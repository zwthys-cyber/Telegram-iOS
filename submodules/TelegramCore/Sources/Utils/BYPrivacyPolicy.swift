import Foundation
import Postbox
import SwiftSignalKit
import SGSimpleSettings

func byAccountOptions(transaction: Transaction) -> BYAccountOptions {
    guard let state = transaction.getState() as? AuthorizedAccountState else {
        return BYAccountOptions()
    }
    return BYPrivacy.effective(state.peerId.toInt64())
}

func bySuppressRead(transaction: Transaction, peerId: PeerId) -> Bool {
    return peerId.namespace != Namespaces.Peer.SecretChat && byAccountOptions(transaction: transaction).hideReadReceipts
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
