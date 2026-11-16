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

private func byHistoryHasTimer(_ message: Message) -> Bool {
    return message.attributes.contains { $0 is AutoclearTimeoutMessageAttribute || $0 is AutoremoveTimeoutMessageAttribute }
}

private func byHistoryEligible(id: MessageId, media: [Media], attributes: [MessageAttribute], allowTimed: Bool = false) -> Bool {
    guard id.namespace == Namespaces.Message.Cloud, id.peerId.namespace != Namespaces.Peer.SecretChat else { return false }
    guard !attributes.contains(where: { $0 is RestrictedContentMessageAttribute }) else { return false }
    if !allowTimed && attributes.contains(where: { $0 is AutoclearTimeoutMessageAttribute || $0 is AutoremoveTimeoutMessageAttribute }) { return false }
    return !media.contains { $0 is TelegramMediaPaidContent || $0 is TelegramMediaExpiredContent || $0 is TelegramMediaAction }
}

func byHistoryMediaStorage(mediaBox: MediaBox, ledger: BYHistoryLedger) -> BYHistoryMediaStorage {
    let directory = URL(fileURLWithPath: mediaBox.basePath, isDirectory: true).deletingLastPathComponent().appendingPathComponent("by-media-history", isDirectory: true)
    return BYHistoryMediaStorage(directoryPath: directory.path, existing: ledger.attachments)
}

private func byHistoryWrite(transaction: Transaction, ledger: BYHistoryLedger, storage: BYHistoryMediaStorage?) {
    transaction.setPreferencesEntry(key: byHistoryKey, value: PreferencesEntry(ledger))
    if let storage {
        let ids = Set(ledger.attachments.compactMap(\.localId))
        transaction.afterCommit {
            Queue.concurrentDefaultQueue().async { storage.removeUnreferenced(keeping: ids) }
        }
    }
}

private func byEncodedHistoryObject(_ object: PostboxCoding, maximumBytes: Int) -> Data? {
    let encoder = PostboxEncoder()
    encoder.encodeRootObject(object)
    let data = encoder.makeData()
    return data.count <= maximumBytes ? data : nil
}

private func byHistoryVersion(text: String, media: [Media], now: Int64, mediaBox: MediaBox, storage: BYHistoryMediaStorage?) -> BYHistoryVersion {
    var attachments: [BYHistoryAttachment] = []
    let descriptions: [String] = media.prefix(20).compactMap { item in
        if let file = item as? TelegramMediaFile {
            if let storage {
                let extensions = ["video/mp4": "mp4", "video/quicktime": "mov", "audio/mpeg": "mp3", "audio/mp4": "m4a", "audio/ogg": "ogg", "application/pdf": "pdf", "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"]
                let ext = extensions[file.mimeType] ?? (file.isVideo ? "mp4" : "bin")
                var name = BYLocalSaving.fileName(file.fileName, fallback: "Media." + ext)
                if (name as NSString).pathExtension.isEmpty { name += "." + ext }
                attachments.append(storage.preserve(resourceId: file.resource.id.stringRepresentation, sourcePath: mediaBox.completedResourcePath(file.resource), fileName: name, mimeType: file.mimeType, mediaData: byEncodedHistoryObject(file, maximumBytes: 32768)))
            }
            return [file.fileName ?? file.mimeType, file.size.map { "\($0) bytes" } ?? "", "id:\(file.fileId.id)"].filter { !$0.isEmpty }.joined(separator: " · ")
        } else if let image = item as? TelegramMediaImage {
            if let storage {
                let representations = image.representations.sorted {
                    Int64($0.dimensions.width) * Int64($0.dimensions.height) > Int64($1.dimensions.width) * Int64($1.dimensions.height)
                }
                let available = representations.first { mediaBox.completedResourcePath($0.resource) != nil }
                if let representation = available ?? representations.first {
                    attachments.append(storage.preserve(resourceId: representation.resource.id.stringRepresentation, sourcePath: mediaBox.completedResourcePath(representation.resource), fileName: "Photo.jpg", mimeType: "image/jpeg", mediaData: byEncodedHistoryObject(image, maximumBytes: 32768)))
                }
            }
            return "Photo · id:\(image.imageId.id)"
        } else if item is TelegramMediaWebpage {
            return "Web page"
        }
        return "Attachment"
    }
    return BYHistoryVersion(text: text, media: descriptions, timestamp: now, attachments: attachments)
}

