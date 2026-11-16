import Foundation

@main
struct MediaStorageTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cache.bin")
        let bytes = Data([0, 1, 2, 3, 255])
        try bytes.write(to: source)
        let archive = root.appendingPathComponent("account-a", isDirectory: true)
        let storage = BYHistoryMediaStorage(directoryPath: archive.path, maximumBytes: 8)
        let saved = storage.preserve(resourceId: "file-1", sourcePath: source.path, fileName: "file.pdf", mimeType: "application/pdf", mediaData: Data([1, 2]))
        precondition(saved.localId != nil && saved.byteCount == 5)
        let savedURL = storage.fileURL(for: saved)!
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let savedAttributes = try FileManager.default.attributesOfItem(atPath: savedURL.path)
        precondition((sourceAttributes[.systemFileNumber] as? NSNumber) == (savedAttributes[.systemFileNumber] as? NSNumber))
        let overQuota = storage.preserve(resourceId: "file-2", sourcePath: source.path, fileName: "second.bin", mimeType: "application/octet-stream")
        precondition(overQuota.localId == nil)
        try FileManager.default.removeItem(at: source)
        precondition(try! Data(contentsOf: savedURL) == bytes)
        let reopened = BYHistoryMediaStorage(directoryPath: archive.path, existing: [saved], maximumBytes: 8)
        precondition(reopened.preserve(resourceId: "file-1", sourcePath: nil, fileName: "renamed.pdf", mimeType: saved.mimeType).localId == saved.localId)
        let other = BYHistoryMediaStorage(directoryPath: root.appendingPathComponent("account-b").path)
        precondition(other.fileURL(for: saved) == nil)
        let traversal = BYHistoryAttachment(resourceId: "x", fileName: "x", mimeType: "x", localId: "../cache.bin", byteCount: 5)
        precondition(storage.fileURL(for: traversal) == nil)
        let linkId = UUID().uuidString.lowercased() + ".bin"
        try FileManager.default.createSymbolicLink(at: archive.appendingPathComponent(linkId), withDestinationURL: savedURL)
        let symlink = BYHistoryAttachment(resourceId: "x", fileName: "x", mimeType: "x", localId: linkId, byteCount: 5)
        precondition(storage.fileURL(for: symlink) == nil)
        let directoryLink = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: archive)
        precondition(BYHistoryMediaStorage(directoryPath: directoryLink.path).fileURL(for: saved) == nil)
        let unknown = archive.appendingPathComponent("leave-me.txt")
        try Data([4]).write(to: unknown)
        let preview = root.appendingPathComponent("preview.pdf")
        try FileManager.default.linkItem(at: savedURL, to: preview)
        reopened.removeUnreferenced(keeping: [])
        precondition(!FileManager.default.fileExists(atPath: savedURL.path))
        precondition(FileManager.default.fileExists(atPath: unknown.path))
        precondition(try! Data(contentsOf: preview) == bytes)
        print("Media archive: hard links survive cache deletion; quota, reopening, isolation, path/symlink rejection and preview lifetime passed")
    }
}
