import Foundation
import Postbox
import SwiftSignalKit
import SGSimpleSettings

private let byHistoryKey = ValueBoxKey("BYPlugin.messageHistory.v1")

private func byHistoryName(_ peer: Peer?) -> String {
    if let user = peer as? TelegramUser {
        return [user.firstName, user.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    } else if let group = peer as? TelegramGroup {
        return group.title
    } else if let channel = peer as? TelegramChannel {
        return channel.title
    }
    return ""
}

private func byHistoryEligible(id: MessageId, media: [Media], attributes: [MessageAttribute]) -> Bool {
    guard id.namespace == Namespaces.Message.Cloud, id.peerId.namespace != Namespaces.Peer.SecretChat else { return false }
    // Disappearing/view-once media continue using the explicitly invoked local-save path.
    guard !attributes.contains(where: { $0 is AutoclearTimeoutMessageAttribute || $0 is AutoremoveTimeoutMessageAttribute || $0 is RestrictedContentMessageAttribute }) else { return false }
    return !media.contains { $0 is TelegramMediaPaidContent || $0 is TelegramMediaExpiredContent || $0 is TelegramMediaAction }
}

private func byHistoryVersion(text: String, media: [Media], now: Int64) -> BYHistoryVersion {
    let descriptions: [String] = media.compactMap { item in
        if let file = item as? TelegramMediaFile {
            return [file.fileName ?? file.mimeType, file.size.map { "\($0) bytes" } ?? "", "id:\(file.fileId.id)"].filter { !$0.isEmpty }.joined(separator: " · ")
        } else if let image = item as? TelegramMediaImage {
            return "Photo · id:\(image.imageId.id)"
        } else if item is TelegramMediaWebpage {
            return "Web page"
        }
        return "Attachment"
    }
    return BYHistoryVersion(text: text, media: descriptions, timestamp: now)
}

private func byHistorySnapshot(_ message: Message, transaction: Transaction, now: Int64) -> BYHistoryRecord? {
    guard byHistoryEligible(id: message.id, media: message.media, attributes: message.attributes) else { return nil }
    return BYHistoryRecord(peerId: message.id.peerId.toInt64(), namespace: message.id.namespace, messageId: message.id.id,
        chatTitle: byHistoryName(transaction.getPeer(message.id.peerId)),
        author: byHistoryName(message.author), sentAt: message.timestamp,
        version: byHistoryVersion(text: message.text, media: message.media, now: now))
}

func byArchiveDeletedMessages(transaction: Transaction, ids: [MessageId]) {
    let options = byAccountOptions(transaction: transaction)
    guard options.keepDeleted, !ids.isEmpty else { return }
    let now = Int64(Date().timeIntervalSince1970)
    var ledger = transaction.getPreferencesEntry(key: byHistoryKey)?.get(BYHistoryLedger.self) ?? BYHistoryLedger()
    var changed = false
    for id in ids {
        if let message = transaction.getMessage(id), let snapshot = byHistorySnapshot(message, transaction: transaction, now: now) {
            ledger.record(snapshot, editedTo: nil, deleted: true, now: now, days: options.historyDays)
            changed = true
        }
    }
    if changed { transaction.setPreferencesEntry(key: byHistoryKey, value: PreferencesEntry(ledger)) }
}

func byArchiveEditedMessage(transaction: Transaction, previous: Message, updated: StoreMessage) {
    let options = byAccountOptions(transaction: transaction)
    guard options.keepEdits, byHistoryEligible(id: previous.id, media: updated.media, attributes: updated.attributes) else { return }
    let now = Int64(Date().timeIntervalSince1970)
    guard let snapshot = byHistorySnapshot(previous, transaction: transaction, now: now) else { return }
    let next = byHistoryVersion(text: updated.text, media: updated.media, now: now)
    guard snapshot.versions.last?.sameContent(as: next) == false else { return }
    var ledger = transaction.getPreferencesEntry(key: byHistoryKey)?.get(BYHistoryLedger.self) ?? BYHistoryLedger()
    ledger.record(snapshot, editedTo: next, deleted: false, now: now, days: options.historyDays)
    transaction.setPreferencesEntry(key: byHistoryKey, value: PreferencesEntry(ledger))
}

public extension TelegramEngine.Messages {
    func byMessageHistory() -> Signal<BYHistoryLedger, NoError> {
        let account = self.account
        // Pruning is account-local and goes through the same serialized database transaction.
        let prune = account.postbox.transaction { transaction -> Void in
            guard var ledger = transaction.getPreferencesEntry(key: byHistoryKey)?.get(BYHistoryLedger.self) else { return }
            let before = ledger
            ledger.prune(now: Int64(Date().timeIntervalSince1970), days: BYPrivacy.saved(account.peerId.toInt64()).historyDays)
            if before != ledger { transaction.setPreferencesEntry(key: byHistoryKey, value: PreferencesEntry(ledger)) }
        }
        return prune |> mapToSignal { _ in
            account.postbox.preferencesView(keys: [byHistoryKey])
            |> map { view in view.values[byHistoryKey]?.get(BYHistoryLedger.self) ?? BYHistoryLedger() }
        }
    }

    func byRemoveMessageHistory(key: String? = nil) -> Signal<Void, NoError> {
        return self.account.postbox.transaction { transaction -> Void in
            if let key {
                var ledger = transaction.getPreferencesEntry(key: byHistoryKey)?.get(BYHistoryLedger.self) ?? BYHistoryLedger()
                ledger.records.removeAll { $0.key == key }
                transaction.setPreferencesEntry(key: byHistoryKey, value: PreferencesEntry(ledger))
            } else {
                transaction.setPreferencesEntry(key: byHistoryKey, value: nil)
            }
        }
    }
}
