import Foundation
import Darwin
import XCTest
import SwiftSignalKit
import Postbox
import TelegramApi
import SGSimpleSettings
@testable import TelegramCore

/// Exercise real replay and Postbox, including the C ABI gate used by a signed host.
final class BYPrivacyHistoryTests: StateSyncTestCase {
    private var savedOptions = BYAccountOptions()
    private var savedChats: [BYChatPrivacy] = []
    private var accountId: Int64 { StateSyncFixture.accountPeerId.toInt64() }

    override func setUpWithError() throws {
        try super.setUpWithError()
        if let path = Bundle(for: BYPrivacyHistoryTests.self).executablePath {
            _ = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
        }
        XCTAssertTrue(BYPlugin.isEnabled(.messageHistory), "Test host must export the actual plugin ABI")
        XCTAssertTrue(BYPlugin.isEnabled(.ghostMode))
        self.savedOptions = BYPrivacy.saved(self.accountId)
        self.savedChats = BYPrivacy.savedChats(self.accountId)
        for chat in self.savedChats { BYPrivacy.updateChat(self.accountId, peerId: chat.peerId, title: chat.title, mode: .inherit) }
        BYPrivacy.update(self.accountId) { $0 = BYAccountOptions() }
    }

    override func tearDown() {
        for chat in BYPrivacy.savedChats(self.accountId) { BYPrivacy.updateChat(self.accountId, peerId: chat.peerId, title: chat.title, mode: .inherit) }
        for chat in self.savedChats { BYPrivacy.updateChat(self.accountId, peerId: chat.peerId, title: chat.title, mode: chat.mode) }
        let saved = self.savedOptions
        BYPrivacy.update(self.accountId) { $0 = saved }
        super.tearDown()
    }

    private func history() -> BYHistoryLedger {
        return self.fixture.transaction { transaction in
            transaction.getPreferencesEntry(key: ValueBoxKey("BYPlugin.messageHistory.v1"))?.get(BYHistoryLedger.self) ?? BYHistoryLedger()
        } ?? BYHistoryLedger()
    }

    func testReplayKeepsVersionsAndDeletionWithoutKeepingDeletedChatMessages() {
        let peer = self.seedUserChat(500)
        self.fixture.storeMessage(peerId: peer, id: 12, timestamp: self.baseDate, authorId: peer, text: "original")
        self.launchIdle()
        BYPrivacy.update(self.accountId) { $0.keepEdits = true; $0.keepDeleted = true }
        self.server.push(StateSyncApi.updates([
            .updateEditMessage(.init(message: StateSyncApi.privateMessage(id: 12, peerUserId: 500, fromUserId: 500, date: self.baseDate, text: "edited"), pts: 101, ptsCount: 1))
        ], users: [StateSyncApi.user(id: 500, firstName: "U500")], date: self.baseDate + 20, seq: 0))
        self.drainOperationQueue()
        XCTAssertEqual(self.fixture.message(self.messageId(peer, 12))?.text, "edited")
        XCTAssertEqual(self.history().records.first?.versions.map(\.text), ["original", "edited"])

        self.server.push(StateSyncApi.updates([
            .updateDeleteMessages(.init(messages: [12], pts: 102, ptsCount: 1))
        ], date: self.baseDate + 21, seq: 0))
        self.drainOperationQueue()
        XCTAssertNil(self.fixture.message(self.messageId(peer, 12)))
        XCTAssertEqual(self.fixture.accountState()?.state?.pts, 102)
        XCTAssertEqual(self.history().records.count, 1)
        XCTAssertNotNil(self.history().records.first?.deletedAt)
        XCTAssertEqual(self.history().records.first?.versions.map(\.text), ["original", "edited"])
    }

    func testDisabledHistoryPreservesUpstreamDeletionAndWritesNoArchive() {
        let peer = self.seedUserChat(500)
        self.fixture.storeMessage(peerId: peer, id: 12, timestamp: self.baseDate, authorId: peer, text: "original")
        self.launchIdle()
        self.server.push(StateSyncApi.updates([
            .updateDeleteMessages(.init(messages: [12], pts: 101, ptsCount: 1))
        ], date: self.baseDate + 20, seq: 0))
        self.drainOperationQueue()
        XCTAssertNil(self.fixture.message(self.messageId(peer, 12)))
        XCTAssertEqual(self.fixture.accountState()?.state?.pts, 101)
        XCTAssertTrue(self.history().records.isEmpty)
    }

