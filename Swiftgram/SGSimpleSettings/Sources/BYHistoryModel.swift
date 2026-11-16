import Foundation

/// A local attachment reference; only opaque archive names are persisted.
public struct BYHistoryAttachment: Codable, Equatable {
    public let resourceId: String
    public let fileName: String
    public let mimeType: String
    public let localId: String?
    public let byteCount: Int64
    public let mediaData: Data?
    public init(resourceId: String, fileName: String, mimeType: String, localId: String?, byteCount: Int64, mediaData: Data? = nil) {
        self.resourceId = String(resourceId.prefix(512))
        self.fileName = String(fileName.prefix(200))
        self.mimeType = String(mimeType.prefix(128))
        self.localId = localId
        self.byteCount = max(0, byteCount)
        self.mediaData = mediaData.flatMap { $0.count <= 32768 ? $0 : nil }
    }
}

/// A bounded local ledger; attachment bytes live in the account's separate archive.
public struct BYHistoryVersion: Codable, Equatable {
    public let text: String
    public let media: [String]
    public let timestamp: Int64
    public let truncated: Bool
    public var attachments: [BYHistoryAttachment]?

    public init(text: String, media: [String], timestamp: Int64, attachments: [BYHistoryAttachment] = []) {
        self.text = String(text.prefix(16384))
        self.media = Array(media.prefix(20)).map { String($0.prefix(1024)) }
        self.timestamp = timestamp
        self.attachments = attachments.isEmpty ? nil : Array(attachments.prefix(20))
        self.truncated = self.text != text || self.media != media
    }