private func byHistorySnapshot(_ message: Message, transaction: Transaction, mediaBox: MediaBox, storage: BYHistoryMediaStorage?, now: Int64, retainedTimed: Bool) -> BYHistoryRecord? {
    guard byHistoryEligible(id: message.id, media: message.media, attributes: message.attributes, allowTimed: retainedTimed) else { return nil }
    return BYHistoryRecord(peerId: message.id.peerId.toInt64(), namespace: message.id.namespace, messageId: message.id.id,
        chatTitle: byHistoryName(transaction.getPeer(message.id.peerId)),
        author: byHistoryName(message.author), sentAt: message.timestamp,
        version: byHistoryVersion(text: message.text, media: message.media, now: now, mediaBox: mediaBox, storage: storage),
        threadId: message.threadId, originalStableId: message.stableId, retainedTimed: retainedTimed, authorData: message.author.flatMap { byEncodedHistoryObject($0, maximumBytes: 16384) })
}

/// Capture before ordinary cache deletion; canonical message deletion and pts still proceed.
func byArchiveDeletedMessages(transaction: Transaction, mediaBox: MediaBox, ids: [MessageId]) {
    let options = byAccountOptions(transaction: transaction)
    guard options.keepDeleted || options.retainTimed, !ids.isEmpty else { return }
    let now = Int64(Date().timeIntervalSince1970)
    var ledger = transaction.getPreferencesEntry(key: byHistoryKey)?.get(BYHistoryLedger.self) ?? BYHistoryLedger()
    let storage = options.keepMedia || options.retainTimed || !ledger.attachments.isEmpty ? byHistoryMediaStorage(mediaBox: mediaBox, ledger: ledger) : nil
    var changed = false
    for id in ids.suffix(BYHistoryLedger.maximumRecords) {
        guard let message = transaction.getMessage(id) else { continue }
        let retainedTimed = options.retainTimed && message.flags.contains(.Incoming) && byHistoryHasTimer(message)
        guard options.keepDeleted || retainedTimed else { continue }
        if let snapshot = byHistorySnapshot(message, transaction: transaction, mediaBox: mediaBox,
            storage: options.keepMedia || retainedTimed ? storage : nil, now: now, retainedTimed: retainedTimed) {
            changed = ledger.record(snapshot, editedTo: nil, deleted: true, now: now, days: options.historyDays, pruneImmediately: false) || changed
        }
    }
    if changed {
        ledger.prune(now: now, days: options.historyDays)
        byHistoryWrite(transaction: transaction, ledger: ledger, storage: storage)
    } else if let storage {
        let ids = Set(ledger.attachments.compactMap(\.localId))
        transaction.afterCommit { Queue.concurrentDefaultQueue().async { storage.removeUnreferenced(keeping: ids) } }
    }
}

func byCaptureTimedMessage(transaction: Transaction, mediaBox: MediaBox, message: Message, expired: Bool = false) {
    let options = byAccountOptions(transaction: transaction)
    guard options.retainTimed, message.flags.contains(.Incoming), byHistoryHasTimer(message),
          byHistoryEligible(id: message.id, media: message.media, attributes: message.attributes, allowTimed: true) else { return }
    let now = Int64(Date().timeIntervalSince1970)
    var ledger = transaction.getPreferencesEntry(key: byHistoryKey)?.get(BYHistoryLedger.self) ?? BYHistoryLedger()
    let storage = byHistoryMediaStorage(mediaBox: mediaBox, ledger: ledger)
    guard let snapshot = byHistorySnapshot(message, transaction: transaction, mediaBox: mediaBox, storage: storage, now: now, retainedTimed: true) else { return }
    let _ = ledger.record(snapshot, editedTo: nil, deleted: expired, now: now, days: options.historyDays)
    byHistoryWrite(transaction: transaction, ledger: ledger, storage: storage)
}

