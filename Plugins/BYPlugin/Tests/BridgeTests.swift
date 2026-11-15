import Darwin
import Foundation

@main
struct BridgeTests {
    static func main() {
        let expected = CommandLine.arguments[1]
        let active = expected == "enabled"
        precondition(BYPlugin.available == (active || expected == "disabled"))
        for feature: BYPlugin.Feature in [.icons, .messageTools, .localFeatures, .downloadBoost, .privateStorage, .loginRestart] {
            precondition(BYPlugin.isEnabled(feature) == active)
        }
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
        print("BYPlugin ABI/injection/policy checks passed: \(expected)")
    }
}
