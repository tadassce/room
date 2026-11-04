# Apple Passwords: fork-owner and maintainer quickstart

## Do I need the original developer?

**No.** Apple approves the browser's signing identity, not its source repository. An eligible organization's Apple Developer **Account Holder** can request the managed browser capability for a fork's own App ID. An individual developer account may need to become an organization account; ask Apple about eligibility. Approval, a provisioning profile and the signing certificate must belong to the same developer account. Do not share private signing keys or impersonate another browser's bundle/team identity.

Request:

https://developer.apple.com/contact/request/macos-browsers-passkeys/

Capability: `com.apple.developer.web-browser.public-key-credential`.

Apple's requirements:

https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential

For an independently distributed fork, register your **own unique bundle identifier**, update the app identity in `xcodegen/base.yml` and RoomCore's identity in `Engine/roomcore/room/branding/BRANDING`, and separate its storage identities in `Packages/Infra/Sources/Infra/AppPaths.swift` so it never opens an installed original Room's state. Adapt the verification script's explicit Debug-ID guard in `scripts/apple-passwords-check.rb` to your own Debug ID as well; never point it at a release app. Use your own signing/update configuration (see `docs/setup.md`). Do not use the original project's update feed or signing keys for your own releases. This integration reads the actual built app's bundle ID and signer; it does not hard-code the original developer's team into the new signing checks.

## What this change supplies

- **Apple's native host:** on startup, an entitled RoomCore app verifies Apple's system helper and links Apple's manifest into the selected engine root's `NativeMessagingHosts`. No executable is copied, no other browser's profile is read, and Apple's allowed extension origins are not broadened. Existing user-managed registrations are not overwritten. Default/unapproved builds register nothing.
- **Native passkey parent:** patch `0032-webauthn-native-window-hook.patch` supplies the requesting Room page's actual AppKit window to Chromium's existing iCloud passkey discovery. It does not replace WebAuthn validation or intercept credentials in JavaScript. Non-Room/detached pages keep Chromium's original path.
- **Safe signing opt-in:** `ROOM_PASSKEYS_PROFILE` enables the managed entitlement only for an approved, matching profile. The default `Room.entitlements` remains unchanged. Invalid profiles or a mismatched signer stop signing before notarization.
- **Visible status:** Settings → Privacy → Passwords and passkeys explains unavailable builds, missing/untrusted helpers and registration conflicts. Open Passwords opens Apple's app; Set Up Autofill opens Apple's extension instructions only after registration. “Helper registered” is not a claim that the extension has connected or that a credential operation passed.

Passwords/verification codes use Apple's **iCloud Passwords extension**. Passkeys use Chromium's implementation of Apple's public browser APIs and native macOS authorization UI. Safari's private password UI is not a public integration API; this change does not promise that UI or every Safari-only feature. Room's local passwords remain separate. Do not disable the local manager merely because an extension is installed: use the extension's supported browser controls or an explicit user choice.

## Maintainer: the shortest adoption path

