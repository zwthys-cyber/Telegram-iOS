import Foundation
import SGSimpleSettings

public extension EngineRawMessage {
    /// Only local export call sites use this. Never override isCopyProtected(),
    /// forwarding rights, paid-content access, consumption or expiry timestamps.
    var byAllowsLocalSaving: Bool {
        let expired = self.effectiveMedia.contains { $0 is TelegramMediaExpiredContent }
        let supported = self.restrictedContentAttribute == nil && self.adAttribute == nil && self.effectiveMedia.allSatisfy { media in
            return media is TelegramMediaImage || media is TelegramMediaFile || media is TelegramMediaWebpage
        }
        return BYLocalSaving.allows(
            userEnabled: SGSimpleSettings.shared.byLocalSaving,
            regularMessage: self.id.namespace >= 0 && !Namespaces.Message.allNonRegular.contains(self.id.namespace) && !self.isEphemeral && self.timestamp != 0 && self.peers[self.id.peerId] != nil,
            paid: self.paidContent != nil,
            expired: expired,
            supportedContent: supported
        )
    }
}
