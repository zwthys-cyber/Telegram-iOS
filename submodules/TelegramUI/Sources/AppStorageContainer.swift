import Foundation

// Self-signed builds may lack the App Groups entitlement. Keep main-app data
// inside its own sandbox in that case; extensions still require a real group.
func resolveApplicationDataContainer(sharedContainerURL: URL?, privateContainerURL: URL, allowPrivateContainer: Bool, fileManager: FileManager = .default) throws -> URL? {
    if let sharedContainerURL = sharedContainerURL {
        return sharedContainerURL
    }
    guard allowPrivateContainer else {
        return nil
    }
    try fileManager.createDirectory(at: privateContainerURL, withIntermediateDirectories: true, attributes: nil)
    return privateContainerURL
}
