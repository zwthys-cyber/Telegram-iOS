import Darwin
import Foundation

/// Optional C ABI provided by the dylib injected at signing time.
/// Only plugin-owned exports are resolved; no Telegram/Swift symbols are hooked.
public enum BYPlugin {
    public enum Feature: UInt32 {
        case icons = 1
        case messageTools = 2
        case localFeatures = 4
        case downloadBoost = 8
        case privateStorage = 16
        case loginRestart = 32
        case localSaving = 64
        case ghostMode = 128
        case messageHistory = 256
        case chatPrivacy = 512
        case deletionMarkers = 1024
        case adBlock = 2048
    }

    private typealias UIntFunction = @convention(c) () -> UInt32
    private typealias PartFunction = @convention(c) (Int64, Int64, UInt32) -> Int64
    private typealias PendingFunction = @convention(c) (Int32, UInt32) -> Int32

    private struct Runtime: @unchecked Sendable {
        let features: UInt32
        let partSize: PartFunction
        let pending: PendingFunction
    }

    // A signing tool must add a load command. Merely copying a dylib into an IPA
    // does not load it. Absence or an incompatible ABI leaves upstream behavior.
    private static let runtime: Runtime? = {
        let global = UnsafeMutableRawPointer(bitPattern: -2) // Darwin RTLD_DEFAULT
        guard let versionSymbol = dlsym(global, "BYPluginABIVersion"),
              let featuresSymbol = dlsym(global, "BYPluginFeatureFlags"),
              let partSymbol = dlsym(global, "BYPluginDownloadPartSize"),
              let pendingSymbol = dlsym(global, "BYPluginPendingParts") else {
            return nil
        }
        let version = unsafeBitCast(versionSymbol, to: UIntFunction.self)
        guard version() == 1 else {
            return nil
        }
        let features = unsafeBitCast(featuresSymbol, to: UIntFunction.self)
        return Runtime(
            features: features() & 4095,
            partSize: unsafeBitCast(partSymbol, to: PartFunction.self),
            pending: unsafeBitCast(pendingSymbol, to: PendingFunction.self)
        )
    }()

    public static var available: Bool {
        return runtime != nil
    }

    public static func isEnabled(_ feature: Feature) -> Bool {
        return ((runtime?.features ?? 0) & feature.rawValue) != 0
    }

    private static func modeValue(_ mode: String) -> UInt32 {
        switch mode {
        case "medium": return 1
        case "maximum": return 2
        default: return 0
        }
    }

    public static func downloadPartSize(_ base: Int64, fileSize: Int64?, mode: String) -> Int64 {
        guard isEnabled(.downloadBoost), let runtime else {
            return base
        }
        let proposed = runtime.partSize(base, fileSize ?? -1, modeValue(mode))
        // Telegram requests must use legal power-of-two lengths <= 1 MiB.
        guard proposed >= base, proposed <= 1024 * 1024,
              proposed > 0, proposed & (proposed - 1) == 0 else {
            return base
        }
        return proposed
    }

    public static func pendingParts(_ base: Int, mode: String) -> Int {
        guard isEnabled(.downloadBoost), let runtime,
              let input = Int32(exactly: base) else {
            return base
        }
        let proposed = Int(runtime.pending(input, modeValue(mode)))
        // Never reduce the newer upstream engine's concurrency.
        return max(base, min(16, proposed))
    }
}

/// Client feature access only; neither cached nor server subscription status changes.
public enum SGLocalFeatures {
    public static var proEnabled: Bool {
        return BYPlugin.isEnabled(.localFeatures)
    }

    public static func canUsePro(serverStatus: Int64) -> Bool {
        return proEnabled || serverStatus > 1
    }
}

/// Local export is opt-in. Timers/view-once do not exclude still-accessible media;
/// paid, expired, non-regular and unsupported content keep upstream behavior.
public enum BYLocalSaving {
    public static func allows(userEnabled: Bool, regularMessage: Bool, paid: Bool, expired: Bool, supportedContent: Bool) -> Bool {
        return BYPlugin.isEnabled(.localSaving) && userEnabled && regularMessage && !paid && !expired && supportedContent
    }

