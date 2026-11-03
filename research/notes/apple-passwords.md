# Apple Passwords in Room — diagnosis and implementation gate

2026-11-03. User report: `Screenshot 2026-11-02 at 21.34.30.png`, iCloud Passwords “couldn’t connect to a helper application”. Investigation on macOS 27.2 (26B123), Xcode 27.2, this checkout at `cacc82b`. **Not fixed; no runtime or signing changes made.**

## Findings

### 1. Apple's helper enforces which browser may launch it

The system's Chrome native-messaging manifest is:

`/Library/Google/Chrome/NativeMessagingHosts/com.apple.passwordmanager.json`

It is a root-owned symlink into the App Cryptex. Its host is `com.apple.passwordmanager`, type `stdio`, executable:

`/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app/Contents/MacOS/PasswordManagerBrowserExtensionHelper`

The manifest allows only these extension origins:

- `chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/`
- `chrome-extension://mfbcdcnpokpoajjciilocoachedjkima/`

The helper's signature verifies with `codesign --verify --strict`. `codesign -d --verbose=4 --entitlements :- -r-` prints its signed **parent launch constraints**. Their `$or-array` permits either:

- a parent with `com.apple.developer.web-browser.public-key-credential = true`; or
- an allowlisted signing identifier **and** Team ID (Chrome, Edge, Firefox, Arc/Dia, Brave, Vivaldi and others).

Neither `app.room.desktop` nor `app.room.desktop.dev` is listed. Changing a bundle name or copying a manifest does not supply the required signing authority. Do not modify/re-sign Apple's helper or spoof an allowlisted browser.

Local evidence: `build/apple-passwords/apple-helper-signature.txt` (gitignored; contains the system binary's signature/constraints, no user credentials).

No helper was launched, no user browser profile or keychain was read, and no password prompt was opened. Therefore the exact first failure in the reported session (missing manifest versus denied launch) was not observed. The unentitled Room parent's trust blocker is independently established by the signed constraints.

### 2. Room also has no native-host registration

`App/Resources/Room.entitlements` has no browser passkey entitlement. B-69 deliberately left desktop-app native messaging unconfigured; Settings says it is unsupported. The user's new request supersedes that product decision for Apple Passwords, but not Apple's trust boundary.

Chromium 157.0.8103.26 searches:

1. `chrome::DIR_USER_DATA/NativeMessagingHosts/<host>.json`;
2. `/Library/Application Support/Chromium/NativeMessagingHosts/<host>.json` in an unbranded macOS build.

`RoomApplication` passes its actual engine root through `--user-data-dir`. The first location is therefore Room's selected **engine** root, not the sidebar database's parent and not Chrome's profile. The system Chromium host directory is absent on this machine. Apple's manifest above lives in neither location.

After approval, register the Apple-supplied manifest in Room's selected engine root, preserving its host name and origin restrictions. Never scan/import another browser's profile, blindly enable all of its native hosts, broaden origins, or silently overwrite a user-managed host. Debug/throwaway roots must remain isolated from the shipping root. Test discovery and the actual extension connection separately from successful password retrieval.

Source:

https://chromium.googlesource.com/chromium/src/+/157.0.8103.26/chrome/common/chrome_paths.cc

https://chromium.googlesource.com/chromium/src/+/157.0.8103.26/chrome/browser/extensions/api/messaging/launch_context_posix.cc

### 3. Native passkeys need a window-parent fix as well as the entitlement

Chromium already implements Apple's public AuthenticationServices browser API, WebAuthn validation, passkey registration/assertion and conditional suggestions. Reuse that implementation; do not inject `navigator.credentials` shims or send passwords through page scripts.

In 157, `ChromeAuthenticatorRequestDelegate::ConfigureNSWindow` resolves the page's native view through `views::Widget::GetTopLevelWidgetForNativeView`. Only a non-null widget supplies the `NSWindow` to `FidoDiscoveryFactory`. `MaybeCreatePlatformDiscovery` creates the iCloud authenticator only if `IsSupported()` **and** a native window are present (apart from its explicit test bypass).

Room's page is embedded in its own AppKit window, not a Views window. Its transparent Views modal anchor is a separate child window, not the page's parent. This is an additional source-level integration gap to reproduce on an entitled build: add a tiny native-window anchor seam for Room, leaving Chromium's origin, RP ID, frame permissions, cancellation and credential-selection rules intact. The source path is established; an end-to-end failure on an entitled Room has **not** been measured here.

https://chromium.googlesource.com/chromium/src/+/157.0.8103.26/chrome/browser/webauthn/chrome_authenticator_request_delegate.cc

https://chromium.googlesource.com/chromium/src/+/157.0.8103.26/device/fido/fido_discovery_factory.cc

https://chromium.googlesource.com/chromium/src/+/157.0.8103.26/device/fido/mac/icloud_keychain_sys.mm

## Required external step

Apple calls `com.apple.developer.web-browser.public-key-credential` a **managed capability**. An organization's Apple Developer **Account Holder** must request it; Apple reviews the browser and adds the capability to the account if approved. A plist entry alone is not approval. Obtain an approved provisioning profile for the actual Room signing identity, and establish Debug identity coverage separately; do not add a restricted entitlement to every build while approval is absent.

https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential

https://developer.apple.com/contact/request/macos-browsers-passkeys/

The installed helper explicitly accepts this entitlement as an alternative to its browser allowlist. A separate public helper-allowlisting application process was not established in this investigation.

https://developer.apple.com/documentation/security/defining-launch-environment-and-library-constraints

https://developer.apple.com/documentation/authenticationservices/authenticating-people-by-using-passkeys-in-browser-apps

https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging

https://support.apple.com/en-us/guide/passwords/get-extensions-mchlf7ac261e/mac

## Scope and verification after the gate

Native Apple passkey sheets are supported through the public browser API. Arbitrary-site password autofill through Apple's extension is a separate integration; do not promise Safari's private password UI/API or every provider feature from the passkey entitlement alone. Keep Room's local password store distinct from Apple Passwords and avoid competing save/fill offers using the extension's supported Chromium controls.

Required checks on the session's Debug app and throwaway state:

- Apple helper discovered; the real extension connects; approved signature/profile survives the release signing script.
- Synthetic account: fill, save/update, password generation and verification codes where the Apple extension supports them; redirects and cross-origin frames do not leak credentials.
- Passkey registration/assertion and conditional suggestions, cancellation, navigation/close, incognito and multiple windows; system UI attached to the correct host window. Test origin/RP security using Chromium's existing path, not a replacement.
- No credentials in logs, snapshots or diagnostics. Real accounts, iCloud unlock and authorization prompts remain the user's checks.
- Local CI spec and window tier, engine incremental/package/baseline and the actual Developer ID release before claiming success.

This machine has no `build/RoomCore` stage or Chromium checkout, and only a development signing identity from a different team than Room's release identity. Do not claim engine compilation or credential verification. `CI=1 swift test --package-path Packages/Integration` passed **36 tests in 9 suites** (baseline only; no code changed), log `build/apple-passwords/integration-baseline.log`. XcodeGen 2.46.0 installed through Homebrew for subsequent local CI; the full CI spec was not run and nothing was pushed.
