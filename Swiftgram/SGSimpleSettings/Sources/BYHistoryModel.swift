import Foundation

/// A bounded local text/caption and attachment-metadata ledger. Media bytes are not copied.
public struct BYHistoryVersion: Codable, Equatable {
    public let text: String
    public let media: [String]
    public let timestamp: Int64
    public let truncated: Bool

    public init(text: String, media: [String], timestamp: Int64) {
        self.text = String(text.prefix(16384))
        self.media = Array(media.prefix(20)).map { String($0.prefix(1024)) }
        self.timestamp = timestamp
        self.truncated = self.text != text || media.count > 20
    }

    public func sameContent(as other: BYHistoryVersion) -> Bool {
        return text == other.text && media == other.media
    }
}

public struct BYHistoryRecord: Codable, Equatable {
    public let peerId: Int64
    public let namespace: Int32
    public let messageId: Int32
    public var chatTitle: String
    public var author: String
    public let sentAt: Int32
    public var deletedAt: Int64?
    public var versions: [BYHistoryVersion]
    public var updatedAt: Int64

    public var key: String { "\(peerId):\(namespace):\(messageId)" }
    public init(peerId: Int64, namespace: Int32, messageId: Int32, chatTitle: String, author: String, sentAt: Int32, version: BYHistoryVersion) {
        self.peerId = peerId
        self.namespace = namespace
        self.messageId = messageId
        self.chatTitle = String(chatTitle.prefix(512))
        self.author = String(author.prefix(512))
        self.sentAt = sentAt
        self.versions = [version]
        self.updatedAt = version.timestamp
    }
}

public struct BYHistoryLedger: Codable, Equatable {
    public var records: [BYHistoryRecord] = []
    public static let maximumRecords = 500
    public static let maximumVersions = 10
    public static let maximumBytes = 2 * 1024 * 1024
    public init() {}

    public mutating func record(_ value: BYHistoryRecord, editedTo: BYHistoryVersion?, deleted: Bool, now: Int64, days: Int, pruneImmediately: Bool = true) {
        var record = records.first(where: { $0.key == value.key }) ?? value
        if let previous = value.versions.last, record.versions.last?.sameContent(as: previous) != true {
            record.versions.append(previous)
        }
        if let editedTo, record.versions.last?.sameContent(as: editedTo) != true {
            record.versions.append(editedTo)
        }
        if deleted { record.deletedAt = now }
        record.updatedAt = now
        record.chatTitle = value.chatTitle
        record.author = value.author
        record.versions = Array(record.versions.suffix(Self.maximumVersions))
        records.removeAll { $0.key == record.key }
        records.append(record)
        if pruneImmediately { prune(now: now, days: days) }
    }

    public mutating func prune(now: Int64, days: Int) {
        let cutoff = now - Int64(max(1, min(90, days))) * 86400
        records.removeAll { $0.updatedAt < cutoff }
        records.sort { $0.updatedAt == $1.updatedAt ? $0.key < $1.key : $0.updatedAt < $1.updatedAt }
        if records.count > Self.maximumRecords { records.removeFirst(records.count - Self.maximumRecords) }
        // Bound the actual persisted encoding, including Unicode/escaping overhead.
        while !records.isEmpty, let data = try? JSONEncoder().encode(self), data.count > Self.maximumBytes {
            records.removeFirst(max(1, records.count / 10))
        }
    }

    public func matching(_ query: String, peerId: Int64? = nil, messageId: Int32? = nil, deletedOnly: Bool = false) -> [BYHistoryRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.reversed().filter { record in
            if let peerId, record.peerId != peerId { return false }
            if let messageId, record.messageId != messageId { return false }
            if deletedOnly && record.deletedAt == nil { return false }
            return needle.isEmpty || record.chatTitle.localizedCaseInsensitiveContains(needle)
                || record.author.localizedCaseInsensitiveContains(needle)
                || record.versions.contains { $0.text.localizedCaseInsensitiveContains(needle) || $0.media.contains { $0.localizedCaseInsensitiveContains(needle) } }
        }
    }
}
