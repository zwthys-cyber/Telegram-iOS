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
            features: features() & 127,
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
