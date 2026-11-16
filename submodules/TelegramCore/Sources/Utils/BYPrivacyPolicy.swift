import Foundation
import Postbox
import SwiftSignalKit
import SGSimpleSettings

func byAccountOptions(transaction: Transaction, peerId: PeerId? = nil) -> BYAccountOptions {
    guard let state = transaction.getState() as? AuthorizedAccountState else {
        return BYAccountOptions()
    }
    return BYPrivacy.effective(state.peerId.toInt64(), peerId: peerId?.toInt64())
}

func bySuppressRead(transaction: Transaction, peerId: PeerId) -> Bool {
    return peerId.namespace != Namespaces.Peer.SecretChat && byAccountOptions(transaction: transaction, peerId: peerId).hideReadReceipts
}

func byPrivacyChanges(accountId: Int64) -> Signal<Void, NoError> {
    return Signal { subscriber in
        let observer = NotificationCenter.default.addObserver(forName: BYPrivacy.changed, object: nil, queue: nil) { notification in
            if notification.userInfo?["accountId"] as? Int64 == accountId {
                subscriber.putNext(())
            }
        }
        subscriber.putNext(())
        return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
    }
}

/// Timed and paid media keep the upstream consumption protocol.
func bySuppressContentRead(transaction: Transaction, id: MessageId) -> Bool {
    guard bySuppressRead(transaction: transaction, peerId: id.peerId),
          let message = transaction.getMessage(id), message.paidContent == nil else {
        return false
    }
    return !message.attributes.contains(where: {
        $0 is AutoclearTimeoutMessageAttribute || $0 is AutoremoveTimeoutMessageAttribute
    })
}


public extension TelegramEngine.Messages {
    func byPrivacySettingsChanges() -> Signal<Void, NoError> {
        return byPrivacyChanges(accountId: self.account.peerId.toInt64())
    }
}