    func testChannelDeletionDoesNotArchiveAnotherChannelWithTheSameId() {
        let first = self.seedChannel(310, pts: 20, storedMessageId: 12)
        let second = self.seedChannel(311, pts: 20, storedMessageId: 12)
        self.launchIdle()
        BYPrivacy.update(self.accountId) { $0.keepDeleted = true }
        self.server.push(StateSyncApi.updates([
            .updateDeleteChannelMessages(.init(channelId: 310, messages: [12], pts: 21, ptsCount: 1))
        ], chats: [StateSyncApi.broadcastChannel(id: 310)], date: self.baseDate + 20, seq: 0))
        self.drainOperationQueue()
        XCTAssertNil(self.fixture.message(self.messageId(first, 12)))
        XCTAssertNotNil(self.fixture.message(self.messageId(second, 12)))
        XCTAssertEqual(self.fixture.channelState(first)?.pts, 21)
        XCTAssertEqual(self.history().records.map(\.peerId), [first.toInt64()])
    }

    func testGhostReadKeepsUnreadStateAndQueuesNoReceipt() {
        let peer = self.seedUserChat(500)
        self.fixture.seedAccount(state: self.state(pts: 100))
        self.fixture.storeMessage(peerId: peer, id: 12, timestamp: self.baseDate, authorId: peer, text: "unread")
        self.fixture.seedReadState(peerId: peer, maxIncomingReadId: 11, maxOutgoingReadId: 0, maxKnownId: 12, count: 1)
        BYPrivacy.update(self.accountId) { $0.hideReadReceipts = true }
        self.fixture.transaction { transaction -> Void in
            _internal_readPeerHistoryToTopInteractively(transaction: transaction, peer: transaction.getPeer(peer)!, principalNamespace: Namespaces.Message.Cloud)
            XCTAssertEqual(transaction.getPeerReadStates(peer)?.first(where: { $0.0 == Namespaces.Message.Cloud })?.1.count, 1)
        }
        let operation = self.fixture.wait(self.fixture.postbox.synchronizePeerReadStatesView() |> map { $0.operations[peer] }) ?? nil
        XCTAssertNil(operation)

        BYPrivacy.update(self.accountId) { $0.hideReadReceipts = false }
        self.fixture.transaction { transaction -> Void in
            _internal_readPeerHistoryToTopInteractively(transaction: transaction, peer: transaction.getPeer(peer)!, principalNamespace: Namespaces.Message.Cloud)
            XCTAssertEqual(transaction.getPeerReadStates(peer)?.first(where: { $0.0 == Namespaces.Message.Cloud })?.1.count, 0)
        }
    }

    func testPaidMessagesKeepConsumptionAndAreNotArchived() {
        let peer = self.seedUserChat(500)
        self.fixture.seedAccount(state: self.state(pts: 100))
        BYPrivacy.update(self.accountId) { $0.hideReadReceipts = true; $0.keepDeleted = true }
        self.fixture.storeMessage(peerId: peer, id: 12, timestamp: self.baseDate, authorId: peer, text: "paid",
            media: [TelegramMediaPaidContent(amount: 10, extendedMedia: [])])
        self.fixture.storeMessage(peerId: peer, id: 13, timestamp: self.baseDate, authorId: peer, text: "ordinary")
        self.fixture.transaction { transaction -> Void in
            XCTAssertFalse(bySuppressContentRead(transaction: transaction, id: self.messageId(peer, 12)))
            XCTAssertTrue(bySuppressContentRead(transaction: transaction, id: self.messageId(peer, 13)))
            byArchiveDeletedMessages(transaction: transaction, mediaBox: self.fixture.postbox.mediaBox, ids: [self.messageId(peer, 12), self.messageId(peer, 13)])
        }
        XCTAssertEqual(self.history().records.map(\.messageId), [13])
    }
    func testTimedAndViewOnceMessagesKeepConsumptionAndAreNotArchived() {
        let peer = self.seedUserChat(500)
        self.fixture.seedAccount(state: self.state(pts: 100))
        BYPrivacy.update(self.accountId) { $0.hideReadReceipts = true; $0.keepDeleted = true }
        self.fixture.transaction { transaction -> Void in
            for (offset, timeout) in [Int32(5), viewOnceTimeout].enumerated() {
                let id = self.messageId(peer, Int32(offset + 12))
                let message = StoreMessage(id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: nil,
                    timestamp: self.baseDate, flags: [.Incoming], tags: [], globalTags: [], localTags: [],
                    forwardInfo: nil, authorId: peer, text: "timed",
                    attributes: [AutoclearTimeoutMessageAttribute(timeout: timeout, countdownBeginTime: nil)], media: [])
                let _ = transaction.addMessages([message], location: .Random)
                XCTAssertFalse(bySuppressContentRead(transaction: transaction, id: id))
                byArchiveDeletedMessages(transaction: transaction, mediaBox: self.fixture.postbox.mediaBox, ids: [id])
            }
        }
        XCTAssertTrue(self.history().records.isEmpty)
    }