func byArchiveEditedMessage(transaction: Transaction, mediaBox: MediaBox, previous: Message, updated: StoreMessage) {
    // Also capture a still-accessible timed message before an update replaces its media with an expired placeholder.
    byCaptureTimedMessage(transaction: transaction, mediaBox: mediaBox, message: previous)
    let options = byAccountOptions(transaction: transaction)
    let retainedTimed = options.retainTimed && previous.flags.contains(.Incoming) && byHistoryHasTimer(previous)
    guard options.keepEdits, byHistoryEligible(id: previous.id, media: updated.media, attributes: updated.attributes, allowTimed: retainedTimed) else { return }
    let now = Int64(Date().timeIntervalSince1970)
    var ledger = transaction.getPreferencesEntry(key: byHistoryKey)?.get(BYHistoryLedger.self) ?? BYHistoryLedger()
    let storage = options.keepMedia || retainedTimed || !ledger.attachments.isEmpty ? byHistoryMediaStorage(mediaBox: mediaBox, ledger: ledger) : nil
    guard let snapshot = byHistorySnapshot(previous, transaction: transaction, mediaBox: mediaBox,
        storage: options.keepMedia || retainedTimed ? storage : nil, now: now, retainedTimed: retainedTimed) else { return }
    let next = byHistoryVersion(text: updated.text, media: updated.media, now: now, mediaBox: mediaBox, storage: options.keepMedia || retainedTimed ? storage : nil)
    guard snapshot.versions.last?.sameContent(as: next) == false else {
        if let storage {
            let ids = Set(ledger.attachments.compactMap(\.localId))
            transaction.afterCommit { Queue.concurrentDefaultQueue().async { storage.removeUnreferenced(keeping: ids) } }
        }
        return
    }
    let _ = ledger.record(snapshot, editedTo: next, deleted: false, now: now, days: options.historyDays)
    byHistoryWrite(transaction: transaction, ledger: ledger, storage: storage)
}

/// Owns a temporary hard link so clearing history cannot invalidate an open preview/export.
public final class BYHistoryPreviewFile {
    public let url: URL
    private let file: EngineTempBox.File
    init?(path: String, fileName: String) {
        let file = EngineTempBox.shared.file(path: path, fileName: BYLocalSaving.fileName(fileName, fallback: "Media.bin"))
        guard FileManager.default.fileExists(atPath: file.path) else {
            EngineTempBox.shared.dispose(file)
            return nil
        }
        self.file = file
        self.url = URL(fileURLWithPath: file.path)
    }
    deinit { EngineTempBox.shared.dispose(self.file) }
}

public extension TelegramEngine.Messages {
    func byMessageHistory() -> Signal<BYHistoryLedger, NoError> {
        let account = self.account
        let prune = account.postbox.transaction { transaction -> Void in
            guard var ledger = transaction.getPreferencesEntry(key: byHistoryKey)?.get(BYHistoryLedger.self) else { return }
            let before = ledger
            ledger.prune(now: Int64(Date().timeIntervalSince1970), days: BYPrivacy.saved(account.peerId.toInt64()).historyDays)
            let storage = byHistoryMediaStorage(mediaBox: account.postbox.mediaBox, ledger: ledger)
            if before != ledger {
                byHistoryWrite(transaction: transaction, ledger: ledger, storage: storage)
            } else {
                let ids = Set(ledger.attachments.compactMap(\.localId))
                transaction.afterCommit { Queue.concurrentDefaultQueue().async { storage.removeUnreferenced(keeping: ids) } }
            }
        }
        return prune |> mapToSignal { _ in
            account.postbox.preferencesView(keys: [byHistoryKey])
            |> map { view in view.values[byHistoryKey]?.get(BYHistoryLedger.self) ?? BYHistoryLedger() }
        }
    }

