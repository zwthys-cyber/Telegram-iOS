import Foundation

/// Account-local, serialized by the caller's Postbox transaction. Complete MediaBox
/// files are immutable; hard links preserve their bytes when the cache unlinks them.
public final class BYHistoryMediaStorage {
    public static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let maximumFiles = 5000
    private let directory: URL
    private let byteLimit: Int64
    private var files: [String: Int64] = [:]
    private var resources: [String: BYHistoryAttachment] = [:]
    private var usedBytes: Int64 = 0
    private var available = false

    public init(directoryPath: String, existing: [BYHistoryAttachment] = [], maximumBytes: Int64 = BYHistoryMediaStorage.maximumBytes) {
        self.directory = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
        self.byteLimit = max(0, maximumBytes)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let values = try self.directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true && values.isSymbolicLink != true else { return }
            for url in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
                let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                if value.isRegularFile == true, value.isSymbolicLink != true, let size = value.fileSize {
                    let size = Int64(max(0, size))
                    self.files[url.lastPathComponent] = size
                    self.usedBytes = self.usedBytes.addingReportingOverflow(size).overflow ? Int64.max : self.usedBytes + size
                }
            }
            self.available = true
            for attachment in existing {
                if self.fileURL(for: attachment) != nil { self.resources[attachment.resourceId] = attachment }
            }
        } catch {
            self.available = false
        }
    }

    private static func url(_ id: String, directory: URL) -> URL? {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              !parts[1].isEmpty, parts[1].count <= 12,
              parts[1].utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) }) else { return nil }
        let result = directory.appendingPathComponent(id).standardizedFileURL
        guard result.deletingLastPathComponent() == directory else { return nil }
        return result
    }

    public func fileURL(for attachment: BYHistoryAttachment) -> URL? {
        guard self.available else { return nil }
        return Self.fileURL(directoryPath: self.directory.path, attachment: attachment)
    }

    /// Read-only resolution for chat rendering; no archive scan or directory creation.
    public static func fileURL(directoryPath: String, attachment: BYHistoryAttachment) -> URL? {
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true).standardizedFileURL
        guard let directoryValues = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
              let id = attachment.localId, let url = Self.url(id, directory: directory),
              let value = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              value.isRegularFile == true, value.isSymbolicLink != true,
              let size = value.fileSize, Int64(size) == attachment.byteCount else { return nil }
        return url
    }

    public func preserve(resourceId: String, sourcePath: String?, fileName: String, mimeType: String, mediaData: Data? = nil) -> BYHistoryAttachment {
        if let existing = self.resources[resourceId], self.fileURL(for: existing) != nil {
            return BYHistoryAttachment(resourceId: resourceId, fileName: fileName, mimeType: mimeType, localId: existing.localId, byteCount: existing.byteCount, mediaData: mediaData ?? existing.mediaData)
        }
        let missing = BYHistoryAttachment(resourceId: resourceId, fileName: fileName, mimeType: mimeType, localId: nil, byteCount: 0, mediaData: mediaData)
        guard self.available, let sourcePath,
              let attributes = try? FileManager.default.attributesOfItem(atPath: sourcePath),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let number = attributes[.size] as? NSNumber else { return missing }
        let size = max(0, number.int64Value)
        guard self.files.count < Self.maximumFiles, size <= self.byteLimit, self.usedBytes <= self.byteLimit - size else { return missing }
        var ext = (fileName as NSString).pathExtension.lowercased()
        if ext.isEmpty || ext.count > 12 || !ext.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 122).contains($0) }) { ext = "bin" }
        let id = UUID().uuidString.lowercased() + "." + ext
        guard let destination = Self.url(id, directory: self.directory) else { return missing }
        do {
            try FileManager.default.linkItem(atPath: sourcePath, toPath: destination.path)
            let saved = BYHistoryAttachment(resourceId: resourceId, fileName: fileName, mimeType: mimeType, localId: id, byteCount: size, mediaData: mediaData)
            guard self.fileURL(for: saved) != nil else {
                try? FileManager.default.removeItem(at: destination)
                return missing
            }
            self.files[id] = size
            self.usedBytes += size
            self.resources[resourceId] = saved
            return saved
        } catch {
            return missing
        }
    }

    /// Call only after the ledger write has committed. Unknown files and paths
    /// outside this archive are never removed. Preview/export copies have their own link.
    public func removeUnreferenced(keeping ids: Set<String>) {
        for (id, size) in Array(self.files) where !ids.contains(id) {
            guard let url = Self.url(id, directory: self.directory) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                self.files.removeValue(forKey: id)
                self.usedBytes = max(0, self.usedBytes - size)
            } catch {
                // Keep failed removals in quota accounting; never claim free space.
            }
        }
        self.resources = self.resources.filter { _, attachment in attachment.localId.map(ids.contains) ?? false }
    }
}