    func testQueuedCloudReceiptCompletesWithoutNetworkSend() {
        let peer = self.seedUserChat(500)
        self.launchIdle()
        self.fixture.storeMessage(peerId: peer, id: 12, timestamp: self.baseDate, authorId: peer, text: "unread")
        self.fixture.seedReadState(peerId: peer, maxIncomingReadId: 11, maxOutgoingReadId: 0, maxKnownId: 12, count: 1)
        self.fixture.transaction { transaction -> Void in
            _internal_readPeerHistoryToTopInteractively(transaction: transaction, peer: transaction.getPeer(peer)!, principalNamespace: Namespaces.Message.Cloud)
        }
        BYPrivacy.update(self.accountId) { $0.hideReadReceipts = true }
        let completed = self.expectation(description: "suppressed receipt completes")
        let disposable = synchronizePeerReadState(network: self.network, postbox: self.fixture.postbox, stateManager: self.stateManager,
            peerId: peer, push: true, validate: false).start(error: { _ in
                XCTFail("suppression must not create a retry")
                completed.fulfill()
            }, completed: { completed.fulfill() })
        self.wait(for: [completed], timeout: 10)
        disposable.dispose()
        XCTAssertFalse(self.server.requestNames.contains("messages.readHistory"))
        let operation = self.fixture.wait(self.fixture.postbox.synchronizePeerReadStatesView() |> map { $0.operations[peer] }) ?? nil
        XCTAssertNil(operation)
        BYPrivacy.update(self.accountId) { $0.hideReadReceipts = false }
        XCTAssertFalse(self.server.requestNames.contains("messages.readHistory"))
    }

    func testLiveLocationReceiptsAreSuppressedForUserAndChannelWithoutReplay() {
        let user = self.seedUserChat(500)
        let channel = self.seedChannel(310, pts: 20, storedMessageId: 12)
        self.fixture.seedAccount(state: self.state(pts: 100))
        self.fixture.storeMessage(peerId: user, id: 12, timestamp: self.baseDate, authorId: user, text: "location")
        self.server.always("messages.readMessageContents") { _ in .result(Api.messages.AffectedMessages.affectedMessages(.init(pts: 100, ptsCount: 0))) }
        self.server.always("channels.readMessageContents") { _ in .result(Api.Bool.boolTrue) }
        BYPrivacy.update(self.accountId) { $0.hideReadReceipts = true }
        for peer in [user, channel] {
            self.completeLiveLocationRead(peer: peer, ids: [12])
        }
        XCTAssertFalse(self.server.requestNames.contains("messages.readMessageContents"))
        XCTAssertFalse(self.server.requestNames.contains("channels.readMessageContents"))

        BYPrivacy.update(self.accountId) { $0.hideReadReceipts = false }
        XCTAssertTrue(self.server.requests.isEmpty, "Switching off must not replay suppressed receipts")
        for peer in [user, channel] {
            self.completeLiveLocationRead(peer: peer, ids: [12])
        }
        XCTAssertEqual(self.server.requestNames.filter { $0 == "messages.readMessageContents" }.count, 1)
        XCTAssertEqual(self.server.requestNames.filter { $0 == "channels.readMessageContents" }.count, 1)
    }

