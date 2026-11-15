import Foundation
import Display
import SwiftSignalKit
import AccountContext
import ItemListUI
import TelegramPresentationData
import SGItemListUI
import SGSimpleSettings
import SGStrings

private enum BYSection: Int32, SGItemListSection {
    case status
    case saving
    case messages
    case downloads
}
private enum BYToggle: Hashable {
    case localSaving
    case saveMenu
    case json
    case seconds
    case quickTranslate
}
private enum BYSelector: Hashable { case downloadMode }
private typealias BYEntry = SGItemListUIEntry<BYSection, BYToggle, Int, BYSelector, Int, Int>

func byPluginSettingsController(context: AccountContext) -> ViewController {
    let refresh = ValuePromise(true, ignoreRepeated: false)
    var selectImpl: (([SGOneFromManyOption]) -> Void)?
    let arguments = SGItemListArguments<BYToggle, Int, BYSelector, Int, Int>(
        context: context,
        setBoolValue: { setting, value in
            switch setting {
            case .localSaving: SGSimpleSettings.shared.byLocalSaving = value
            case .saveMenu: SGSimpleSettings.shared.contextShowSaveMedia = value
            case .json: SGSimpleSettings.shared.contextShowJson = value
            case .seconds: SGSimpleSettings.shared.secondsInMessages = value
            case .quickTranslate: SGSimpleSettings.shared.quickTranslateButton = value
            }
            refresh.set(true)
        },
        setOneFromManyValue: { _ in
            let lang = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode }
            selectImpl?(SGSimpleSettings.DownloadSpeedBoostValues.allCases.map { mode in
                SGOneFromManyOption(title: i18n("Settings.DownloadsBoost.\(mode.rawValue)", lang), isSelected: SGSimpleSettings.shared.downloadSpeedBoost == mode.rawValue, action: {
                    SGSimpleSettings.shared.downloadSpeedBoost = mode.rawValue
                    refresh.set(true)
                })
            })
        }
    )
    let signal = combineLatest(context.sharedContext.presentationData, refresh.get())
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        let strings = presentationData.strings
        let status = !BYPlugin.available ? "Missing" : (BYPlugin.isEnabled(.localSaving) ? "Active" : "Legacy")
        let entries: [BYEntry] = [
            .header(id: 1, section: .status, text: "BYPlugin", badge: nil),
            .notice(id: 2, section: .status, text: i18n("Settings.BYPlugin.Status." + status, lang)),
            .header(id: 3, section: .saving, text: i18n("Settings.BYPlugin.LocalSaving", lang), badge: nil),
            .toggle(id: 4, section: .saving, settingName: .localSaving, value: SGSimpleSettings.shared.byLocalSaving, text: i18n("Settings.BYPlugin.LocalSaving", lang), enabled: BYPlugin.isEnabled(.localSaving)),
            .notice(id: 5, section: .saving, text: i18n("Settings.BYPlugin.LocalSaving.Notice", lang)),
            .toggle(id: 6, section: .saving, settingName: .saveMenu, value: SGSimpleSettings.shared.contextShowSaveMedia, text: i18n("Settings.BYPlugin.SaveMenu", lang), enabled: true),
            .header(id: 7, section: .messages, text: i18n("Settings.ContextMenu", lang), badge: nil),
            .toggle(id: 8, section: .messages, settingName: .json, value: SGSimpleSettings.shared.contextShowJson, text: "JSON", enabled: true),
            .toggle(id: 9, section: .messages, settingName: .seconds, value: SGSimpleSettings.shared.secondsInMessages, text: i18n("Settings.secondsInMessages", lang), enabled: true),
            .toggle(id: 10, section: .messages, settingName: .quickTranslate, value: SGSimpleSettings.shared.quickTranslateButton, text: i18n("Settings.Translation.QuickTranslateButton", lang), enabled: true),
            .header(id: 11, section: .downloads, text: i18n("Settings.DownloadsBoost", lang), badge: nil),
            .oneFromManySelector(id: 12, section: .downloads, settingName: .downloadMode, text: i18n("Settings.DownloadsBoost", lang), value: i18n("Settings.DownloadsBoost.\(SGSimpleSettings.shared.downloadSpeedBoost)", lang), enabled: BYPlugin.isEnabled(.downloadBoost)),
            .notice(id: 13, section: .downloads, text: i18n("Settings.BYPlugin.Downloads.Notice", lang))
        ]
        return (
            ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(i18n("Settings.BYPlugin.Title", lang)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: strings.Common_Back)),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks), arguments)
        )
    }
    let controller = ItemListController(context: context, state: signal)
    selectImpl = { [weak controller] options in
        guard let controller else { return }
        sgPresentOneFromManySelector(controller: controller, setting: BYSelector.downloadMode, presentationData: context.sharedContext.currentPresentationData.with { $0 }, options: options)
    }
    return controller
}