    func byRemoveMessageHistory(key: String? = nil) -> Signal<Void, NoError> {
        let account = self.account
        return account.postbox.transaction { transaction -> Void in
            var ledger = transaction.getPreferencesEntry(key: byHistoryKey)?.get(BYHistoryLedger.self) ?? BYHistoryLedger()
            let storage = byHistoryMediaStorage(mediaBox: account.postbox.mediaBox, ledger: ledger)
            if let key { ledger.records.removeAll { $0.key == key } } else { ledger.records.removeAll() }
            byHistoryWrite(transaction: transaction, ledger: ledger, storage: storage)
        }
    }

    func byRetainTimedMessage(message: EngineMessage) -> Signal<Void, NoError> {
        let account = self.account
        return account.postbox.transaction { transaction -> Void in
            byCaptureTimedMessage(transaction: transaction, mediaBox: account.postbox.mediaBox, message: message._asMessage())
        }
    }

    /// Watches downloads already requested by the viewer. It does not start a
    /// remote download, and the viewer must dispose it when dismissed.
    func byObserveTimedMessageMedia(message: EngineMessage) -> Signal<Void, NoError> {
        let account = self.account
        guard BYPrivacy.effective(account.peerId.toInt64()).retainTimed else { return .complete() }
        let raw = message._asMessage()
        guard raw.flags.contains(.Incoming), byHistoryHasTimer(raw),
              byHistoryEligible(id: raw.id, media: raw.media, attributes: raw.attributes, allowTimed: true) else { return .complete() }
        var seen = Set<MediaResourceId>()
        var resources: [MediaResource] = []
        for media in raw.media {
            if let image = media as? TelegramMediaImage {
                for representation in image.representations where seen.insert(representation.resource.id).inserted { resources.append(representation.resource) }
            } else if let file = media as? TelegramMediaFile, seen.insert(file.resource.id).inserted {
                resources.append(file.resource)
            }
        }
        guard !resources.isEmpty else { return self.byRetainTimedMessage(message: message) }
        let watched = combineLatest(resources.map { resource in
            account.postbox.mediaBox.resourceData(resource) |> map { $0.complete }
        })
        |> distinctUntilChanged
        |> filter { $0.contains(true) }
        |> mapToSignal { _ -> Signal<Void, NoError> in
            self.byRetainTimedMessage(message: message)
        }
        return self.byRetainTimedMessage(message: message) |> then(watched)
    }

    func byMessageHistoryFile(recordKey: String, localId: String? = nil) -> Signal<BYHistoryPreviewFile?, NoError> {
        let account = self.account
        return account.postbox.transaction { transaction -> BYHistoryPreviewFile? in
            let ledger = transaction.getPreferencesEntry(key: byHistoryKey)?.get(BYHistoryLedger.self) ?? BYHistoryLedger()
            guard let record = ledger.records.first(where: { $0.key == recordKey }),
                  let attachment = record.versions.flatMap({ $0.attachments ?? [] }).first(where: { attachment in attachment.localId != nil && (localId == nil || attachment.localId == localId) }) else { return nil }
            let storage = byHistoryMediaStorage(mediaBox: account.postbox.mediaBox, ledger: ledger)
            guard let url = storage.fileURL(for: attachment) else { return nil }
            return BYHistoryPreviewFile(path: url.path, fileName: attachment.fileName)
        }
    }
}

/// Presentation-only notice attached to synthetic chat rows. Never written to Postbox.
public final class BYLocalMessageNoticeAttribute: MessageAttribute {
    public enum Kind: Int32 { case deleted = 0, promotion = 1, retained = 2 }
    public let kind: Kind
    public let recordKey: String
    public init(kind: Kind, recordKey: String = "") { self.kind = kind; self.recordKey = recordKey }
    public init(decoder: PostboxDecoder) {
        self.kind = Kind(rawValue: decoder.decodeInt32ForKey("k", orElse: 0)) ?? .deleted
        self.recordKey = decoder.decodeStringForKey("r", orElse: "")
    }
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.kind.rawValue, forKey: "k")
        encoder.encodeString(self.recordKey, forKey: "r")
    }
}

public extension Message {
    var byLocalNotice: BYLocalMessageNoticeAttribute? {
        return self.attributes.first(where: { $0 is BYLocalMessageNoticeAttribute }) as? BYLocalMessageNoticeAttribute
    }
}