    public static func fileName(_ original: String?, fallback: String) -> String {
        guard let original else { return fallback }
        var name = (original.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        name = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        guard !name.isEmpty, name != ".", name != ".." else { return fallback }
        while name.utf8.count > 200 { name.removeLast() }
        return name.isEmpty ? fallback : name
    }
}

/// Stored independently per Telegram account. New privacy options are opt-in.
/// Preferences are never uploaded and a missing/older dylib disables the new policies.
public enum BYChatGhostMode: String, Codable, CaseIterable {
    case inherit, hidden, visible
}

/// A chat override affects peer-scoped reports. Online presence remains account-wide.
public struct BYChatPrivacy: Codable, Equatable {
    public let peerId: Int64
    public var title: String
    public var mode: BYChatGhostMode
    public init(peerId: Int64, title: String, mode: BYChatGhostMode) {
        self.peerId = peerId
        self.title = String(title.prefix(256))
        self.mode = mode
    }
}

public struct BYAccountOptions: Codable, Equatable {
    public var hideOnline = false
    public var hideTyping = false
    public var hideReadReceipts = false
    public var hideStoryViews = false
    public var keepDeleted = false
    public var keepEdits = false
    public var historyDays = 30
    public var showDeletedMarkers = true
    public var hideSponsoredMessages = false
    public var filterPromotions = false
    public var promotionKeywords: [String] = []

    public init() {}
    private enum CodingKeys: String, CodingKey {
        case hideOnline, hideTyping, hideReadReceipts, hideStoryViews, keepDeleted, keepEdits, historyDays
        case showDeletedMarkers, hideSponsoredMessages, filterPromotions, promotionKeywords
    }
    // Explicit defaults preserve all previously saved 2.0 options when new keys are absent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.hideOnline = try c.decodeIfPresent(Bool.self, forKey: .hideOnline) ?? false
        self.hideTyping = try c.decodeIfPresent(Bool.self, forKey: .hideTyping) ?? false
        self.hideReadReceipts = try c.decodeIfPresent(Bool.self, forKey: .hideReadReceipts) ?? false
        self.hideStoryViews = try c.decodeIfPresent(Bool.self, forKey: .hideStoryViews) ?? false
        self.keepDeleted = try c.decodeIfPresent(Bool.self, forKey: .keepDeleted) ?? false
        self.keepEdits = try c.decodeIfPresent(Bool.self, forKey: .keepEdits) ?? false
        self.historyDays = try c.decodeIfPresent(Int.self, forKey: .historyDays) ?? 30
        self.showDeletedMarkers = try c.decodeIfPresent(Bool.self, forKey: .showDeletedMarkers) ?? true
        self.hideSponsoredMessages = try c.decodeIfPresent(Bool.self, forKey: .hideSponsoredMessages) ?? false
        self.filterPromotions = try c.decodeIfPresent(Bool.self, forKey: .filterPromotions) ?? false
        self.promotionKeywords = BYPromotionFilter.normalized(try c.decodeIfPresent([String].self, forKey: .promotionKeywords) ?? [])
    }
    public var anyGhostEnabled: Bool {
        return hideOnline || hideTyping || hideReadReceipts || hideStoryViews
    }
    public mutating func setGhost(_ value: Bool) {
        hideOnline = value
        hideTyping = value
        hideReadReceipts = value
        hideStoryViews = value
    }
    public mutating func applyChatMode(_ mode: BYChatGhostMode) {
        guard mode != .inherit else { return }
        hideTyping = mode == .hidden
        hideReadReceipts = mode == .hidden
        hideStoryViews = mode == .hidden
    }
}

public enum BYPromotionFilter {
    private final class RevealedStore: @unchecked Sendable {
        let lock = NSLock()
        var keys: [String] = []
    }
    private static let revealed = RevealedStore()
    private static func revealKey(accountId: Int64, peerId: Int64, namespace: Int32, messageId: Int32) -> String {
        return "\(accountId):\(peerId):\(namespace):\(messageId)"
    }
    public static func isRevealed(accountId: Int64, peerId: Int64, namespace: Int32, messageId: Int32) -> Bool {
        revealed.lock.lock()
        defer { revealed.lock.unlock() }
        return revealed.keys.contains(revealKey(accountId: accountId, peerId: peerId, namespace: namespace, messageId: messageId))
    }
    public static func reveal(accountId: Int64, peerId: Int64, namespace: Int32, messageId: Int32) {
        let key = revealKey(accountId: accountId, peerId: peerId, namespace: namespace, messageId: messageId)
        revealed.lock.lock()
        revealed.keys.removeAll { $0 == key }
        revealed.keys.append(key)
        if revealed.keys.count > 500 { revealed.keys.removeFirst(revealed.keys.count - 500) }
        revealed.lock.unlock()
        NotificationCenter.default.post(name: BYPrivacy.changed, object: nil, userInfo: ["accountId": accountId, "peerId": peerId])
    }
    public static func normalized(_ keywords: [String]) -> [String] {
        var result: [String] = []
        for value in keywords {
            let value = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            if !value.isEmpty && !result.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
                result.append(value)
            }
            if result.count == 100 { break }
        }
        return result
    }
    public static func matches(text: String, links: [String], keywords: [String]) -> Bool {
        let value = String(text.prefix(32768)) + "\n" + links.prefix(20).map { String($0.prefix(2048)) }.joined(separator: "\n")
        return normalized(keywords).contains { value.localizedCaseInsensitiveContains($0) }
    }
}

