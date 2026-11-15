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
    private var accountId: Int64 { StateSyncFixture.accountPeerId.toInt64() }

    override func setUpWithError() throws {
        try super.setUpWithError()
        if let path = Bundle(for: BYPrivacyHistoryTests.self).executablePath {
            _ = dlopen(path, RTLD_NOW | RTLD_GLOBAL)
        }
        XCTAssertTrue(BYPlugin.isEnabled(.messageHistory), "Test host must export the actual plugin ABI")
        XCTAssertTrue(BYPlugin.isEnabled(.ghostMode))
        self.savedOptions = BYPrivacy.saved(self.accountId)
        BYPrivacy.update(self.accountId) { $0 = BYAccountOptions() }
    }

    override func tearDown() {
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
            byArchiveDeletedMessages(transaction: transaction, ids: [self.messageId(peer, 12), self.messageId(peer, 13)])
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
                byArchiveDeletedMessages(transaction: transaction, ids: [id])
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

}
