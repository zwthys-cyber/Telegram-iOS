import Foundation
import Display
import SwiftSignalKit
import AccountContext
import ItemListUI
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import SGItemListUI
import SGSimpleSettings
import SGStrings

private enum BYChatSection: Int32, SGItemListSection { case mode, chats, rules }
private enum BYChatAction: Hashable { case addChat, more, addRule, removeRule(String) }
private typealias BYChatEntry = SGItemListUIEntry<BYChatSection, Int, Int, Int, Int64, BYChatAction>

private func byChatModeTitle(_ mode: BYChatGhostMode, _ lang: String) -> String {
    return i18n("Settings.BYPlugin.Chat." + mode.rawValue, lang)
}

public func byChatPrivacyController(context: AccountContext, peerId: Int64, title: String) -> ViewController {
    let accountId = context.account.peerId.toInt64()
    var selectImpl: (([SGOneFromManyOption]) -> Void)?
    let arguments = SGItemListArguments<Int, Int, Int, Int64, BYChatAction>(
        context: context,
        setOneFromManyValue: { _ in
            let lang = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode }
            selectImpl?(BYChatGhostMode.allCases.map { mode in
                SGOneFromManyOption(title: byChatModeTitle(mode, lang), isSelected: BYPrivacy.chatMode(accountId, peerId: peerId) == mode, action: {
                    BYPrivacy.updateChat(accountId, peerId: peerId, title: title, mode: mode)
                })
            })
        }
    )
    let signal = combineLatest(context.sharedContext.presentationData, context.engine.messages.byPrivacySettingsChanges())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        func tr(_ key: String) -> String { i18n("Settings.BYPlugin.Chat." + key, lang) }
        let entries: [BYChatEntry] = [
            .plainNotice(id: 1, section: .mode, text: title),
            .oneFromManySelector(id: 2, section: .mode, settingName: 0, text: tr("Mode"), value: byChatModeTitle(BYPrivacy.chatMode(accountId, peerId: peerId), lang), enabled: BYPlugin.isEnabled(.chatPrivacy) && BYPlugin.isEnabled(.ghostMode)),
            .notice(id: 3, section: .mode, text: tr("Notice"))
        ]
        return (
            ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(tr("Title")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks), arguments)
        )
    }
    let controller = ItemListController(context: context, state: signal)
    selectImpl = { [weak controller] options in
        guard let controller else { return }
        sgPresentOneFromManySelector(controller: controller, setting: 0, presentationData: context.sharedContext.currentPresentationData.with { $0 }, options: options)
    }
    return controller
}

public func byChatPrivacyListController(context: AccountContext) -> ViewController {
    let accountId = context.account.peerId.toInt64()
    let limit = ValuePromise(50, ignoreRepeated: true)
    var currentLimit = 50
    var pushImpl: ((ViewController) -> Void)?
    var chooseImpl: (() -> Void)?
    let arguments = SGItemListArguments<Int, Int, Int, Int64, BYChatAction>(
        context: context,
        openDisclosureLink: { peerId in
            if let chat = BYPrivacy.savedChats(accountId).first(where: { $0.peerId == peerId }) {
                pushImpl?(byChatPrivacyController(context: context, peerId: peerId, title: chat.title))
            }
        },
        action: { action in
            switch action {
            case .addChat: chooseImpl?()
            case .more:
                currentLimit += 50
                limit.set(currentLimit)
            default: break
            }
        }
    )
    let signal = combineLatest(context.sharedContext.presentationData, context.engine.messages.byPrivacySettingsChanges(), limit.get())
    |> map { presentationData, _, limit -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        func tr(_ key: String) -> String { i18n("Settings.BYPlugin.Chat." + key, lang) }
        let chats = BYPrivacy.savedChats(accountId).sorted {
            if $0.title == $1.title { return $0.peerId < $1.peerId }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        var entries: [BYChatEntry] = [
            .action(id: 1, section: .mode, actionType: .addChat, text: tr("Add"), kind: .generic),
            .notice(id: 2, section: .mode, text: tr("Notice"))
        ]
        if chats.isEmpty {
            entries.append(.plainNotice(id: 3, section: .chats, text: tr("Empty")))
        }
        for (index, chat) in chats.prefix(limit).enumerated() {
            entries.append(.disclosure(id: 10 + index, section: .chats, link: chat.peerId, text: chat.title + " · " + byChatModeTitle(chat.mode, lang)))
        }
        if chats.count > limit {
            entries.append(.action(id: 10 + limit, section: .chats, actionType: .more, text: i18n("Settings.BYPlugin.History.More", lang), kind: .generic))
        }
        return (
            ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(tr("Title")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks), arguments)
        )
    }
    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] child in
        (controller?.navigationController as? NavigationController)?.pushViewController(child)
    }
    chooseImpl = { [weak controller] in
        guard let navigationController = controller?.navigationController as? NavigationController else { return }
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let picker = context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(
            context: context,
            filter: [.excludeSecretChats, .excludeRecent, .doNotSearchMessages],
            hasContactSelector: false,
            hasGlobalSearch: false,
            title: i18n("Settings.BYPlugin.Chat.Add", presentationData.strings.baseLanguageCode),
            selectForumThreads: false
        ))
        picker.peerSelected = { [weak picker, weak controller] peer, _ in
            picker?.dismiss()
            let child = byChatPrivacyController(context: context, peerId: peer.id.toInt64(), title: peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder))
            (controller?.navigationController as? NavigationController)?.pushViewController(child)
        }
        navigationController.pushViewController(picker)
    }
    return controller
}

public func byPromotionRulesController(context: AccountContext) -> ViewController {
    let accountId = context.account.peerId.toInt64()
    let query = ValuePromise("", ignoreRepeated: true)
    var currentQuery = ""
    let arguments = SGItemListArguments<Int, Int, Int, Int64, BYChatAction>(
        context: context,
        action: { action in
            switch action {
            case .addRule:
                let input = currentQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !input.isEmpty else { return }
                BYPrivacy.update(accountId) { $0.promotionKeywords.append(input) }
                currentQuery = ""
                query.set("")
            case let .removeRule(rule):
                BYPrivacy.update(accountId) { $0.promotionKeywords.removeAll { $0 == rule } }
            default: break
            }
        },
        searchInput: { value in
            currentQuery = value
            query.set(value)
        }
    )
    let signal = combineLatest(context.sharedContext.presentationData, context.engine.messages.byPrivacySettingsChanges(), query.get())
    |> map { presentationData, _, query -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        func tr(_ key: String) -> String { i18n("Settings.BYPlugin.Ads." + key, lang) }
        let rules = BYPrivacy.saved(accountId).promotionKeywords
        var entries: [BYChatEntry] = [
            .searchInput(id: 1, section: .mode, title: NSAttributedString(string: ""), text: query, placeholder: tr("Placeholder")),
            .action(id: 2, section: .mode, actionType: .addRule, text: tr("AddRule"), kind: .generic),
            .notice(id: 3, section: .mode, text: tr("RulesNotice")),
            .plainNotice(id: 4, section: .mode, text: "\(rules.count) / 100")
        ]
        if rules.isEmpty { entries.append(.plainNotice(id: 5, section: .rules, text: tr("Empty"))) }
        for (index, rule) in rules.enumerated() {
            entries.append(.action(id: 10 + index, section: .rules, actionType: .removeRule(rule), text: presentationData.strings.Common_Delete + " · " + rule, kind: .destructive))
        }
        return (
            ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(tr("Rules")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks), arguments)
        )
    }
    return ItemListController(context: context, state: signal)
}
