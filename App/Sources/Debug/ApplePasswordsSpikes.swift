#if DEBUG
import AppKit
import Engine
import Integration
#if ROOM_ENGINE_ROOMCORE
import EngineRoomCore
#endif

extension SpikeRunner.Context {
    /// Unapproved-build safety and the actual installed native-window callback.
    /// No Apple credential request, helper launch or keychain access. The callback
    /// is probed directly: this is not proof of an authorized passkey transaction.
    func applePasswordsChecks() async {
        #if ROOM_ENGINE_ROOMCORE
        guard let app = AppDelegate.current, let first = app.windows.all.first,
              let window1 = first.window,
              let profile = await activeEngineProfile(app) as? RoomCoreProfile,
              let engineDirectory = AppDelegate.debugEngineDirectory,
              let fixture = UserDefaults.standard.string(forKey: "RoomApplePasswordsFixtureURL").flatMap(URL.init(string:)),
              fixture.scheme == "http", fixture.host == "127.0.0.1" else {
            return SpikeRunner.record("error", "requires RoomCore, throwaway state and a loopback fixture")
        }
        guard !ApplePasswords.hasBrowserEntitlement() else {
            return SpikeRunner.record("error", "negative entitlement check requires an unapproved build; no credentials requested")
        }
        let manifest = engineDirectory.appending(path: "NativeMessagingHosts/\(ApplePasswords.hostName).json")
        let absent = !FileManager.default.fileExists(atPath: manifest.path)
            && (try? FileManager.default.destinationOfSymbolicLink(atPath: manifest.path)) == nil
        SpikeRunner.record("apple_passwords_gate", "passed=\(app.applePasswords.state == .approvalRequired && absent) entitlement=false manifest_absent=\(absent)")

        guard let page1 = try? profile.makeWebContents(WebContentsConfiguration(hostWindow: window1)) else {
            return SpikeRunner.record("error", "could not create first probe page")
        }
        defer { page1.close() }
        hostScratch(page1, in: window1)
        page1.load(fixture, transition: .typed, fromAddressBar: true)
        await waitLoaded(page1, timeout: 10)

        app.newRoomWindow(nil)
        _ = await waitUntil(5) { app.windows.all.count == 2 }
        guard let second = app.windows.all.last, second !== first, let window2 = second.window,
              let page2 = try? profile.makeWebContents(WebContentsConfiguration(hostWindow: window2)) else {
            return SpikeRunner.record("error", "could not create second probe window/page")
        }
        defer {
            page2.close()
            window2.performClose(nil)
        }
        hostScratch(page2, in: window2)
        page2.load(fixture, transition: .typed, fromAddressBar: true)
        await waitLoaded(page2, timeout: 10)
        SpikeRunner.record("webauthn_fixture", "passed=\(page1.title == "Room WebAuthn window fixture" && page2.title == "Room WebAuthn window fixture")")

        func probe(_ label: String, _ page: any WebContents, in host: NSWindow, attached: Bool = true) async {
            // EngineRoomCore owns an outer view around RoomWebContents' view.
            // Identify the requesting wrapper in its Browser, regardless of
            // the selected tab or whether macOS lets this app become active.
            let browser = profile.spikeBrowsers.first { candidate in
                candidate.window === host && candidate.webContents.contains { $0.nativeView?.isDescendant(of: page.nativeView) == true }
            }
            let native = browser?.webContents.first { $0.nativeView?.isDescendant(of: page.nativeView) == true }
            let flags = native.flatMap { SpikeRunner.spikeHook(browser, "roomSpikeWebAuthnWindow:", $0) }?.intValue ?? -1
            let placement = attached ? page.nativeView.window === host : page.nativeView.window == nil
            SpikeRunner.record(label, "passed=\(placement && flags == (attached ? 63 : 37)) flags=\(flags) expected=\(attached ? 63 : 37)")
        }
        SpikeRunner.record("webauthn_windows", "distinct=\(window1 !== window2) first_main=\(window1.isMainWindow) second_main=\(window2.isMainWindow)")
        await probe("webauthn_first_after_second", page1, in: window1)
        await probe("webauthn_second", page2, in: window2)

        // A detached view must yield nil, never another live window.
        page1.nativeView.removeFromSuperview()
        await probe("webauthn_detached", page1, in: window1, attached: false)
        hostScratch(page1, in: window1)
        await probe("webauthn_reattached", page1, in: window1)

        // Exercise the production move API, preserving the same requesting page.
        do {
            try page1.move(toHostWindow: window2)
            hostScratch(page1, in: window2)
            await nextRunLoopTurn()
            await probe("webauthn_moved", page1, in: window2)
        } catch {
            SpikeRunner.record("error", "probe page move failed: \(error)")
        }
        SpikeRunner.record("credential_transaction", "not attempted (Apple approval/profile required)")
        #else
        SpikeRunner.record("error", "requires the RoomCore Debug app, not the engine-free CI app")
        #endif
    }
}
#endif
