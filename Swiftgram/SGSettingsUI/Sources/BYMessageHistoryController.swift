import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import ItemListUI
import TelegramCore
import TelegramPresentationData
import SGItemListUI
import SGSimpleSettings
import SGStrings

private enum BYHistorySection: Int32, SGItemListSection { case controls, records, management }
private enum BYHistoryAction: Hashable { case more, clear, confirm, cancel, copy(String), openFile(String, String) }
private struct BYHistoryUIState: Equatable {
    var query = ""
    var deletedOnly = false
    var limit = 50
    var confirmingClear = false
}
private typealias BYHistoryEntry = SGItemListUIEntry<BYHistorySection, Int, Int, Int, String, BYHistoryAction>

public func byMessageHistoryController(context: AccountContext, peerId: Int64? = nil, messageId: Int32? = nil, recordKey: String? = nil) -> ViewController {
    var state = BYHistoryUIState()
    let statePromise = ValuePromise(state, ignoreRepeated: true)
    var pushImpl: ((ViewController) -> Void)?
    let arguments = SGItemListArguments<Int, Int, Int, String, BYHistoryAction>(
        context: context,
        setBoolValue: { _, value in
            state.deletedOnly = value
            state.limit = 50
            statePromise.set(state)
        },
        openDisclosureLink: { key in
            pushImpl?(byMessageHistoryController(context: context, recordKey: key))
        },
        action: { action in
            switch action {
            case .more: state.limit += 50
            case .clear: state.confirmingClear = true
            case .cancel: state.confirmingClear = false
            case .confirm:
                let _ = context.engine.messages.byRemoveMessageHistory(key: recordKey).start()
                state.confirmingClear = false
            case let .copy(text): UIPasteboard.general.string = text
            case let .openFile(key, localId): pushImpl?(byMessageHistoryMediaController(context: context, recordKey: key, localId: localId))
            }
            statePromise.set(state)
        },
        searchInput: { query in
            state.query = query
            state.limit = 50
            statePromise.set(state)
        }
    )
    let signal = combineLatest(context.sharedContext.presentationData, context.engine.messages.byMessageHistory(), statePromise.get())
    |> map { presentationData, ledger, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let lang = presentationData.strings.baseLanguageCode
        func tr(_ key: String) -> String { i18n("Settings.BYPlugin." + key, lang) }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        func date(_ value: Int64) -> String { formatter.string(from: Date(timeIntervalSince1970: TimeInterval(value))) }
        var entries: [BYHistoryEntry] = []
        if let recordKey {
            if let record = ledger.records.first(where: { $0.key == recordKey }) {
                entries.append(.plainNotice(id: 1, section: .records, text: "\(record.chatTitle)\n\(record.author)\nID: \(record.messageId) · \(date(Int64(record.sentAt)))"))
                if record.retainedTimed == true {
                    entries.append(.plainNotice(id: 2, section: .records, text: tr("History.Retained")))
                } else if let deletedAt = record.deletedAt {
                    entries.append(.plainNotice(id: 2, section: .records, text: tr("History.Deleted") + " · " + date(deletedAt)))
                }
                for (index, version) in record.versions.enumerated() {
                    let base = 10 + index * 32
                    entries.append(.header(id: base, section: .records, text: "\(index + 1) · \(date(version.timestamp))", badge: nil))
                    let preview = String(version.text.prefix(4096))
                    let mediaDescriptions = (version.attachments?.isEmpty == false) ? [] : version.media.map { $0.components(separatedBy: " · id:").first ?? $0 }
                    let body = ([preview] + mediaDescriptions).filter { !$0.isEmpty }.joined(separator: "\n")
                    let note = version.truncated || preview != version.text ? "\n" + tr("History.Truncated") : ""
                    entries.append(.plainNotice(id: base + 1, section: .records, text: body + note))
                    if !version.text.isEmpty {
                        entries.append(.action(id: base + 2, section: .records, actionType: .copy(version.text), text: tr("History.Copy"), kind: .generic))
                    }
                    for (attachmentIndex, attachment) in (version.attachments ?? []).enumerated() {
                        if let localId = attachment.localId {
                            entries.append(.action(id: base + 3 + attachmentIndex, section: .records, actionType: .openFile(record.key, localId), text: tr("History.OpenAttachment") + " · " + attachment.fileName, kind: .generic))
                        } else {
                            entries.append(.plainNotice(id: base + 3 + attachmentIndex, section: .records, text: attachment.fileName + "\n" + tr("History.MediaUnavailable")))
                        }
                    }
                    if !version.media.isEmpty && (version.attachments?.isEmpty ?? true) {
                        entries.append(.plainNotice(id: base + 24, section: .records, text: tr("History.MediaNotSaved")))
                    }
                }
            } else {
                entries.append(.plainNotice(id: 1, section: .records, text: tr("History.Empty")))
            }
        } else {
            entries.append(.searchInput(id: 1, section: .controls, title: NSAttributedString(string: ""), text: state.query, placeholder: tr("History.Search")))
            entries.append(.toggle(id: 2, section: .controls, settingName: 0, value: state.deletedOnly, text: tr("History.DeletedOnly"), enabled: true))
            let records = ledger.matching(state.query, peerId: peerId, messageId: messageId, deletedOnly: state.deletedOnly)
            entries.append(.plainNotice(id: 3, section: .controls, text: tr("History.Count") + ": \(records.count)"))
            entries.append(.plainNotice(id: 4, section: .controls, text: tr("History.MediaUsage") + ": " + ByteCountFormatter.string(fromByteCount: ledger.mediaByteCount, countStyle: .file) + " / 2 GiB"))
            if records.isEmpty {
                entries.append(.plainNotice(id: 5, section: .records, text: tr("History.Empty")))
            }
            for (index, record) in records.prefix(state.limit).enumerated() {
                let prefix = record.retainedTimed == true ? tr("History.Retained") : (record.deletedAt == nil ? tr("History.Edited") : tr("History.Deleted"))
                let version = record.versions.last
                let description = version?.text.isEmpty == false ? version!.text : (version?.attachments?.first?.fileName ?? version?.media.first?.components(separatedBy: " · id:").first ?? "")
                let preview = String(description.prefix(60)).replacingOccurrences(of: "\n", with: " ")
                entries.append(.disclosure(id: 10 + index, section: .records, link: record.key, text: "\(prefix) · \(record.chatTitle) · \(preview)"))
            }
            if records.count > state.limit {
                entries.append(.action(id: 1000, section: .records, actionType: .more, text: tr("History.More"), kind: .generic))
            }
        }
        entries.append(.plainNotice(id: 2000, section: .management, text: tr("History.Notice")))
        if state.confirmingClear {
            entries.append(.plainNotice(id: 2001, section: .management, text: tr("History.ClearConfirm")))
            entries.append(.action(id: 2002, section: .management, actionType: .confirm, text: presentationData.strings.Common_Delete, kind: .destructive))
            entries.append(.action(id: 2003, section: .management, actionType: .cancel, text: presentationData.strings.Common_Cancel, kind: .generic))
        } else {
            entries.append(.action(id: 2001, section: .management, actionType: .clear, text: tr(recordKey == nil ? "History.ClearAll" : "History.ClearOne"), kind: .destructive))
        }
        return (
            ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(tr("History.Title")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks), arguments)
        )
    }
    let controller = ItemListController(context: context, state: signal)
    pushImpl = { [weak controller] child in
        (controller?.navigationController as? NavigationController)?.pushViewController(child)
    }
    return controller
}
