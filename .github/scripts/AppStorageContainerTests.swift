import Foundation

@main
struct AppStorageContainerTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let shared = temporary.appendingPathComponent("shared", isDirectory: true)
        let local = temporary.appendingPathComponent("private/data", isDirectory: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        for allowPrivate in [false, true] {
            let selected = try resolveApplicationDataContainer(sharedContainerURL: shared, privateContainerURL: local, allowPrivateContainer: allowPrivate)
            precondition(selected == shared)
            precondition(!fm.fileExists(atPath: local.path))
        }
        let missing = try resolveApplicationDataContainer(sharedContainerURL: nil, privateContainerURL: local, allowPrivateContainer: false)
        precondition(missing == nil)
        precondition(!fm.fileExists(atPath: local.path))
        let selected = try resolveApplicationDataContainer(sharedContainerURL: nil, privateContainerURL: local, allowPrivateContainer: true)
        precondition(selected == local)
        let marker = local.appendingPathComponent("existing-account")
        try Data("preserve".utf8).write(to: marker)
        _ = try resolveApplicationDataContainer(sharedContainerURL: nil, privateContainerURL: local, allowPrivateContainer: true)
        let preserved = try Data(contentsOf: marker)
        precondition(preserved == Data("preserve".utf8))
        let blocked = temporary.appendingPathComponent("file-not-directory")
        try Data("keep".utf8).write(to: blocked)
        var rejected = false
        do {
            _ = try resolveApplicationDataContainer(sharedContainerURL: nil, privateContainerURL: blocked, allowPrivateContainer: true)
        } catch {
            rejected = true
        }
        precondition(rejected)
        let blockedContents = try Data(contentsOf: blocked)
        precondition(blockedContents == Data("keep".utf8))
        print("App storage: shared group, missing entitlement, private fallback, data preservation and filesystem failure checks passed.")
    }
}
