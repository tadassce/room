import Foundation
@testable import Integration
import Testing

@Suite("Apple Passwords host registration")
struct ApplePasswordsTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "room-apple-passwords-\(UUID())", directoryHint: .isDirectory)
        var manifest: URL { root.appending(path: "apple/com.apple.passwordmanager.json") }
        var engine: URL { root.appending(path: "engine", directoryHint: .isDirectory) }
        var hosts: URL { engine.appending(path: "NativeMessagingHosts", directoryHint: .isDirectory) }
        var registration: URL { hosts.appending(path: "com.apple.passwordmanager.json") }

        func write(_ override: [String: Any] = [:]) throws {
            var values: [String: Any] = [
                "name": "com.apple.passwordmanager", "type": "stdio",
                "path": "/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper",
                "allowed_origins": ["chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/", "chrome-extension://mfbcdcnpokpoajjciilocoachedjkima/"]
            ]
            values.merge(override) { _, new in new }
            try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: values).write(to: manifest)
        }

        func bridge(entitled: Bool = true, trusted: Bool = true) -> ApplePasswords {
            ApplePasswords(manifestURLs: [manifest], isEntitled: { entitled }, verifyHelper: { _ in trusted })
        }

        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("Unapproved builds do not register or even inspect a helper")
    func approvalGate() {
        let fixture = Fixture()
        defer { fixture.clean() }
        let bridge = ApplePasswords(manifestURLs: [fixture.manifest], isEntitled: { false }, verifyHelper: { _ in
            Issue.record("No helper verification before entitlement approval")
            return true
        })
        bridge.prepare(engineDirectory: fixture.engine)
        #expect(bridge.state == .approvalRequired)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test("Verified Apple manifest is linked once, without copying or broadening its origin restrictions")
    func registration() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        try fixture.write()
        let original = try Data(contentsOf: fixture.manifest)
        let bridge = fixture.bridge()
        bridge.prepare(engineDirectory: fixture.engine)
        #expect(bridge.state == .registered)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.registration.path) == fixture.manifest.path)
        #expect(try Data(contentsOf: fixture.registration) == original)
        bridge.prepare(engineDirectory: fixture.engine)
        #expect(bridge.state == .registered)
        #expect(try Data(contentsOf: fixture.manifest) == original)
    }

    @Test("Debug and throwaway engine roots get independent registrations")
    func isolation() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        try fixture.write()
        let debug = fixture.root.appending(path: "debug/engine", directoryHint: .isDirectory)
        let bridge = fixture.bridge()
        bridge.prepare(engineDirectory: fixture.engine)
        bridge.prepare(engineDirectory: debug)
        #expect(bridge.state == .registered)
        #expect(try Data(contentsOf: debug.appending(path: "NativeMessagingHosts/com.apple.passwordmanager.json")) == Data(contentsOf: fixture.registration))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "NativeMessagingHosts").path))
    }

    @Test("User-managed registrations, including dangling links, are never overwritten", arguments: [false, true])
    func preserveExisting(link: Bool) throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        try fixture.write()
        try FileManager.default.createDirectory(at: fixture.hosts, withIntermediateDirectories: true)
        if link {
            try FileManager.default.createSymbolicLink(atPath: fixture.registration.path, withDestinationPath: "/nonexistent/user-managed-host.json")
        } else {
            try Data("user managed".utf8).write(to: fixture.registration)
        }
        let bridge = fixture.bridge()
        bridge.prepare(engineDirectory: fixture.engine)
        #expect(bridge.state == .conflictingRegistration)
        if link {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.registration.path) == "/nonexistent/user-managed-host.json")
        } else {
            #expect(try Data(contentsOf: fixture.registration) == Data("user managed".utf8))
        }
    }

    @Test("A linked host directory cannot redirect registration into another browser")
    func directoryLink() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        try fixture.write()
        let other = fixture.root.appending(path: "other-browser", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.engine, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.hosts, withDestinationURL: other)
        let bridge = fixture.bridge()
        bridge.prepare(engineDirectory: fixture.engine)
        #expect(bridge.state == .conflictingRegistration)
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
    }

    @Test("Missing or untrusted macOS helpers leave no registration")
    func unavailable() throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        let bridge = fixture.bridge(trusted: false)
        bridge.prepare(engineDirectory: fixture.engine)
        #expect(bridge.state == .helperUnavailable)
        try fixture.write()
        bridge.prepare(engineDirectory: fixture.engine)
        #expect(bridge.state == .helperNotTrusted)
        #expect(!FileManager.default.fileExists(atPath: fixture.engine.path))
    }

    @Test("Only Apple's stdio host and exact Apple extension origins are accepted",
          arguments: ["name", "type", "path", "traversal", "wildcard", "extraOrigin", "emptyOrigins"])
    func rejectModifiedManifest(rule: String) throws {
        let override: [String: Any]
        switch rule {
        case "name": override = ["name": "another.host"]
        case "type": override = ["type": "other"]
        case "path": override = ["path": "/tmp/PasswordManagerBrowserExtensionHelper"]
        case "traversal": override = ["path": "/System/Cryptexes/App/System/Library/CoreServices/../untrusted"]
        case "wildcard": override = ["allowed_origins": ["chrome-extension://*/"]]
        case "extraOrigin": override = ["allowed_origins": ["chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/", "chrome-extension://untrusted/"]]
        default: override = ["allowed_origins": [String]()]
        }
        let fixture = Fixture()
        defer { fixture.clean() }
        try fixture.write(override)
        let bridge = fixture.bridge()
        bridge.prepare(engineDirectory: fixture.engine)
        #expect(bridge.state == .helperNotTrusted)
        #expect(!FileManager.default.fileExists(atPath: fixture.engine.path))
    }
}