1. Merge these changes; request the capability for the app you distribute (Room's existing ID is `app.room.desktop`). Include `app.room.desktop.dev` if you want entitled Debug builds. Release approval does not automatically cover Debug's different ID.
2. After Apple approves, download a **macOS Developer ID provisioning profile** containing this capability, your exact App ID and your current Developer ID certificate. No wildcard App ID. Keep it outside the repository.
3. On the existing build machine, rebuild the engine once (the patch series now includes 0032), then package normally:

```sh
env -u GOROOT ROOM_BUILD_JOBS=6 ROOM_OUT_DIR=out/release ROOM_GN_ARGS=release.gn scripts/roomcore-build.sh
scripts/roomcore-package.sh --release
```

For a long/clean build, use the background/nohup procedure in `docs/setup.md`; do not edit `//room` while it builds. Clear an inherited `GOROOT` only for this build as above: Dawn uses a pinned Go binary, and a Homebrew Go root can silently override its standard library with an incompatible version. Do not change your global Go installation or delete its cache.

4. Sign with the profile. The existing release pipeline inherits the same variable, so no extra release step is needed:

```sh
ROOM_PASSKEYS_PROFILE="$HOME/Downloads/Room.provisionprofile" \
  scripts/roomcore-sign.sh
```

A fork using its own certificate can instead sign its built app directly:

```sh
ROOM_PASSKEYS_PROFILE="$HOME/Downloads/MyBrowser.provisionprofile" \
ROOM_SIGN_IDENTITY="Developer ID Application: Your Organization (YOURTEAMID)" \
ROOM_NOTARY_PROFILE="your-notary-profile" \
  scripts/sign-and-notarize.sh /absolute/path/to/Room.app
```

Use `--no-notarize` for a local entitled Debug build, with the **Debug App ID's** approved profile. No Apple account credentials or private keys need to be sent to a contributor.

5. Install/enable iCloud Passwords in the target Room profile using Settings → Privacy → Set Up Autofill. Open its extension action and complete Apple's unlock/authorization. Other Room profiles have their own extension installations.

## Checks before shipping

Before a push, run the local CI spec (GitHub CI is disabled):

```sh
xcodegen --spec xcodegen/ci.yml --project-root . --project .
CI=1 xcodebuild -project Room.xcodeproj -scheme Room -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/apple-passwords/ci \
  CODE_SIGNING_ALLOWED=NO build test
xcodegen
/usr/bin/ruby scripts/tests/test_passkeys_signing.rb
/usr/bin/ruby scripts/tests/test_roomcore_gn.rb
```

Run the window tier with the normal `Room` scheme and `CI`/`ROOM_CI` unset; run the usual engine baseline and password/extension checks after packaging. The console must be unlocked for UI-sensitive checks; a wrapper's zero exit status is not proof when its spike reports missing bubbles/popups or `window_main: false`. Verify an opted-in signed app without changing it using `/usr/bin/ruby scripts/passkeys-signing.rb --verify /absolute/path/to/Room.app`.

For the default **unapproved Debug app over a `dev.gn` framework** (`room_enable_spikes=true`), run:

```sh
scripts/apple-passwords-check.rb /absolute/path/to/a/fresh/evidence-directory
```

This bounded check uses throwaway state, a loopback fixture and the Debug app only. It checks the real startup entitlement gate and calls the **actual installed production window callback** for requesting pages in two windows, detached/reattached and moved. The private diagnostic is absent from release engines. It neither launches Apple's helper nor requests a credential; it is not an end-to-end passkey test.

On an **approved Debug build, with throwaway Room state**, verify:

- The main app has the browser entitlement and the correct embedded profile/signing certificate; helpers have not gained the browser entitlement. The final release re-signing preserves both profile and entitlement.
- Settings reports “Apple helper registered”; the actual extension connects (not merely a manifest file appearing). Unlock prompts are Apple's and are answered by the developer, not automated away.
- With a disposable account: password save, update and fill, verification codes and generation where Apple's extension offers them; no duplicate Room save offers or credentials leaked to another origin/frame.
- At https://webauthn.io register and authenticate a disposable passkey. Check conditional suggestions, cancel/retry, navigation/tab close, incognito and two windows. The macOS sheet must belong to the window containing the requesting page, including after moving a tab. Remove the disposable credential from Passwords afterwards.
- No passwords, verification codes or credential payloads in logs, screenshots or diagnostics. A capability probe alone does not prove any of these flows.

## Message you can send the original developer

> I traced the iCloud Passwords helper failure: Apple's signed parent-launch constraints require the managed browser/passkey entitlement (or Apple's browser/team allowlist). Room currently has neither the entitlement nor native-host registration. I've implemented host registration, the AppKit window hook for Chromium passkeys, approved-profile opt-in signing, tests and a setup guide, and built the patched engine and Debug apps. Could you request Apple's macOS browser passkey capability for Room's release App ID (and Debug ID for testing), then provide the resulting profile **on your build machine**? No private-key sharing is needed; the existing signing pipeline takes `ROOM_PASSKEYS_PROFILE`. Please rebuild RoomCore with patch 0032 and run the entitled credential checks before calling the issue fixed.

## Verification status of this contribution

The patched component RoomCore engine and both ad-hoc-signed Debug apps **built successfully** on this fork machine (2026-11-04): engine compilation/linking **6 h 39 min 48.9 s**, with three jobs on an M1 / 16 GiB. Both app signatures verify. Real navigation/back/forward/reload and three ten-page quits passed, with no new crash reports or leftover helpers. The initial locked-console UI measurement was inconclusive. After unlock, actual local password save/update and two-site fill after relaunch passed, as did address/card autofill and light/dark host-popover responses. The separate reverse-Tab window failure was traced to scroll-container focus proxies and fixed without weakening its assertion; the full window tier and local CI pass. A stale Debug-only Cmd-T probe was corrected; its final rebuilt-app UI confirmation is pending because the Mac auto-locked again. No approved Room profile is available. The actual installed window callback passed two-window, detach/reattach and page-move checks; the unapproved startup gate/manifest absence passed, with zero non-page network hosts. Local CI was rerun: **753 tests passed**. Remaining UI/credential results are in `docs/progress.md`. **A real Apple Passwords/passkey transaction still must be demonstrated before calling the integration fixed.**

Detailed system evidence: `research/notes/apple-passwords.md`.
