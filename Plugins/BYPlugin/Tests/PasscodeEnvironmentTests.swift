import Foundation

@main
struct PasscodeEnvironmentTests {
    static func mustThrow(_ body: () throws -> Void) {
        do {
            try body()
            fatalError("Expected a rejected keychain scope")
        } catch {
            precondition(error as? PasscodeError == .unavailable)
        }
    }

    static func main() throws {
        let group = "group.org.example.byplugin"
        let privateGroup = "TEAM.org.example.byplugin"
        let normal = PasscodeEnvironment()
        try normal.configure(PasscodeConfiguration(appGroupIdentifier: group, processRole: .mainApp), privateAccessGroup: { privateGroup })
        let normalShared = try normal.sharedAccessGroup()
        precondition(normalShared == group)

        let local = PasscodeEnvironment()
        let configuration = PasscodeConfiguration(appGroupIdentifier: group, processRole: .mainApp, usePrivateKeychainForAppData: true)
        try local.configure(configuration, privateAccessGroup: { privateGroup })
        let localShared = try local.sharedAccessGroup()
        let localPrivate = try local.privateAccessGroup()
        precondition(localShared == privateGroup && localPrivate == privateGroup)
        try local.configure(configuration, privateAccessGroup: { privateGroup })
        mustThrow {
            try local.configure(PasscodeConfiguration(appGroupIdentifier: group, processRole: .mainApp), privateAccessGroup: { privateGroup })
        }

        let extensionEnvironment = PasscodeEnvironment()
        mustThrow {
            try extensionEnvironment.configure(PasscodeConfiguration(appGroupIdentifier: group, processRole: .appExtension, usePrivateKeychainForAppData: true), privateAccessGroup: { privateGroup })
        }
        try extensionEnvironment.configure(PasscodeConfiguration(appGroupIdentifier: group, processRole: .appExtension))
        let extensionGroup = try extensionEnvironment.sharedAccessGroup()
        precondition(extensionGroup == group)

        let missing = PasscodeEnvironment()
        try missing.configure(configuration, privateAccessGroup: { nil })
        mustThrow { _ = try missing.sharedAccessGroup() }
        let unconfigured = PasscodeEnvironment()
        mustThrow { _ = try unconfigured.sharedAccessGroup() }

        #if os(iOS)
        for invalid in ["group.org.example.byplugin", "TEAM.org.some.other.app"] {
            let environment = PasscodeEnvironment()
            try environment.configure(configuration, privateAccessGroup: { invalid })
            mustThrow { _ = try environment.sharedAccessGroup() }
        }
        #endif
        print("Passcode scope: normal groups, private main-app scope, extension rejection, immutability and missing credentials passed.")
    }
}