    func testLiveLocationReceiptFilteringPreservesPaidConsumption() {
        let peer = self.seedUserChat(500)
        self.fixture.seedAccount(state: self.state(pts: 100))
        self.fixture.storeMessage(peerId: peer, id: 12, timestamp: self.baseDate, authorId: peer, text: "ordinary")
        self.fixture.storeMessage(peerId: peer, id: 13, timestamp: self.baseDate, authorId: peer, text: "paid",
            media: [TelegramMediaPaidContent(amount: 10, extendedMedia: [])])
        self.server.on("messages.readMessageContents", .result(Api.messages.AffectedMessages.affectedMessages(.init(pts: 100, ptsCount: 0))))
        BYPrivacy.update(self.accountId) { $0.hideReadReceipts = true }
        self.completeLiveLocationRead(peer: peer, ids: [12, 13])
        let requests = self.server.requests.filter { $0.name == "messages.readMessageContents" }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.payload, Api.functions.messages.readMessageContents(id: [13]).1.makeData())
    }

    func testChatOverrideAllowsOnePeerAndKeepsAnotherUnread() {
        let first = self.seedUserChat(500)
        let second = self.seedUserChat(501)
        self.fixture.seedAccount(state: self.state(pts: 100))
        for peer in [first, second] {
            self.fixture.storeMessage(peerId: peer, id: peer == first ? 12 : 13, timestamp: self.baseDate, authorId: peer, text: "unread")
            self.fixture.seedReadState(peerId: peer, maxIncomingReadId: 11, maxOutgoingReadId: 0, maxKnownId: peer == first ? 12 : 13, count: 1)
        }
        BYPrivacy.update(self.accountId) { $0.setGhost(true) }
        BYPrivacy.updateChat(self.accountId, peerId: first.toInt64(), title: "first", mode: .visible)
        self.fixture.transaction { transaction -> Void in
            XCTAssertFalse(bySuppressRead(transaction: transaction, peerId: first))
            XCTAssertTrue(bySuppressRead(transaction: transaction, peerId: second))
            for peer in [first, second] {
                _internal_readPeerHistoryToTopInteractively(transaction: transaction, peer: transaction.getPeer(peer)!, principalNamespace: Namespaces.Message.Cloud)
            }
            XCTAssertEqual(transaction.getPeerReadStates(first)?.first(where: { $0.0 == Namespaces.Message.Cloud })?.1.count, 0)
            XCTAssertEqual(transaction.getPeerReadStates(second)?.first(where: { $0.0 == Namespaces.Message.Cloud })?.1.count, 1)
        }
        XCTAssertTrue(BYPrivacy.effective(self.accountId, peerId: first.toInt64()).hideOnline, "Peer overrides must not change account-wide presence")
        BYPrivacy.update(self.accountId) { $0.setGhost(false) }
        BYPrivacy.updateChat(self.accountId, peerId: second.toInt64(), title: "second", mode: .hidden)
        self.fixture.transaction { transaction -> Void in
            XCTAssertFalse(bySuppressRead(transaction: transaction, peerId: first))
            XCTAssertTrue(bySuppressRead(transaction: transaction, peerId: second))
        }
        BYPrivacy.updateChat(self.accountId, peerId: second.toInt64(), title: "", mode: .inherit)
        self.fixture.transaction { transaction -> Void in
            XCTAssertFalse(bySuppressRead(transaction: transaction, peerId: second))
        }
    }

    func testQueuedReceiptUsesPeerOverrideWithoutReplayingHiddenPeer() {
        let first = self.seedUserChat(500)
        let second = self.seedUserChat(501)
        self.launchIdle()
        for (peer, id) in [(first, Int32(12)), (second, Int32(13))] {
            self.fixture.storeMessage(peerId: peer, id: id, timestamp: self.baseDate, authorId: peer, text: "unread")
            self.fixture.seedReadState(peerId: peer, maxIncomingReadId: 11, maxOutgoingReadId: 0, maxKnownId: id, count: 1)
            self.fixture.transaction { transaction -> Void in
                _internal_readPeerHistoryToTopInteractively(transaction: transaction, peer: transaction.getPeer(peer)!, principalNamespace: Namespaces.Message.Cloud)
            }
        }
        BYPrivacy.update(self.accountId) { $0.hideReadReceipts = true }
        BYPrivacy.updateChat(self.accountId, peerId: first.toInt64(), title: "first", mode: .visible)
        self.server.always("messages.readHistory") { _ in
            .result(Api.messages.AffectedMessages.affectedMessages(.init(pts: 100, ptsCount: 0)))
        }
        for peer in [first, second] {
            let done = self.expectation(description: "queued peer receipt completes")
            let disposable = synchronizePeerReadState(network: self.network, postbox: self.fixture.postbox, stateManager: self.stateManager, peerId: peer, push: true, validate: false)
                .start(error: { _ in XCTFail("must not retry"); done.fulfill() }, completed: { done.fulfill() })
            self.wait(for: [done], timeout: 10)
            disposable.dispose()
        }
        let sent = self.server.requests.filter { $0.name == "messages.readHistory" }
        XCTAssertEqual(sent.count, 1)
        if let peer = self.fixture.transaction({ $0.getPeer(first).flatMap(apiInputPeer) }) ?? nil {
            XCTAssertEqual(sent.first?.payload, Api.functions.messages.readHistory(peer: peer, maxId: 12).1.makeData())
        } else { XCTFail("missing test peer") }
        BYPrivacy.update(self.accountId) { $0.hideReadReceipts = false }
        XCTAssertEqual(self.server.requestNames.filter { $0 == "messages.readHistory" }.count, 1)
        let operation = self.fixture.wait(self.fixture.postbox.synchronizePeerReadStatesView() |> map { $0.operations[second] }) ?? nil
        XCTAssertNil(operation)
    }

    func testDeletionSnapshotKeepsThreadAndStableIdentityWithoutReinsertingMessage() {
        let peer = self.seedChannel(310, pts: 20, storedMessageId: nil)
        self.fixture.seedAccount(state: self.state(pts: 100))
        BYPrivacy.update(self.accountId) { $0.keepDeleted = true }
        let id = self.messageId(peer, 12)
        self.fixture.transaction { transaction -> Void in
            let value = StoreMessage(id: id, customStableId: nil, globallyUniqueId: nil, groupingKey: nil, threadId: 77,
                timestamp: self.baseDate, flags: [.Incoming], tags: [], globalTags: [], localTags: [],
                forwardInfo: nil, authorId: peer, text: "thread message", attributes: [], media: [])
            let _ = transaction.addMessages([value], location: .Random)
            let stableId = transaction.getMessage(id)?.stableId
            byArchiveDeletedMessages(transaction: transaction, mediaBox: self.fixture.postbox.mediaBox, ids: [id])
            transaction.deleteMessages([id], forEachMedia: nil)
            let ledger = transaction.getPreferencesEntry(key: ValueBoxKey("BYPlugin.messageHistory.v1"))?.get(BYHistoryLedger.self)
            XCTAssertEqual(ledger?.records.first?.threadId, 77)
            XCTAssertEqual(ledger?.records.first?.originalStableId, stableId)
            XCTAssertNil(transaction.getMessage(id))
        }
    }

    func testMarkerIdentityRoundTripsThroughPostboxIncludingUnsignedMaximum() {
        let peer = self.seedUserChat(500)
        let record = BYHistoryRecord(peerId: peer.toInt64(), namespace: Namespaces.Message.Cloud, messageId: 12,
            chatTitle: "chat", author: "sender", sentAt: self.baseDate,
            version: BYHistoryVersion(text: "original", media: [], timestamp: Int64(self.baseDate)),
            threadId: 77, originalStableId: UInt32.max)
        var ledger = BYHistoryLedger()
        ledger.records = [record]
        self.fixture.transaction { transaction -> Void in
            let key = ValueBoxKey("BYPlugin.messageHistory.v1")
            transaction.setPreferencesEntry(key: key, value: PreferencesEntry(ledger))
        }
        XCTAssertEqual(self.history(), ledger, "Use the real signed-integer Postbox Codable adapter, not just JSON")
        XCTAssertEqual(self.history().records.first?.originalStableId, UInt32.max)
    }

    func testAdRequestsRecheckPolicyAtSubscriptionAndPreservePayloadWhenOff() {
        let user = self.seedUserChat(500)
        let channel = self.seedChannel(310, pts: 20, storedMessageId: nil)
        self.server.always("messages.getSponsoredMessages") { _ in .error(code: 400, text: "AD_NOT_FOUND") }
        self.server.always("contacts.getSponsoredPeers") { _ in .error(code: 400, text: "AD_NOT_FOUND") }
        for peerId in [user, channel] {
            guard let peer = self.fixture.transaction({ $0.getPeer(peerId).flatMap(apiInputPeer) }) ?? nil else {
                XCTFail("missing ad test peer"); continue
            }
            for messageId: Int32? in [nil, 12] {
                BYPrivacy.update(self.accountId) { $0.hideSponsoredMessages = false }
                let request = byRequestSponsoredMessages(accountPeerId: StateSyncFixture.accountPeerId, network: self.network, peer: peer, messageId: messageId)
                BYPrivacy.update(self.accountId) { $0.hideSponsoredMessages = true }
                _ = self.fixture.wait(request)
                XCTAssertFalse(self.server.requestNames.contains("messages.getSponsoredMessages"))
            }
        }
        let search = byRequestSponsoredPeers(accountPeerId: StateSyncFixture.accountPeerId, network: self.network, query: "telegram")
        _ = self.fixture.wait(search)
        XCTAssertFalse(self.server.requestNames.contains("contacts.getSponsoredPeers"))

        BYPrivacy.update(self.accountId) { $0.hideSponsoredMessages = false }
        guard let peer = self.fixture.transaction({ $0.getPeer(channel).flatMap(apiInputPeer) }) ?? nil else {
            XCTFail("missing channel"); return
        }
        _ = self.fixture.wait(byRequestSponsoredMessages(accountPeerId: StateSyncFixture.accountPeerId, network: self.network, peer: peer, messageId: 12))
        _ = self.fixture.wait(byRequestSponsoredPeers(accountPeerId: StateSyncFixture.accountPeerId, network: self.network, query: "telegram"))
        let ads = self.server.requests.filter { $0.name == "messages.getSponsoredMessages" }
        XCTAssertEqual(ads.count, 1)
        XCTAssertEqual(ads.first?.payload, Api.functions.messages.getSponsoredMessages(flags: 1, peer: peer, msgId: 12).1.makeData())
        let searches = self.server.requests.filter { $0.name == "contacts.getSponsoredPeers" }
        XCTAssertEqual(searches.count, 1)
        XCTAssertEqual(searches.first?.payload, Api.functions.contacts.getSponsoredPeers(q: "telegram").1.makeData())
    }


    private func historyResource(_ id: Int64) -> CloudDocumentMediaResource {
        return CloudDocumentMediaResource(datacenterId: 2, fileId: id, accessHash: 1, size: 5, fileReference: nil, fileName: "sample.bin")
    }

    private func historyPhoto(_ resource: TelegramMediaResource) -> TelegramMediaImage {
        return TelegramMediaImage(imageId: MediaId(namespace: Namespaces.Media.CloudImage, id: 101),
            representations: [TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 640, height: 480), resource: resource, progressiveSizes: [], immediateThumbnailData: nil)],
            immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
    }

    private func historyFile(_ resource: TelegramMediaResource, video: Bool) -> TelegramMediaFile {
        var attributes: [TelegramMediaFileAttribute] = [.FileName(fileName: video ? "clip.mp4" : "report.pdf")]
        if video {
            attributes.append(.Video(duration: 2.0, size: PixelDimensions(width: 640, height: 480), flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil))
        }
        return TelegramMediaFile(fileId: MediaId(namespace: Namespaces.Media.CloudFile, id: video ? 201 : 202), partialReference: nil,
            resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil,
            mimeType: video ? "video/mp4" : "application/pdf", size: 5, attributes: attributes, alternativeRepresentations: [])
    }

    private func storeTimed(peer: PeerId, id: Int32, media: [Media], attributes: [MessageAttribute], incoming: Bool = true) {
        self.fixture.transaction { transaction -> Void in
            let message = StoreMessage(id: self.messageId(peer, id), customStableId: nil, globallyUniqueId: nil,
                groupingKey: nil, threadId: nil, timestamp: self.baseDate, flags: incoming ? [.Incoming] : [],
                tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: peer,
                text: "timed caption", attributes: attributes, media: media)
            let _ = transaction.addMessages([message], location: .UpperHistoryBlock)
        }
    }

    func testReplayArchivesPhotoVideoAndDocumentBytesAfterCacheRemoval() throws {
        let peer = self.seedUserChat(500)
        let resources = [self.historyResource(901), self.historyResource(902), self.historyResource(903)]
        let media: [Media] = [self.historyPhoto(resources[0]), self.historyFile(resources[1], video: true), self.historyFile(resources[2], video: false)]
        let bytes = Data([0, 1, 2, 3, 255])
        for (index, item) in media.enumerated() {
            self.fixture.postbox.mediaBox.storeResourceData(resources[index].id, data: bytes, synchronous: true)
            self.fixture.storeMessage(peerId: peer, id: 12 + Int32(index), timestamp: self.baseDate, authorId: peer, text: "caption", media: [item])
        }
        self.launchIdle()
        BYPrivacy.update(self.accountId) { $0.keepDeleted = true; $0.keepMedia = true }
        self.server.push(StateSyncApi.updates([
            .updateDeleteMessages(.init(messages: [12, 13, 14], pts: 103, ptsCount: 3))
        ], date: self.baseDate + 20, seq: 0))
        self.drainOperationQueue()
        XCTAssertEqual(self.fixture.accountState()?.state?.pts, 103)
        for id: Int32 in 12 ... 14 { XCTAssertNil(self.fixture.message(self.messageId(peer, id))) }
        _ = self.fixture.wait(self.fixture.postbox.mediaBox.removeCachedResources(resources.map(\.id), force: true) |> filter { $0 == 1.0 })
        let ledger = self.history()
        XCTAssertEqual(ledger.records.count, 3)
        let storage = byHistoryMediaStorage(mediaBox: self.fixture.postbox.mediaBox, ledger: ledger)
        for record in ledger.records {
            let attachment = try XCTUnwrap(record.versions.last?.attachments?.first)
            XCTAssertNotNil(attachment.localId)
            let url = try XCTUnwrap(storage.fileURL(for: attachment))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertNotNil(attachment.mediaData)
            XCTAssertNotNil(record.authorData)
            let projected = try XCTUnwrap(byMakeRetainedHistoryMessage(mediaBox: self.fixture.postbox.mediaBox, record: record, stableId: 42, chatPeer: nil, noticeText: "local", missingMediaText: "missing"))
            XCTAssertEqual(projected.id.id, record.messageId)
            XCTAssertEqual(projected.timestamp, record.sentAt)
            XCTAssertEqual(projected.byLocalNotice?.kind, .retained)
            XCTAssertFalse(projected.media.isEmpty)
            XCTAssertNil(self.fixture.message(self.messageId(peer, record.messageId)))
            var editedOnly = record
            editedOnly.deletedAt = nil
            XCTAssertNil(byMakeRetainedHistoryMessage(mediaBox: self.fixture.postbox.mediaBox, record: editedOnly, stableId: 42, chatPeer: nil, noticeText: "local", missingMediaText: "missing"))
        }
        for resource in resources { XCTAssertNil(self.fixture.postbox.mediaBox.completedResourcePath(resource)) }
    }

    func testTimedAutoclearKeepsLocalPhotoWhileCanonicalMediaExpires() throws {
        let peer = self.seedUserChat(500)
        self.fixture.seedAccount(state: self.state(pts: 100))
        BYPrivacy.update(self.accountId) { $0.retainTimed = true; $0.keepMedia = false }
        let resource = self.historyResource(911)
        let bytes = Data([5, 4, 3, 2, 1])
        self.fixture.postbox.mediaBox.storeResourceData(resource.id, data: bytes, synchronous: true)
        self.storeTimed(peer: peer, id: 12, media: [self.historyPhoto(resource)],
            attributes: [AutoclearTimeoutMessageAttribute(timeout: 1, countdownBeginTime: self.baseDate)])
        let disposable = managedAutoremoveMessageOperations(network: self.network, postbox: self.fixture.postbox, isRemove: false).start()
        defer { disposable.dispose() }
        self.fixture.eventually { self.fixture.message(self.messageId(peer, 12))?.media.first is TelegramMediaExpiredContent }
        let record = try XCTUnwrap(self.history().records.first)
        XCTAssertEqual(record.retainedTimed, true)
        XCTAssertNotNil(record.deletedAt)
        let peerValue = self.fixture.transaction { $0.getPeer(peer) } ?? nil
        let projected = try XCTUnwrap(byMakeRetainedHistoryMessage(mediaBox: self.fixture.postbox.mediaBox, record: record, stableId: 42, chatPeer: peerValue, noticeText: "local", missingMediaText: "missing"))
        XCTAssertEqual(projected.id, self.messageId(peer, 12))
        XCTAssertEqual(projected.author?.id, peer)
        XCTAssertTrue(projected.text.contains("timed caption"))
        XCTAssertEqual(projected.byLocalNotice?.kind, .retained)
        XCTAssertFalse(projected.containsSecretMedia)
        let image = try XCTUnwrap(projected.media.first as? TelegramMediaImage)
        let local = try XCTUnwrap(image.representations.first?.resource as? LocalFileReferenceMediaResource)
        _ = self.fixture.wait(self.fixture.postbox.mediaBox.removeCachedResources([resource.id], force: true) |> filter { $0 == 1.0 })
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: local.localFilePath)), bytes)
        XCTAssertTrue(self.fixture.message(self.messageId(peer, 12))?.media.first is TelegramMediaExpiredContent)
    }

    func testTimedAutoremoveKeepsTextWithoutReinsertingDeletedMessage() throws {
        let peer = self.seedUserChat(500)
        self.fixture.seedAccount(state: self.state(pts: 100))
        BYPrivacy.update(self.accountId) { $0.retainTimed = true }
        self.storeTimed(peer: peer, id: 12, media: [], attributes: [AutoremoveTimeoutMessageAttribute(timeout: 1, countdownBeginTime: self.baseDate)])
        let disposable = managedAutoremoveMessageOperations(network: self.network, postbox: self.fixture.postbox, isRemove: true).start()
        defer { disposable.dispose() }
        self.fixture.eventually { self.fixture.message(self.messageId(peer, 12)) == nil }
        let record = try XCTUnwrap(self.history().records.first)
        let projected = try XCTUnwrap(byMakeRetainedHistoryMessage(mediaBox: self.fixture.postbox.mediaBox, record: record, stableId: 42, chatPeer: nil, noticeText: "local", missingMediaText: "missing"))
        XCTAssertTrue(projected.text.hasPrefix("timed caption"))
        XCTAssertTrue(projected.media.isEmpty)
        XCTAssertNil(self.fixture.message(self.messageId(peer, 12)))
        XCTAssertEqual(self.fixture.accountState()?.state?.pts, 100)
    }

    func testRemoteViewOnceConsumptionPreservesVideoAndStillConsumes() throws {
        let peer = self.seedUserChat(500)
        self.fixture.seedAccount(state: self.state(pts: 100))
        BYPrivacy.update(self.accountId) { $0.retainTimed = true; $0.hideReadReceipts = true }
        let resource = self.historyResource(921)
        self.fixture.postbox.mediaBox.storeResourceData(resource.id, data: Data([1, 2, 3, 4, 5]), synchronous: true)
        self.storeTimed(peer: peer, id: 12, media: [self.historyFile(resource, video: true)],
            attributes: [AutoclearTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil), ConsumableContentMessageAttribute(consumed: false)])
        self.fixture.transaction { transaction -> Void in
            markMessageContentAsConsumedRemotely(transaction: transaction, mediaBox: self.fixture.postbox.mediaBox, messageId: self.messageId(peer, 12), consumeDate: self.baseDate)
        }
        let canonical = try XCTUnwrap(self.fixture.message(self.messageId(peer, 12)))
        XCTAssertTrue(canonical.media.first is TelegramMediaExpiredContent)
        XCTAssertEqual((canonical.attributes.first { $0 is ConsumableContentMessageAttribute } as? ConsumableContentMessageAttribute)?.consumed, true)
        let record = try XCTUnwrap(self.history().records.first)
        XCTAssertNotNil(record.versions.last?.attachments?.first?.localId)
        let projected = try XCTUnwrap(byMakeRetainedHistoryMessage(mediaBox: self.fixture.postbox.mediaBox, record: record, stableId: 42, chatPeer: nil, noticeText: "local", missingMediaText: "missing"))
        let file = try XCTUnwrap(projected.media.first as? TelegramMediaFile)
        XCTAssertTrue(file.isVideo)
        XCTAssertTrue(file.resource is LocalFileReferenceMediaResource)
        XCTAssertFalse(projected.containsSecretMedia)
    }

    func testTimedRetentionRequiresOptInAndExcludesPaidAndOutgoingContent() {
        let peer = self.seedUserChat(500)
        self.fixture.seedAccount(state: self.state(pts: 100))
        let timer = AutoclearTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil)
        self.storeTimed(peer: peer, id: 12, media: [], attributes: [timer])
        self.fixture.transaction { transaction -> Void in
            byCaptureTimedMessage(transaction: transaction, mediaBox: self.fixture.postbox.mediaBox, message: transaction.getMessage(self.messageId(peer, 12))!)
        }
        XCTAssertTrue(self.history().records.isEmpty)
        BYPrivacy.update(self.accountId) { $0.retainTimed = true; $0.keepDeleted = true }
        self.storeTimed(peer: peer, id: 13, media: [TelegramMediaPaidContent(amount: 10, extendedMedia: [])], attributes: [timer])
        self.storeTimed(peer: peer, id: 14, media: [], attributes: [timer], incoming: false)
        self.fixture.transaction { transaction -> Void in
            for id: Int32 in 13 ... 14 {
                byCaptureTimedMessage(transaction: transaction, mediaBox: self.fixture.postbox.mediaBox, message: transaction.getMessage(self.messageId(peer, id))!)
            }
            byArchiveDeletedMessages(transaction: transaction, mediaBox: self.fixture.postbox.mediaBox, ids: [self.messageId(peer, 13)])
        }
        XCTAssertTrue(self.history().records.isEmpty)
    }

    func testUnavailableTimedMediaRemainsAnExplicitMissingFile() throws {
        let peer = self.seedUserChat(500)
        self.fixture.seedAccount(state: self.state(pts: 100))
        BYPrivacy.update(self.accountId) { $0.retainTimed = true }
        self.storeTimed(peer: peer, id: 12, media: [self.historyPhoto(self.historyResource(931))],
            attributes: [AutoclearTimeoutMessageAttribute(timeout: viewOnceTimeout, countdownBeginTime: nil)])
        self.fixture.transaction { transaction -> Void in
            byCaptureTimedMessage(transaction: transaction, mediaBox: self.fixture.postbox.mediaBox, message: transaction.getMessage(self.messageId(peer, 12))!)
        }
        let record = try XCTUnwrap(self.history().records.first)
        XCTAssertNil(record.versions.last?.attachments?.first?.localId)
        let projected = try XCTUnwrap(byMakeRetainedHistoryMessage(mediaBox: self.fixture.postbox.mediaBox, record: record, stableId: 42, chatPeer: nil, noticeText: "local", missingMediaText: "missing"))
        XCTAssertTrue(projected.media.isEmpty)
        XCTAssertTrue(projected.text.contains("missing"))
    }

    private func completeLiveLocationRead(peer: PeerId, ids: [Int32]) {
        guard let request = self.fixture.transaction({ transaction in
            synchronizeSeenLiveLocations(transaction: transaction, network: self.network, peerId: peer,
                messageIds: ids.map { self.messageId(peer, $0) })
        }) else { return }
        let done = self.expectation(description: "live location receipt completes")
        let disposable = request.start(completed: { done.fulfill() })
        self.wait(for: [done], timeout: 10)
        disposable.dispose()
    }

}
