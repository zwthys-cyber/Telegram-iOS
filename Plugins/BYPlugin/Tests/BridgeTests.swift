import Darwin
import Foundation

@main
struct BridgeTests {
    static func main() {
        let expected = CommandLine.arguments[1]
        let active = expected == "enabled" || expected == "legacy"
        precondition(BYPlugin.available == (active || expected == "disabled"))
        for feature: BYPlugin.Feature in [.icons, .messageTools, .localFeatures, .downloadBoost, .privateStorage, .loginRestart] {
            precondition(BYPlugin.isEnabled(feature) == active)
        }
        precondition(BYPlugin.isEnabled(.localSaving) == (expected == "enabled"))
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
            let shouldAllow = expected == "enabled" && bits == 19
            precondition(BYLocalSaving.allows(userEnabled: userEnabled, regularMessage: regular, paid: paid, expired: expired, supportedContent: supported) == shouldAllow)
        }
        precondition(BYLocalSaving.fileName("../../report.pdf", fallback: "file.bin") == "report.pdf")
        precondition(BYLocalSaving.fileName("..\\\\private\\\\movie.mp4", fallback: "file.bin") == "movie.mp4")
        precondition(BYLocalSaving.fileName(".", fallback: "file.bin") == "file.bin")
        precondition(BYLocalSaving.fileName("..", fallback: "file.bin") == "file.bin")
        precondition(BYLocalSaving.fileName(nil, fallback: "file.bin") == "file.bin")
        precondition(BYLocalSaving.fileName("a\nb.pdf", fallback: "file.bin") == "ab.pdf")
        precondition(BYLocalSaving.fileName(String(repeating: "文", count: 100), fallback: "file.bin").utf8.count <= 200)
        print("BYPlugin ABI/injection/policy checks passed: \(expected)")
    }
}
