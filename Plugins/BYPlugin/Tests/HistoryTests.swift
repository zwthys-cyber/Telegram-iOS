import Foundation

@main
struct HistoryTests {
    static func main() throws {
        let now: Int64 = 2000000000
        func snapshot(_ peer: Int64, _ id: Int32, _ text: String, at: Int64? = nil) -> BYHistoryRecord {
            return BYHistoryRecord(peerId: peer, namespace: 0, messageId: id, chatTitle: "Chat", author: "Author", sentAt: 1,
                version: BYHistoryVersion(text: text, media: ["document.pdf"], timestamp: at ?? now))
        }
        var ledger = BYHistoryLedger()
        let original = snapshot(1, 42, "original")
        ledger.record(original, editedTo: BYHistoryVersion(text: "edited", media: [], timestamp: now + 1), deleted: false, now: now + 1, days: 30)
        ledger.record(snapshot(1, 42, "edited"), editedTo: nil, deleted: true, now: now + 2, days: 30)
        // Another channel reuses the same message ID without overwriting the first chat.
        ledger.record(snapshot(2, 42, "other chat"), editedTo: nil, deleted: true, now: now + 3, days: 30)
        precondition(ledger.records.count == 2)
        precondition(ledger.matching("original").count == 1)
        precondition(ledger.matching("", peerId: 1, deletedOnly: true).count == 1)
        let restored = try JSONDecoder().decode(BYHistoryLedger.self, from: JSONEncoder().encode(ledger))
        precondition(restored == ledger)
        for revision in 0 ..< 25 {
            ledger.record(snapshot(3, 1, "v\(revision)"), editedTo: nil, deleted: false, now: now + Int64(revision), days: 30)
        }
        precondition(ledger.records.first(where: { $0.peerId == 3 })!.versions.count == 10)
        ledger.prune(now: now + 91 * 86400, days: 90)
        precondition(ledger.records.isEmpty)
        for id: Int32 in 0 ..< 700 {
            ledger.record(snapshot(4, id, "bounded"), editedTo: nil, deleted: true, now: now + Int64(id), days: 30)
        }
        precondition(ledger.records.count == 500)
        let long = String(repeating: "文\n", count: 20000)
        for id: Int32 in 0 ..< 100 {
            ledger.record(snapshot(5, id, long), editedTo: nil, deleted: true, now: now + 1000 + Int64(id), days: 30)
        }
        let boundedData = try JSONEncoder().encode(ledger)
        precondition(boundedData.count <= BYHistoryLedger.maximumBytes)
        precondition(ledger.records.last?.versions.last?.truncated == true)
        var scoped = BYHistoryLedger()
        for (peer, id, thread, stamp) in [(Int64(1), Int32(10), Int64(77), Int32(100)), (1, 11, 77, 101), (1, 12, 78, 102), (2, 11, 77, 101)] {
            let record = BYHistoryRecord(peerId: peer, namespace: 0, messageId: id, chatTitle: "Chat", author: "Author", sentAt: stamp,
                version: BYHistoryVersion(text: "old", media: [], timestamp: now), threadId: thread, originalStableId: UInt32(id))
            scoped.record(record, editedTo: nil, deleted: true, now: now, days: 30)
        }
        let selected = scoped.deletionMarkers(peerId: 1, namespace: 0, threadId: 77,
            lower: BYHistoryPosition(timestamp: 101, messageId: 11), upper: nil, existingMessageIds: [], now: now, days: 30)
        precondition(selected.map(\.messageId) == [11])
        precondition(selected.first?.originalStableId == 11)
        precondition(scoped.deletionMarkers(peerId: 1, namespace: 0, threadId: 77, lower: nil, upper: nil, existingMessageIds: [10, 11], now: now, days: 30).isEmpty)
        precondition(scoped.deletionMarkers(peerId: 1, namespace: 0, threadId: nil, lower: nil, upper: BYHistoryPosition(timestamp: 101, messageId: 10), existingMessageIds: [], now: now, days: 30).map(\.messageId) == [10])
        precondition(scoped.deletionMarkers(peerId: 1, namespace: 0, threadId: nil, lower: nil, upper: nil, existingMessageIds: [], now: now + 31 * 86400, days: 30).isEmpty)
        // Old persisted records have no thread/stable-id fields and remain readable.
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected[0])) as! [String: Any]
        object.removeValue(forKey: "threadId")
        object.removeValue(forKey: "originalStableId")
        let legacyRecord = try JSONDecoder().decode(BYHistoryRecord.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(legacyRecord.messageId == 11 && legacyRecord.threadId == nil && legacyRecord.originalStableId == nil)

        // Retained timed content survives age pruning and is never silently evicted for a new capture.
        var retained = BYHistoryLedger()
        for id: Int32 in 0 ..< 500 {
            var value = snapshot(20, id, "kept")
            value.retainedTimed = true
            precondition(retained.record(value, editedTo: nil, deleted: false, now: now, days: 7))
        }
        retained.prune(now: now + 365 * 86400, days: 7)
        precondition(retained.records.count == 500)
        let before = retained
        var excess = snapshot(20, 501, "over capacity")
        excess.retainedTimed = true
        precondition(!retained.record(excess, editedTo: nil, deleted: false, now: now, days: 7))
        precondition(retained == before)
        precondition(retained.deletionMarkers(peerId: 20, namespace: 0, threadId: nil, lower: nil, upper: nil, existingMessageIds: [1], now: now + 365 * 86400, days: 7, includeDeleted: false, includeRetainedTimed: true).count == 499)
        precondition(retained.deletionMarkers(peerId: 21, namespace: 0, threadId: nil, lower: nil, upper: nil, existingMessageIds: [], now: now, days: 7, includeDeleted: false, includeRetainedTimed: true).isEmpty)
        let low = BYHistoryAttachment(resourceId: "thumb", fileName: "Photo.jpg", mimeType: "image/jpeg", localId: "low.jpg", byteCount: 10, mediaData: Data([1, 2, 3]))
        let high = BYHistoryAttachment(resourceId: "full", fileName: "Photo.jpg", mimeType: "image/jpeg", localId: "high.jpg", byteCount: 100, mediaData: Data([4, 5]))
        let missing = BYHistoryAttachment(resourceId: "full", fileName: "Photo.jpg", mimeType: "image/jpeg", localId: nil, byteCount: 0)
        var version = BYHistoryVersion(text: "", media: ["photo"], timestamp: now, attachments: [low])
        version.mergeAttachments(from: BYHistoryVersion(text: "", media: ["photo"], timestamp: now, attachments: [high]))
        version.mergeAttachments(from: BYHistoryVersion(text: "", media: ["photo"], timestamp: now, attachments: [missing]))
        precondition(version.attachments == [high])
        precondition(try! JSONDecoder().decode(BYHistoryVersion.self, from: JSONEncoder().encode(version)) == version)
        var legacyVersion = try JSONSerialization.jsonObject(with: JSONEncoder().encode(version)) as! [String: Any]
        legacyVersion.removeValue(forKey: "attachments")
        precondition(try! JSONDecoder().decode(BYHistoryVersion.self, from: JSONSerialization.data(withJSONObject: legacyVersion)).attachments == nil)
        var bytesLedger = BYHistoryLedger()
        for id: Int32 in 0 ..< 200 {
            var value = snapshot(30, id, String(repeating: "文", count: 16384))
            value.retainedTimed = true
            let prior = bytesLedger
            if !bytesLedger.record(value, editedTo: nil, deleted: false, now: now, days: 7) {
                precondition(bytesLedger == prior)
                break
            }
        }
        precondition(bytesLedger.records.count < 200)
        precondition(try! JSONEncoder().encode(bytesLedger).count <= BYHistoryLedger.maximumBytes)

        print("History: persistence, search, namespace isolation, versions, retention, byte budget and deletion-marker windows passed")
    }
}
