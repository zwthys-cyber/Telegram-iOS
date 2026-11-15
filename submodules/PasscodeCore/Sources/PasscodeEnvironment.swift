import Foundation

public struct PasscodeConfiguration: Equatable, Sendable {
    public enum ProcessRole: Equatable, Sendable {
        case mainApp
        case appExtension
    }

    public let appGroupIdentifier: String
    public let processRole: ProcessRole
    public let biometricKeychainService: String?
    public let keychainScope: String?
    /// Main-app-only keychain scope matching the private data container of a self-signed build.
    public let usePrivateKeychainForAppData: Bool

    public init(appGroupIdentifier: String, processRole: ProcessRole, biometricKeychainService: String? = nil, keychainScope: String? = nil, usePrivateKeychainForAppData: Bool = false) {
        self.appGroupIdentifier = appGroupIdentifier
        self.processRole = processRole
        self.biometricKeychainService = biometricKeychainService
        self.keychainScope = keychainScope
        self.usePrivateKeychainForAppData = usePrivateKeychainForAppData
    }
}

public final class PasscodeEnvironment: @unchecked Sendable {
    public static let shared = PasscodeEnvironment()

    private let mutex = NSLock()
    private var configuration: PasscodeConfiguration?
    private var resolvePrivateAccessGroup: (() -> String?)?
    private var resolvedPrivateAccessGroup: String?

    init() {
        
    }

    public func configure(_ configuration: PasscodeConfiguration, privateAccessGroup: (() -> String?)? = nil) throws {
        self.mutex.lock()
        defer { self.mutex.unlock() }
        #if os(macOS)
        guard !configuration.appGroupIdentifier.isEmpty, configuration.appGroupIdentifier.contains(".") else {
            throw PasscodeError.unavailable
        }
        #else
        guard configuration.appGroupIdentifier.hasPrefix("group."), configuration.appGroupIdentifier.count > "group.".count else {
            throw PasscodeError.unavailable
        }
        #endif
        guard !configuration.usePrivateKeychainForAppData || configuration.processRole == .mainApp else {
            throw PasscodeError.unavailable
        }
        if let current = self.configuration {
            guard current == configuration else { throw PasscodeError.unavailable }
            return
        }
        guard configuration.processRole != .mainApp || privateAccessGroup != nil else { throw PasscodeError.unavailable }
        self.configuration = configuration
        self.resolvePrivateAccessGroup = privateAccessGroup
    }

    public var keychainScope: String? {
        self.mutex.lock()
        defer { self.mutex.unlock() }
        guard let scope = self.configuration?.keychainScope, !scope.isEmpty else { return nil }
        return scope
    }

    public var isMainApp: Bool {
        self.mutex.lock()
        defer { self.mutex.unlock() }
        return self.configuration?.processRole == .mainApp
    }

    public func sharedAccessGroup() throws -> String {
        self.mutex.lock()
        let configuration = self.configuration
        self.mutex.unlock()
        guard let configuration else { throw PasscodeError.unavailable }
        if configuration.usePrivateKeychainForAppData {
            // Resolve through the existing checked private-group path. Never catch
            // a keychain read failure as "no credential" or reset protected data.
            return try self.privateAccessGroup()
        }
        return configuration.appGroupIdentifier
    }

    func biometricKeychainService() throws -> String {
        self.mutex.lock()
        defer { self.mutex.unlock() }
        guard let configuration = self.configuration, configuration.processRole == .mainApp,
              let service = configuration.biometricKeychainService, !service.isEmpty else {
            throw PasscodeError.unavailable
        }
        return service
    }

    public func privateAccessGroup() throws -> String {
        self.mutex.lock()
        defer { self.mutex.unlock() }
        guard let configuration = self.configuration, configuration.processRole == .mainApp else { throw PasscodeError.unavailable }
        if let group = self.resolvedPrivateAccessGroup { return group }
        guard let group = self.resolvePrivateAccessGroup?(), !group.isEmpty else {
            throw PasscodeError.unavailable
        }
        #if !os(macOS)
        guard !group.hasPrefix("group."),
              group.hasSuffix("." + configuration.appGroupIdentifier.dropFirst("group.".count)) else {
            throw PasscodeError.unavailable
        }
        #endif
        self.resolvedPrivateAccessGroup = group
        return group
    }
}

