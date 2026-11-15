import Darwin
import Foundation

@main
struct BridgeTests {
    static func main() {
        let expected = CommandLine.arguments[1]
        let active = expected == "enabled" || expected == "v2" || expected == "previous" || expected == "legacy"
        precondition(BYPlugin.available == (active || expected == "disabled"))
        for feature: BYPlugin.Feature in [.icons, .messageTools, .localFeatures, .downloadBoost, .privateStorage, .loginRestart] {
            precondition(BYPlugin.isEnabled(feature) == active)
        }
        precondition(BYPlugin.isEnabled(.localSaving) == (expected == "enabled" || expected == "v2" || expected == "previous"))
        precondition(SGLocalFeatures.canUsePro(serverStatus: 1) == active)
        precondition(SGLocalFeatures.canUsePro(serverStatus: 2))
        precondition(BYPlugin.downloadPartSize(131072, fileSize: nil, mode: "maximum") == 131072)
        precondition(BYPlugin.downloadPartSize(16384, fileSize: 1048576, mode: "maximum") == 16384)
        precondition(BYPlugin.downloadPartSize(131072, fileSize: 1048577, mode: "maximum") == (active ? 1048576 : 131072))
        precondition(BYPlugin.downloadPartSize(131072, fileSize: 1048577, mode: "medium") == (active ? 524288 : 131072))
        precondition(BYPlugin.downloadPartSize(131072, fileSize: 1048577, mode: "none") == 131072)
        precondition(BYPlugin.pendingParts(6, mode: "maximum") == (active ? 12 : 6))
        precondition(BYPlugin.pendingParts(6, mode: "medium") == (active ? 8 : 6))
        precondition(BYPlugin.pendingParts(16, mode: "maximum") == 16)
        precondition(BYPlugin.pendingParts(24, mode: "maximum") == 24)
        precondition(BYPlugin.pendingParts(1, mode: "none") == 1)
        // Exhaust all policy inputs for each actual dyld loader scenario.
        for bits in 0..<32 {
            let userEnabled = bits & 1 != 0
            let regular = bits & 2 != 0
            let paid = bits & 4 != 0
            let expired = bits & 8 != 0
            let supported = bits & 16 != 0
            let shouldAllow = (expected == "enabled" || expected == "v2" || expected == "previous") && bits == 19
            precondition(BYLocalSaving.allows(userEnabled: userEnabled, regularMessage: regular, paid: paid, expired: expired, supportedContent: supported) == shouldAllow)
        }
        precondition(BYLocalSaving.fileName("../../report.pdf", fallback: "file.bin") == "report.pdf")
        precondition(BYLocalSaving.fileName("..\\\\private\\\\movie.mp4", fallback: "file.bin") == "movie.mp4")
        precondition(BYLocalSaving.fileName(".", fallback: "file.bin") == "file.bin")
        precondition(BYLocalSaving.fileName("..", fallback: "file.bin") == "file.bin")
        precondition(BYLocalSaving.fileName(nil, fallback: "file.bin") == "file.bin")
        precondition(BYLocalSaving.fileName("a\nb.pdf", fallback: "file.bin") == "ab.pdf")
        precondition(BYLocalSaving.fileName(String(repeating: "文", count: 100), fallback: "file.bin").utf8.count <= 200)
        let accountA: Int64 = -81820001
        let accountB: Int64 = -81820002
        BYPrivacy.update(accountA) { $0 = BYAccountOptions() }
        BYPrivacy.update(accountB) { $0 = BYAccountOptions() }
        precondition(!BYPrivacy.saved(accountA).anyGhostEnabled)
        BYPrivacy.update(accountA) { options in
            options.setGhost(true)
            options.keepDeleted = true
            options.keepEdits = true
        }
        precondition(BYPrivacy.saved(accountA).hideReadReceipts)
        precondition(!BYPrivacy.saved(accountB).anyGhostEnabled)
        precondition(BYPrivacy.effective(accountA).anyGhostEnabled == (expected == "enabled" || expected == "v2"))
        precondition(BYPrivacy.effective(accountA).keepDeleted == (expected == "enabled" || expected == "v2"))
        precondition(BYPrivacy.effective(accountA).keepEdits == (expected == "enabled" || expected == "v2"))
        // Decode the previous release's on-disk representation without resetting user choices.
        let oldData = Data(#"{"hideOnline":true,"hideTyping":false,"hideReadReceipts":true,"hideStoryViews":false,"keepDeleted":true,"keepEdits":true,"historyDays":90}"#.utf8)
        let restored = try! JSONDecoder().decode(BYAccountOptions.self, from: oldData)
        precondition(restored.hideOnline && restored.hideReadReceipts && restored.keepDeleted && restored.keepEdits)
        precondition(!restored.hideTyping && !restored.hideStoryViews && restored.historyDays == 90)
        precondition(!restored.hideSponsoredMessages && !restored.filterPromotions)
        precondition(restored.showDeletedMarkers)
        for feature: BYPlugin.Feature in [.chatPrivacy, .deletionMarkers, .adBlock] {
            precondition(BYPlugin.isEnabled(feature) == (expected == "enabled"))
        }
        BYPrivacy.updateChat(accountA, peerId: 10, title: "Visible", mode: .visible)
        BYPrivacy.updateChat(accountA, peerId: 11, title: "Hidden", mode: .hidden)
        precondition(BYPrivacy.effective(accountA, peerId: 10).hideOnline == (expected == "enabled" || expected == "v2"))
        precondition(BYPrivacy.effective(accountA, peerId: 10).hideReadReceipts == (expected == "v2"))
        BYPrivacy.update(accountA) { $0.setGhost(false) }
        precondition(BYPrivacy.effective(accountA, peerId: 11).hideReadReceipts == (expected == "enabled"))
        precondition(BYPrivacy.effective(accountA, peerId: 11).hideTyping == (expected == "enabled"))
        precondition(BYPrivacy.effective(accountA, peerId: 11).hideStoryViews == (expected == "enabled"))
        precondition(!BYPrivacy.effective(accountA, peerId: 11).hideOnline)
        precondition(!BYPrivacy.effective(accountB, peerId: 11).anyGhostEnabled)
        precondition(BYPrivacy.effective(accountA, peerId: 11).keepDeleted == (expected == "enabled" || expected == "v2"))
        BYPrivacy.updateChat(accountA, peerId: 11, title: "", mode: .inherit)
        precondition(!BYPrivacy.effective(accountA, peerId: 11).anyGhostEnabled)
        BYPrivacy.updateChat(accountA, peerId: 10, title: "", mode: .inherit)
        precondition(BYPrivacy.savedChats(accountA).isEmpty)
        BYPrivacy.update(accountA) { $0.hideSponsoredMessages = true; $0.filterPromotions = true }
        precondition(BYPrivacy.effective(accountA).hideSponsoredMessages == (expected == "enabled"))
        precondition(BYPrivacy.effective(accountA).filterPromotions == (expected == "enabled"))
        precondition(BYPromotionFilter.normalized([" ", "广告", "广告", "EXAMPLE.com", "example.COM"]) == ["广告", "EXAMPLE.com"])
        precondition(BYPromotionFilter.matches(text: "推广合作", links: [], keywords: ["推广"]))
        precondition(BYPromotionFilter.matches(text: "点这里", links: ["https://ads.example.com/start"], keywords: ["ADS.EXAMPLE.COM"]))
        precondition(!BYPromotionFilter.matches(text: "正常聊天", links: [], keywords: ["推广", "广告"]))
        precondition(!BYPromotionFilter.matches(text: "正常聊天", links: [], keywords: [" "]))
        BYPromotionFilter.reveal(accountId: accountA, peerId: 10, namespace: 0, messageId: 12)
        precondition(BYPromotionFilter.isRevealed(accountId: accountA, peerId: 10, namespace: 0, messageId: 12))
        precondition(!BYPromotionFilter.isRevealed(accountId: accountB, peerId: 10, namespace: 0, messageId: 12))
        precondition(!BYPromotionFilter.isRevealed(accountId: accountA, peerId: 11, namespace: 0, messageId: 12))
        BYPrivacy.update(accountA) { $0 = BYAccountOptions() }
        BYPrivacy.update(accountB) { $0 = BYAccountOptions() }
        print("BYPlugin ABI/injection/policy checks passed: \(expected)")
    }
}
