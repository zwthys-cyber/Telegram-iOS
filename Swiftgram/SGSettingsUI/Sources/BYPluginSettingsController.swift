import TelegramCore
import Foundation
import Display
import SwiftSignalKit
import AccountContext
import ItemListUI
import TelegramPresentationData
import PresentationDataUtils
import SGItemListUI
import SGSimpleSettings
import SGStrings

private enum BYSection: Int32, SGItemListSection {
    case status, ghost, history, saving, messages, downloads, interface, ads
}
private enum BYToggle: Hashable {
    case localSaving, saveMenu, json, seconds, quickTranslate
    case ghost, online, typing, reads, stories, deleted, edits
    case toolbar, hidePhone, confirmCalls, markers, sponsored, promotions
}
private enum BYSelector: Hashable { case downloadMode, retention }
private typealias BYEntry = SGItemListUIEntry<BYSection, BYToggle, Int, BYSelector, Int, Int>

func byPluginSettingsController(context: AccountContext, updated: @escaping () -> Void = {}) -> ViewController {
    let refresh = ValuePromise(true, ignoreRepeated: false)
    let accountId = context.account.peerId.toInt64()
    var selectImpl: ((BYSelector, [SGOneFromManyOption]) -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    let arguments = SGItemListArguments<BYToggle, Int, BYSelector, Int, Int>(
        context: context,
        setBoolValue: { setting, value in
            switch setting {
            case .localSaving: SGSimpleSettings.shared.byLocalSaving = value
            case .saveMenu: SGSimpleSettings.shared.contextShowSaveMedia = value
            case .json: SGSimpleSettings.shared.contextShowJson = value
            case .seconds: SGSimpleSettings.shared.secondsInMessages = value
            case .quickTranslate: SGSimpleSettings.shared.quickTranslateButton = value
            case .toolbar: SGSimpleSettings.shared.inputToolbar = value
            case .hidePhone: SGSimpleSettings.shared.hidePhoneInSettings = value
            case .confirmCalls: SGSimpleSettings.shared.confirmCalls = value
            default:
                BYPrivacy.update(accountId) { options in
                    switch setting {
                    case .ghost: options.setGhost(value)
                    case .online: options.hideOnline = value
                    case .typing: options.hideTyping = value
                    case .reads: options.hideReadReceipts = value
                    case .stories: options.hideStoryViews = value
                    case .deleted: options.keepDeleted = value
                    case .edits: options.keepEdits = value
                    case .markers: options.showDeletedMarkers = value
                    case .sponsored: options.hideSponsoredMessages = value
                    case .promotions: options.filterPromotions = value
                    default: break
                    }
                }
            }
            refresh.set(true)
            updated()
        },
        setOneFromManyValue: { setting in
            let lang = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode }
            switch setting {
            case .downloadMode:
                selectImpl?(setting, SGSimpleSettings.DownloadSpeedBoostValues.allCases.map { mode in
                    SGOneFromManyOption(title: i18n("Settings.DownloadsBoost.\(mode.rawValue)", lang), isSelected: SGSimpleSettings.shared.downloadSpeedBoost == mode.rawValue, action: {
                        SGSimpleSettings.shared.downloadSpeedBoost = mode.rawValue
                        refresh.set(true)
                        updated()
                    })
                })
            case .retention:
                selectImpl?(setting, [7, 30, 90].map { days in
                    SGOneFromManyOption(title: "\(days) " + i18n("Settings.BYPlugin.History.Days", lang), isSelected: BYPrivacy.saved(accountId).historyDays == days, action: {
                        BYPrivacy.update(accountId) { $0.historyDays = days }
                        refresh.set(true)
                    })
                })
            }
        },
        openDisclosureLink: { link in
            switch link {
            case 1: pushImpl?(byChatPrivacyListController(context: context))
            case 2: pushImpl?(byPromotionRulesController(context: context))
            default: pushImpl?(byMessageHistoryController(context: context))
            }
        }
    )
    let signal = combineLatest(context.sharedContext.presentationData, refresh.get(), context.engine.messages.byPrivacySettingsChanges())
    |> map { presentationData, _, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        func tr(_ key: String) -> String { i18n("Settings.BYPlugin." + key, lang) }
        let options = BYPrivacy.saved(accountId)
        let ghostAvailable = BYPlugin.isEnabled(.ghostMode)
        let historyAvailable = BYPlugin.isEnabled(.messageHistory)
        let status = !BYPlugin.available ? "Missing" : (ghostAvailable && historyAvailable && BYPlugin.isEnabled(.chatPrivacy) && BYPlugin.isEnabled(.deletionMarkers) && BYPlugin.isEnabled(.adBlock) ? "ActiveV21" : "LegacyV21")
        let capabilities: [(String, BYPlugin.Feature)] = [("Capability.Icons", .icons), ("Capability.Tools", .messageTools), ("Capability.Local", .localFeatures), ("Capability.Downloads", .downloadBoost), ("Capability.Storage", .privateStorage), ("Capability.Login", .loginRestart), ("Chat.Title", .chatPrivacy), ("History.Markers", .deletionMarkers), ("Ads.Title", .adBlock)]
        let capabilityText = capabilities.map { tr($0.0) + ": " + tr(BYPlugin.isEnabled($0.1) ? "Available" : "Unavailable") }.joined(separator: "\n")
        let entries: [BYEntry] = [
            .header(id: 1, section: .status, text: "BYPlugin 2.1", badge: nil),
            .notice(id: 2, section: .status, text: tr("Status." + status)),
            .header(id: 10, section: .ghost, text: tr("Ghost.Title"), badge: nil),
            .toggle(id: 11, section: .ghost, settingName: .ghost, value: options.anyGhostEnabled, text: tr("Ghost.Master"), enabled: ghostAvailable),
            .toggle(id: 12, section: .ghost, settingName: .online, value: options.hideOnline, text: tr("Ghost.Online"), enabled: ghostAvailable),
            .toggle(id: 13, section: .ghost, settingName: .typing, value: options.hideTyping, text: tr("Ghost.Typing"), enabled: ghostAvailable),
            .toggle(id: 14, section: .ghost, settingName: .reads, value: options.hideReadReceipts, text: tr("Ghost.Reads"), enabled: ghostAvailable),
            .toggle(id: 15, section: .ghost, settingName: .stories, value: options.hideStoryViews, text: tr("Ghost.Stories"), enabled: ghostAvailable),
            .notice(id: 16, section: .ghost, text: tr("Ghost.Notice")),
            .disclosure(id: 17, section: .ghost, link: 1, text: tr("Chat.Title")),
            .header(id: 20, section: .history, text: tr("History.Title"), badge: nil),
            .toggle(id: 21, section: .history, settingName: .deleted, value: options.keepDeleted, text: tr("History.KeepDeleted"), enabled: historyAvailable),
            .toggle(id: 22, section: .history, settingName: .edits, value: options.keepEdits, text: tr("History.KeepEdits"), enabled: historyAvailable),
            .oneFromManySelector(id: 23, section: .history, settingName: .retention, text: tr("History.Retention"), value: "\(options.historyDays) " + tr("History.Days"), enabled: true),
            .disclosure(id: 24, section: .history, link: 0, text: tr("History.Open")),
            .notice(id: 25, section: .history, text: tr("History.Notice")),
            .toggle(id: 26, section: .history, settingName: .markers, value: options.showDeletedMarkers, text: tr("History.Markers"), enabled: historyAvailable && options.keepDeleted && BYPlugin.isEnabled(.deletionMarkers)),
            .notice(id: 27, section: .history, text: tr("History.MarkerNotice")),
            .header(id: 30, section: .saving, text: tr("LocalSaving"), badge: nil),
            .toggle(id: 31, section: .saving, settingName: .localSaving, value: SGSimpleSettings.shared.byLocalSaving, text: tr("LocalSaving"), enabled: BYPlugin.isEnabled(.localSaving)),
            .toggle(id: 32, section: .saving, settingName: .saveMenu, value: SGSimpleSettings.shared.contextShowSaveMedia, text: tr("SaveMenu"), enabled: true),
            .notice(id: 33, section: .saving, text: tr("LocalSaving.Notice")),
            .header(id: 40, section: .messages, text: i18n("Settings.ContextMenu", lang), badge: nil),
            .toggle(id: 41, section: .messages, settingName: .json, value: SGSimpleSettings.shared.contextShowJson, text: "JSON", enabled: true),
            .toggle(id: 42, section: .messages, settingName: .seconds, value: SGSimpleSettings.shared.secondsInMessages, text: i18n("Settings.secondsInMessages", lang), enabled: true),
            .toggle(id: 43, section: .messages, settingName: .quickTranslate, value: SGSimpleSettings.shared.quickTranslateButton, text: i18n("Settings.Translation.QuickTranslateButton", lang), enabled: true),
            .notice(id: 44, section: .messages, text: tr("Tools.Notice")),
            .header(id: 50, section: .downloads, text: i18n("Settings.DownloadsBoost", lang), badge: nil),
            .oneFromManySelector(id: 51, section: .downloads, settingName: .downloadMode, text: i18n("Settings.DownloadsBoost", lang), value: i18n("Settings.DownloadsBoost.\(SGSimpleSettings.shared.downloadSpeedBoost)", lang), enabled: BYPlugin.isEnabled(.downloadBoost)),
            .notice(id: 52, section: .downloads, text: tr("Downloads.Notice")),
            .header(id: 60, section: .interface, text: tr("Existing.Title"), badge: nil),
            .toggle(id: 61, section: .interface, settingName: .toolbar, value: SGSimpleSettings.shared.inputToolbar, text: tr("Existing.Toolbar"), enabled: SGLocalFeatures.proEnabled),
            .toggle(id: 62, section: .interface, settingName: .hidePhone, value: SGSimpleSettings.shared.hidePhoneInSettings, text: tr("Existing.HidePhone"), enabled: true),
            .toggle(id: 63, section: .interface, settingName: .confirmCalls, value: SGSimpleSettings.shared.confirmCalls, text: tr("Existing.ConfirmCalls"), enabled: true),
            .plainNotice(id: 64, section: .interface, text: capabilityText),
            .notice(id: 65, section: .interface, text: tr("Existing.Notice")),
            .header(id: 70, section: .ads, text: tr("Ads.Title"), badge: nil),
            .toggle(id: 71, section: .ads, settingName: .sponsored, value: options.hideSponsoredMessages, text: tr("Ads.Sponsored"), enabled: BYPlugin.isEnabled(.adBlock)),
            .toggle(id: 72, section: .ads, settingName: .promotions, value: options.filterPromotions, text: tr("Ads.Promotions"), enabled: BYPlugin.isEnabled(.adBlock)),
            .disclosure(id: 73, section: .ads, link: 2, text: tr("Ads.Rules")),
            .notice(id: 74, section: .ads, text: tr("Ads.Notice"))
        ]
        return (
            ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(tr("Title")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks), arguments)
        )
    }
    let controller = ItemListController(context: context, state: signal)
    selectImpl = { [weak controller] setting, options in
        guard let controller else { return }
        sgPresentOneFromManySelector(controller: controller, setting: setting, presentationData: context.sharedContext.currentPresentationData.with { $0 }, options: options)
    }
    pushImpl = { [weak controller] child in
        (controller?.navigationController as? NavigationController)?.pushViewController(child)
    }
    return controller
}
