# Apple Passwords in Room — diagnosis and implementation gate

2026-11-03. User report: `Screenshot 2026-11-02 at 21.34.30.png`, iCloud Passwords “couldn’t connect to a helper application”. Investigation on macOS 27.2 (26B123), Xcode 27.2, this checkout at `cacc82b`. **Initial diagnosis: not fixed; no runtime or signing changes were made in that first step.** The follow-up below prepares the code/signing changes without claiming a working entitled build.

## Follow-up: source preparation, 2026-11-03

The user correctly asked for a useful contribution rather than stopping at the approval gate. Prepared `Integration.ApplePasswords` (entitlement-gated system-host registration and Privacy status), patch 0032 with the page's actual AppKit window, and `ROOM_PASSKEYS_PROFILE` signing (strict profile/identity validation, minimal main-app entitlements, embedding, actual signer-certificate verification). Default entitlements remain unchanged. A fork owner can obtain approval for their own identity; original-developer involvement is not a prerequisite.

Handoff and exact adoption commands: `docs/apple-passwords.md`. No signing keys or account credentials need to be shared.

Measurements/checks on this source-only machine:

- Local CI spec, including the rerun before push: **TEST SUCCEEDED, 753 tests** (`build/apple-passwords/ci.log`, `ci-final.log`; count includes Infra's singular “1 test” summary); the normal project regenerated afterwards.
- Integration package: **43 tests**, passed; signing rules: **26 tests / 123 assertions**, passed on system Ruby. A production certificate-extraction probe against Apple's signed system helper caught incorrect `codesign --extract-certificates` optional-argument syntax; fixed to `--extract-certificates=<prefix>`, with a regression test. Actual extraction now returns the helper's **1,263-byte public signer certificate**.
- Read-only Swift probe: production Security validation accepts the installed Apple helper, and an unentitled process leaves its nonexistent scratch engine root untouched (`build/apple-passwords/runtime-probe.log`). No helper launched or credentials requested.
- Patch 0032 applies and reverse-checks against the pinned upstream file (`157.0.8103.26`, git blob `6c8b88832830ce1120094ce6f6e43d84fc02adb2`). **Not an engine compile.**
- Window tier run: one failure, reverse Tab in `AccessibilityAuditTests.swift:204`; independently reproduced by `swift test --package-path Packages/Palette --filter KeyViewLoopTests`. That suite and all its package dependencies have no source changes in this contribution (and do not depend on Integration). Forward/default order passes. Recorded as B-161, not hidden or attributed to Apple Passwords.

At that source-preparation checkpoint full RoomCore compilation/linking was unverified; it has since passed (below). Actual approved-profile signing/notarization, extension handshake/unlock/fill, and native passkey transactions still need an entitled build machine. The complete Apple Passwords task remains open.

## Actual engine/app build and baseline, 2026-11-04

Built the pinned Chromium **157.0.8103.26**, all **30 patches** including 0032, component `out/dev`, **3 jobs** on the **M1 mini / 16 GiB**. Engine stage **23,988.9 s (6 h 39 min 48.9 s)**; staging **5.5 s**, Debug host **36.7 s**, Debug app **65.0 s**. Both ad-hoc apps pass `codesign --verify --deep --strict`; bundle identity **`app.room.desktop.dev`**, restricted browser entitlement absent. Free disk **23.0 GiB**, 15 GiB reserve preserved. Original completion receipt `build/apple-passwords/engine-build-clean-status.json`; append-only build log `engine-build.log`.

Actual Debug artifacts: `build/roomcore/DerivedData/Build/Products/Debug/Room.app`, `build/roomcore-host/DerivedData/Build/Products/Debug/Room.app`, `build/roomcore/RoomCore.framework`. These are local dev artifacts, not an approved/notarized release.

`roomcore-baseline.sh` on isolated host state: navigation/back/forward/reload **passed, 14.606 s**. Three ten-page live-site quits **0.515 / 0.460 / 0.405 s**, **28 / 28 / 29** helpers observed, **0** helpers left and **0** new crash reports. Evidence `build/apple-passwords/baseline-initial`.

The first full local-password/autofill measurement is **inconclusive**, not passed: `window_main: false`, required offers/popups absent. Public console status confirmed **screen locked**, frontmost **`com.apple.loginwindow`**. The synthetic first-site save did persist, but that is not a save/update/fill pass. Zero non-page hosts in all three launch net-logs. Evidence `build/apple-passwords/passwords-autofill-initial`; its synthetic screenshots preserved separately in `research/screenshots/apple-passwords-runtime/`. User asked to unlock macOS; session will rerun on fresh throwaway state itself, not require real accounts.

Added a dev-only private callback probe and `scripts/apple-passwords-check.rb`: startup negative-entitlement gate plus actual production hook on requesting pages, distinct windows, detach/reattach and the real page-move API. No credentials/helper launch. Initial probe verified the startup gate/manifest absence but did not reach the callback: the harness incorrectly compared EngineRoomCore's outer view with the native wrapper's inner view and assumed the active tab. Corrected to pass the actual owning wrapper independently of tab activation; full Debug rebuild caught and fixed nullable `nativeView` handling. **Actual callback rerun passed:** attached first/second windows **flags 63 / 63**, detached **37** (nil, no borrowed window), reattached/moved **63 / 63**. Flags check installed production hook, exact wrapper window, Browser host, distinction from the Views anchor and null-input nil behavior. Both native windows are distinct despite neither being main on the locked console. Evidence `build/apple-passwords/window-check-final`; **0** non-page hosts (4 fixture/favicon requests), no own app/helper processes left. This is routing proof, not a WebAuthn transaction or Apple authorization. Repeated successfully on committed-source artifacts: staged/embedded framework revision **adba86a**, strict signatures valid, evidence `build/apple-passwords/window-check-committed`.

Local CI spec **rerun before push**, **TEST SUCCEEDED, 753 tests** (`build/apple-passwords/ci-runtime.log`); normal project regenerated. Signing **26 tests / 123 assertions**, GN retry **4 / 21**, passed again. The fresh-state guard rejects a reused evidence directory before launching an app. That checkpoint still awaited console unlock; subsequent results follow. Approved-profile/credential checks remain gated.

## Unlocked-console verification, 2026-11-04

On fresh state (`build/apple-passwords/passwords-autofill-unlocked`), `window_main: true` throughout. Actual host password saves **587 / 762 ms**, update **519 ms**, accepted with Return. After relaunch, both distinct fixture origins fill with **username_matches=true / password_matches=true** and sign in; popups **28 / 25 ms**. Not Now dismisses, Never persists the origin blocklist and suppresses the next offer. Signup's typed password saves; no generation is the existing accepted no-Sync limitation B-72.

Address save/update, suggestion fill, Esc and dismissal on window move pass; secure-fixture card save/fill pass. Own stored data: **3 saved logins + 1 blocklist**, **1 address**, **1 card**; mock-keychain encrypted password/card lengths **19 / 35 bytes**. **0 non-page hosts** across all three launches, no own Crashpad dumps. `password-popover-unlocked/{light,dark}.txt` verifies host UI-delegate response sequence **save,notNow,never,save,notNow,notNow**, saved/update toasts, Manage tab and unanswered withdrawal; **0 dumps** in each run. These UI-delegate cases complement, not replace, the actual engine submissions above. In-process captures are review artifacts under `research/screenshots/apple-passwords-runtime/unlocked-20261104/`.

Actual installed callback on the unlocked console (`window-check-unlocked`): **first_main=false / second_main=true**, correct first/second requesting windows **63 / 63**, detached **37**, reattached/moved **63 / 63**. No Apple credential operation.

Two ancillary diagnostics investigated, not hidden: Cmd-T's false palette reading was a stale spike hook (`SpikeSession` counts requests); the check now restores the existing real palette hooks. B-161's reverse-only failure was real: a **12/12 reciprocal** key-view chain still included a preceding `NSClipView` which redirects focus into the same outline. Exclude scroll containers as stops, continue walking their contents and retain AppKit's selection direction. Original **3/3** tests pass unchanged, full window tier **TEST SUCCEEDED** (`window-unlocked-fixed.log`), local CI rerun **753 passed** (`ci-unlocked-final.log`). No temporary diagnostic code remains. Fix committed separately as **58b0809**.

The Debug app rebuilt and its strict signature verified, but macOS auto-locked before the post-build UI rerun (`passwords-autofill-verified`, `window_main=false`): that rerun is **inconclusive**, not a pass. The user subsequently unlocked the Mac and asked for explicit confirmation: public console status **screen_locked=false / on_console=1**. The final rebuilt-app run stayed unlocked, every window-main marker was true, actual saves/update/Not Now/Never and both relaunch fills passed, and corrected **palette_opened=true / closed=true** (`passwords-autofill-final-unlocked`). Display idle sleep was inhibited only during the owned command; no login/security settings changed or lock bypassed.

Do not call that entire mixed run clean: its address fill read **Room Fi**, its move step found no popup, and the own store contained **two** name tokens, **Room Fixture / Room Fi**. A fresh autofill-only run on the same binary (`autofill-final-recheck`) passed the complete expected address, save/update, Esc, window-move dismissal and card fill; its store has **1** correctly named address and **1** card. The differing seed is established, but its cause is **not** established; retain the mixed run as an anomaly, not a passing result. Follow-up: validate fixture typing/commit before submit and investigate suggestion/focus interaction. No production failure attribution or universal-green claim.

Final password/recheck launches: **0 non-page hosts**, **0 own Crashpad dumps**, no owned app processes left, strict app signature valid. Local CI spec rerun before this session's push: **TEST SUCCEEDED, 753 tests**, `ci-confirmed-unlocked.log`; normal project restored. Real Apple credential transactions still require approval/profile.

## Initial findings

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

At the initial diagnosis this machine had no staged RoomCore framework or Chromium checkout, and only a development signing identity from a different team than Room's release identity. The initial `CI=1 swift test --package-path Packages/Integration` baseline passed **36 tests in 9 suites** (`build/apple-passwords/integration-baseline.log`); XcodeGen 2.46.0 was installed. Full CI had not run at that point. See the follow-ups above for later implementation checks and the successful engine build. Authorized credential verification remains unavailable.