    public mutating func mergeAttachments(from other: BYHistoryVersion) {
        var merged = self.attachments ?? []
        for (index, attachment) in (other.attachments ?? []).enumerated() {
            // sameContent pins media order/identity. A better downloaded photo
            // representation replaces its earlier capture instead of adding a duplicate image.
            if index < merged.count {
                if merged[index].localId == nil || (attachment.localId != nil && attachment.byteCount >= merged[index].byteCount) {
                    merged[index] = attachment
                }
            } else if merged.count < 20 {
                merged.append(attachment)
            }
        }
        self.attachments = merged.isEmpty ? nil : merged
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
    public var threadId: Int64?
    public var retainedTimed: Bool?
    public var authorData: Data?
    // Postbox's Codable adapter supports signed integers only.
    private var encodedOriginalStableId: Int64?
    public var originalStableId: UInt32? {
        get { self.encodedOriginalStableId.flatMap { UInt32(exactly: $0) } }
        set { self.encodedOriginalStableId = newValue.map(Int64.init) }
    }
    private enum CodingKeys: String, CodingKey {
        case peerId, namespace, messageId, chatTitle, author, sentAt, threadId, retainedTimed, authorData
        case encodedOriginalStableId = "originalStableId"
        case deletedAt, versions, updatedAt
    }
    public var deletedAt: Int64?
    public var versions: [BYHistoryVersion]
    public var updatedAt: Int64

    public var key: String { "\(peerId):\(namespace):\(messageId)" }
    public init(peerId: Int64, namespace: Int32, messageId: Int32, chatTitle: String, author: String, sentAt: Int32, version: BYHistoryVersion, threadId: Int64? = nil, originalStableId: UInt32? = nil, retainedTimed: Bool = false, authorData: Data? = nil) {
        self.peerId = peerId
        self.namespace = namespace
        self.messageId = messageId
        self.chatTitle = String(chatTitle.prefix(512))
        self.author = String(author.prefix(512))
        self.sentAt = sentAt
        self.threadId = threadId
        self.retainedTimed = retainedTimed ? true : nil
        self.authorData = authorData.flatMap { $0.count <= 16384 ? $0 : nil }
        self.encodedOriginalStableId = originalStableId.map(Int64.init)
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

    @discardableResult
    public mutating func record(_ value: BYHistoryRecord, editedTo: BYHistoryVersion?, deleted: Bool, now: Int64, days: Int, pruneImmediately: Bool = true) -> Bool {
        let previousLedger = self
        var record = records.first(where: { $0.key == value.key }) ?? value
        if let previous = value.versions.last {
            if record.versions.last?.sameContent(as: previous) == true, !record.versions.isEmpty {
                record.versions[record.versions.count - 1].mergeAttachments(from: previous)
            } else {
                record.versions.append(previous)
            }
        }
        if let editedTo, record.versions.last?.sameContent(as: editedTo) != true {
            record.versions.append(editedTo)
        }
        if deleted { record.deletedAt = now }
        record.updatedAt = now
        record.chatTitle = value.chatTitle
        record.author = value.author
        if let authorData = value.authorData { record.authorData = authorData }
        record.threadId = value.threadId
        record.originalStableId = value.originalStableId
        if value.retainedTimed == true { record.retainedTimed = true }
        record.versions = Array(record.versions.suffix(Self.maximumVersions))
        records.removeAll { $0.key == record.key }
        records.append(record)
        if pruneImmediately || record.retainedTimed == true {
            prune(now: now, days: days)
            if records.count > Self.maximumRecords || ((try? JSONEncoder().encode(self).count) ?? Int.max) > Self.maximumBytes {
                // Reject the new capture rather than silently deleting retained timed content.
                self = previousLedger
                return false
            }
        }
        return true
    }

    public mutating func prune(now: Int64, days: Int) {
        let cutoff = now - Int64(max(1, min(90, days))) * 86400
        records.removeAll { $0.retainedTimed != true && $0.updatedAt < cutoff }
        records.sort { $0.updatedAt == $1.updatedAt ? $0.key < $1.key : $0.updatedAt < $1.updatedAt }
        while records.count > Self.maximumRecords, let index = records.firstIndex(where: { $0.retainedTimed != true }) {
            records.remove(at: index)
        }
        // Bound the actual persisted encoding, including Unicode/escaping overhead.
        while !records.isEmpty, let data = try? JSONEncoder().encode(self), data.count > Self.maximumBytes {
            let removable = records.indices.filter { records[$0].retainedTimed != true }
            guard !removable.isEmpty else { break }
            for index in removable.prefix(max(1, records.count / 10)).reversed() { records.remove(at: index) }
        }
    }

    public var attachments: [BYHistoryAttachment] {
        var seen = Set<String>()
        return records.flatMap(\.versions).flatMap { $0.attachments ?? [] }.filter {
            guard let localId = $0.localId else { return false }
            return seen.insert(localId).inserted
        }
    }

    public var mediaByteCount: Int64 { attachments.reduce(0) { $0 + $1.byteCount } }

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


public struct BYHistoryPosition: Comparable {
    public let timestamp: Int32
    public let messageId: Int32
    public init(timestamp: Int32, messageId: Int32) {
        self.timestamp = timestamp
        self.messageId = messageId
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        return lhs.timestamp == rhs.timestamp ? lhs.messageId < rhs.messageId : lhs.timestamp < rhs.timestamp
    }
}

public extension BYHistoryLedger {
    /// Only project archived deletions into the loaded chat window; never fill a database hole.
    func deletionMarkers(peerId: Int64, namespace: Int32, threadId: Int64?, lower: BYHistoryPosition?, upper: BYHistoryPosition?, existingMessageIds: Set<Int32>, now: Int64, days: Int, includeDeleted: Bool = true, includeRetainedTimed: Bool = false) -> [BYHistoryRecord] {
        let cutoff = now - Int64(max(1, min(90, days))) * 86400
        return self.records.filter { record in
            guard record.peerId == peerId, record.namespace == namespace,
                  (includeDeleted && record.deletedAt != nil) || (includeRetainedTimed && record.retainedTimed == true),
                  record.retainedTimed == true || record.updatedAt >= cutoff,
                  !existingMessageIds.contains(record.messageId) else { return false }
            if let threadId, record.threadId != threadId { return false }
            let position = BYHistoryPosition(timestamp: record.sentAt, messageId: record.messageId)
            if let lower, position < lower { return false }
            if let upper, upper < position { return false }
            return true
        }.sorted {
            BYHistoryPosition(timestamp: $0.sentAt, messageId: $0.messageId) < BYHistoryPosition(timestamp: $1.sentAt, messageId: $1.messageId)
        }
    }
}
