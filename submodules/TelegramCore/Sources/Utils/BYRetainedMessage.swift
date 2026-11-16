import Foundation
import Postbox
import SGSimpleSettings

/// Reconstructs a presentation-only message backed exclusively by archived local files.
    /// The server message remains deleted/expired in Postbox.
func byMakeRetainedHistoryMessage(mediaBox: MediaBox, record: BYHistoryRecord, stableId: UInt32, chatPeer: Peer?, noticeText: String, missingMediaText: String) -> Message? {
        guard record.retainedTimed == true, let version = record.versions.last else { return nil }
        let directory = URL(fileURLWithPath: mediaBox.basePath, isDirectory: true).deletingLastPathComponent().appendingPathComponent("by-media-history", isDirectory: true).path
        var media: [Media] = []
        var hasher = Hasher()
        hasher.combine(record.updatedAt)
        hasher.combine(version.text)
        for attachment in version.attachments ?? [] {
            guard let localId = attachment.localId, let url = BYHistoryMediaStorage.fileURL(directoryPath: directory, attachment: attachment) else { continue }
            hasher.combine(localId)
            var resourceHash: UInt64 = 14695981039346656037
            for byte in localId.utf8 { resourceHash = (resourceHash ^ UInt64(byte)) &* 1099511628211 }
            let resourceId = Int64(bitPattern: resourceHash)
            let resource = LocalFileReferenceMediaResource(localFilePath: url.path, randomId: resourceId, isUniquelyReferencedTemporaryFile: false, size: attachment.byteCount)
            let storedMedia: PostboxCoding? = attachment.mediaData.flatMap {
                PostboxDecoder(buffer: MemoryBuffer(data: $0)).decodeRootObject()
            }
            if let image = storedMedia as? TelegramMediaImage {
                let source = image.representations.first(where: { $0.resource.id.stringRepresentation == attachment.resourceId }) ?? image.representations.first
                let representation = TelegramMediaImageRepresentation(
                    dimensions: source?.dimensions ?? PixelDimensions(width: 320, height: 320),
                    resource: resource, progressiveSizes: [], immediateThumbnailData: source?.immediateThumbnailData
                )
                media.append(TelegramMediaImage(
                    imageId: MediaId(namespace: Namespaces.Media.LocalImage, id: resourceId),
                    representations: [representation], immediateThumbnailData: image.immediateThumbnailData,
                    reference: nil, partialReference: nil, flags: []
                ))
            } else {
                let file = storedMedia as? TelegramMediaFile
                var attributes: [TelegramMediaFileAttribute] = [.FileName(fileName: attachment.fileName)]
                for attribute in file?.attributes ?? [] {
                    if case let .Video(duration, size, _, _, _, _) = attribute {
                        // Treat round clips as normal local videos; playback must not depend on a deleted message.
                        attributes.append(.Video(duration: duration, size: size, flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil))
                    }
                }
                media.append(TelegramMediaFile(
                    fileId: MediaId(namespace: Namespaces.Media.LocalFile, id: resourceId), partialReference: nil,
                    resource: resource, previewRepresentations: [], videoThumbnails: [],
                    immediateThumbnailData: file?.immediateThumbnailData, mimeType: attachment.mimeType,
                    size: attachment.byteCount, attributes: attributes, alternativeRepresentations: []
                ))
            }
        }
        let author = record.authorData.flatMap {
            PostboxDecoder(buffer: MemoryBuffer(data: $0)).decodeRootObject() as? Peer
        }
        var peers = SimpleDictionary<PeerId, Peer>()
        if let peer = chatPeer { peers[peer.id] = peer }
        if let author { peers[author.id] = author }
        var text = version.text
        if !text.isEmpty { text += "\n\n" }
        text += noticeText
        if !version.media.isEmpty && media.count < (version.attachments?.count ?? version.media.count) {
            text += "\n" + missingMediaText
        }
        let message = Message(
            stableId: stableId, stableVersion: UInt32(truncatingIfNeeded: hasher.finalize()) | 0x80000000,
            id: MessageId(peerId: PeerId(record.peerId), namespace: record.namespace, id: record.messageId),
            globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: record.threadId,
            timestamp: record.sentAt, flags: [.Incoming], tags: [], globalTags: [], localTags: [], customTags: [],
            forwardInfo: nil, author: author, text: text,
            attributes: [BYLocalMessageNoticeAttribute(kind: .retained, recordKey: record.key)],
            media: media, peers: peers, associatedMessages: SimpleDictionary<MessageId, Message>(),
            associatedMessageIds: [], associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:]
        )
        return message
}

public extension TelegramEngine.Messages {
    func byRetainedHistoryMessage(record: BYHistoryRecord, stableId: UInt32, chatPeer: EnginePeer?, noticeText: String, missingMediaText: String) -> EngineMessage? {
        return byMakeRetainedHistoryMessage(mediaBox: self.account.postbox.mediaBox, record: record, stableId: stableId, chatPeer: chatPeer?._asPeer(), noticeText: noticeText, missingMediaText: missingMediaText).map { EngineMessage($0) }
    }
}