public enum BYPrivacy {
    public static let changed = Notification.Name("BYPlugin.AccountOptionsChanged")
    private static let lock = NSLock()
    private static func key(_ accountId: Int64) -> String { "BYPlugin.account.v1.\(accountId)" }
    private static func chatsKey(_ accountId: Int64) -> String { "BYPlugin.chats.v1.\(accountId)" }

    public static func saved(_ accountId: Int64) -> BYAccountOptions {
        lock.lock()
        defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: key(accountId)),
              let options = try? JSONDecoder().decode(BYAccountOptions.self, from: data) else {
            return BYAccountOptions()
        }
        return options
    }

    public static func savedChats(_ accountId: Int64) -> [BYChatPrivacy] {
        lock.lock()
        defer { lock.unlock() }
        return UserDefaults.standard.data(forKey: chatsKey(accountId)).flatMap {
            try? JSONDecoder().decode([BYChatPrivacy].self, from: $0)
        } ?? []
    }

    public static func chatMode(_ accountId: Int64, peerId: Int64) -> BYChatGhostMode {
        return savedChats(accountId).first(where: { $0.peerId == peerId })?.mode ?? .inherit
    }

    public static func effective(_ accountId: Int64, peerId: Int64? = nil) -> BYAccountOptions {
        var options = saved(accountId)
        if BYPlugin.isEnabled(.chatPrivacy), let peerId {
            options.applyChatMode(chatMode(accountId, peerId: peerId))
        }
        if !BYPlugin.isEnabled(.ghostMode) { options.setGhost(false) }
        if !BYPlugin.isEnabled(.messageHistory) {
            options.keepDeleted = false
            options.keepEdits = false
        }
        if !BYPlugin.isEnabled(.deletionMarkers) { options.showDeletedMarkers = false }
        if !BYPlugin.isEnabled(.adBlock) {
            options.hideSponsoredMessages = false
            options.filterPromotions = false
        }
        options.historyDays = [7, 30, 90].contains(options.historyDays) ? options.historyDays : 30
        return options
    }

    public static func update(_ accountId: Int64, _ update: (inout BYAccountOptions) -> Void) {
        lock.lock()
        var options = UserDefaults.standard.data(forKey: key(accountId)).flatMap {
            try? JSONDecoder().decode(BYAccountOptions.self, from: $0)
        } ?? BYAccountOptions()
        update(&options)
        options.promotionKeywords = BYPromotionFilter.normalized(options.promotionKeywords)
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: key(accountId))
        }
        lock.unlock()
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["accountId": accountId])
    }

    public static func updateChat(_ accountId: Int64, peerId: Int64, title: String, mode: BYChatGhostMode) {
        lock.lock()
        var chats = UserDefaults.standard.data(forKey: chatsKey(accountId)).flatMap {
            try? JSONDecoder().decode([BYChatPrivacy].self, from: $0)
        } ?? []
        chats.removeAll { $0.peerId == peerId }
        if mode != .inherit {
            chats.append(BYChatPrivacy(peerId: peerId, title: title, mode: mode))
        }
        // Do not evict another chat's privacy choice silently when a list grows.
        if let data = try? JSONEncoder().encode(chats) {
            UserDefaults.standard.set(data, forKey: chatsKey(accountId))
        }
        lock.unlock()
        NotificationCenter.default.post(name: changed, object: nil, userInfo: ["accountId": accountId, "peerId": peerId])
    }
}
