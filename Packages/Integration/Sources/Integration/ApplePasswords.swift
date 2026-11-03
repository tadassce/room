import Foundation
import Observation
import Security

/// Registers Apple's own native-messaging host, never a copy of its executable
/// or another browser's profile. The managed entitlement is checked before any
/// filesystem change: unapproved builds remain usable, without a broken host.
@Observable
public final class ApplePasswords {
    public nonisolated static let browserEntitlement = "com.apple.developer.web-browser.public-key-credential"
    public nonisolated static let hostName = "com.apple.passwordmanager"
    public nonisolated static let extensionHelpURL = URL(string: "https://support.apple.com/en-us/guide/passwords/get-extensions-mchlf7ac261e/mac")!

    public nonisolated enum State: Equatable, Sendable {
        case notPrepared
        case approvalRequired
        case helperUnavailable
        case helperNotTrusted
        case conflictingRegistration
        case registered
        case failed(String)

        public var title: String {
            switch self {
            case .notPrepared: "Not available with this engine"
            case .approvalRequired: "Not enabled in this build"
            case .helperUnavailable: "macOS helper not found"
            case .helperNotTrusted: "Apple helper could not be verified"
            case .conflictingRegistration: "Existing helper configuration"
            case .registered: "Apple helper registered"
            case .failed: "Helper setup failed"
            }
        }

        public var detail: String {
            switch self {
            case .notPrepared:
                "Apple Passwords requires RoomCore."
            case .approvalRequired:
                "Apple Passwords and iCloud passkeys require Apple's browser entitlement in this build's signing profile. Room's local password manager is separate and remains available."
            case .helperUnavailable:
                "Install the latest macOS update. Room uses the Passwords helper supplied by macOS."
            case .helperNotTrusted:
                "Room left the helper unchanged because its Apple signature or extension permissions could not be verified."
            case .conflictingRegistration:
                "Room left an existing NativeMessagingHosts configuration in its engine folder unchanged."
            case .registered:
                "Enable iCloud Passwords in each profile where you want autofill, then unlock it when prompted. Apple controls its password and verification-code features; iCloud passkeys use macOS authorization."
            case .failed(let reason): reason
            }
        }
    }

    public private(set) var state: State = .notPrepared
    @ObservationIgnored private let manifestURLs: [URL]
    @ObservationIgnored private let isEntitled: () -> Bool
    @ObservationIgnored private let verifyHelper: (URL) -> Bool

    public convenience init() {
        self.init(manifestURLs: [
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json"),
            URL(fileURLWithPath: "/System/Cryptexes/App/Library/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json")
        ], isEntitled: Self.hasBrowserEntitlement, verifyHelper: Self.isAppleHelper)
    }

    // Injectable only inside the module/tests; production always uses Security.
    init(manifestURLs: [URL], isEntitled: @escaping () -> Bool, verifyHelper: @escaping (URL) -> Bool) {
        self.manifestURLs = manifestURLs
        self.isEntitled = isEntitled
        self.verifyHelper = verifyHelper
    }

    /// Before engine startup, using exactly EngineConfiguration.userDataDirectory
    /// (including the Debug/throwaway override). No credential requests or UI.
    public func prepare(engineDirectory: URL) {
        guard isEntitled() else { state = .approvalRequired; return }
        let files = FileManager.default
        guard let source = manifestURLs.first(where: { files.fileExists(atPath: $0.path) }) else {
            state = .helperUnavailable
            return
        }
        do {
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 16_384,
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: source)),
                  manifest.isAppleHost, verifyHelper(URL(fileURLWithPath: manifest.path)) else {
                state = .helperNotTrusted
                return
            }
            guard engineDirectory.isFileURL else {
                state = .failed("The engine folder must be a local directory.")
                return
            }
            let directory = engineDirectory.resolvingSymlinksInPath().appending(path: "NativeMessagingHosts", directoryHint: .isDirectory)
            // Do not follow a registration directory into another browser or
            // the user's real state from a throwaway run.
            if (try? files.destinationOfSymbolicLink(atPath: directory.path)) != nil {
                state = .conflictingRegistration
                return
            }
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appending(path: "\(Self.hostName).json")
            if let destination = try? files.destinationOfSymbolicLink(atPath: target.path) {
                let linked = URL(fileURLWithPath: destination, relativeTo: directory).resolvingSymlinksInPath()
                state = linked == source.resolvingSymlinksInPath() ? .registered : .conflictingRegistration
                return
            }
            guard !files.fileExists(atPath: target.path) else {
                state = .conflictingRegistration
                return
            }
            // Exclusive creation: never overwrite a concurrently installed or
            // user-managed host. The symlink follows macOS helper updates.
            try files.createSymbolicLink(at: target, withDestinationURL: source)
            state = .registered
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public nonisolated static func hasBrowserEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, browserEntitlement as CFString, nil) else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID() && CFEqual(value, kCFBooleanTrue)
    }

    private nonisolated static func isAppleHelper(_ executable: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString("anchor apple and identifier \"com.apple.PasswordManagerBrowserExtensionHelper\"" as CFString,
                                             [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    private nonisolated struct Manifest: Decodable {
        let name: String
        let type: String
        let path: String
        let allowed_origins: [String]

        var isAppleHost: Bool {
            let executable = "System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper"
            let paths = ["/\(executable)", "/System/Cryptexes/App/\(executable)"]
            let origins: Set<String> = [
                "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/",
                "chrome-extension://mfbcdcnpokpoajjciilocoachedjkima/"
            ]
            return name == ApplePasswords.hostName && type == "stdio" && paths.contains(path)
                && !allowed_origins.isEmpty && Set(allowed_origins).isSubset(of: origins)
        }
    }
}
