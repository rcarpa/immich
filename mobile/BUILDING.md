# Building and installing Mirrich

Two routes. **iPhone** is §0–§5 and needs a Mac and a paid Apple Developer
account. **Android** is §7 and needs neither — a Linux, Mac or Windows machine
with the Android SDK will do, and there is nothing to pay for or register.

The mirror is Dart; the only per-platform part is the store the image path reads
through (`OfflineStore.swift`, `OfflineStore.kt`).

## 0. Before you start (iPhone)

- **A *paid* Developer Program membership ($99/year) is required.** The app, its
  share extension and its widget share an **App Group**, and it requests **Access
  WiFi Information** — both unavailable on the free tier.
- **The bundle ID (§3) is a one-way door.** iOS identifies an app by that string,
  so changing it later gives you a *different app*: empty database, and the whole
  offline mirror downloads again.
- Xcode is ~10 GB. Budget an hour or two for the first build.

## 1. One-time Mac setup

### 1.1 Xcode

Install from the Mac App Store, open it once to let it add iOS platform support,
then:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcode-select --install          # harmless if already present
```

### 1.2 CocoaPods

Flutter cannot build the iOS app without it.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install cocoapods
```

### 1.3 mise

The repo pins Flutter, Java and DCM through [mise](https://mise.jdx.dev). Do
**not** install Flutter separately — you will get a version mismatch.

```bash
curl https://mise.run | sh
```

Follow the printed instruction to add it to your shell, then restart the terminal.

## 2. One-time project setup

```bash
ulimit -n 8192                 # codegen opens more than the default 256; same shell as below

git clone <your-fork-url> immich
cd immich/mobile

mise trust
mise install                   # from mobile/: the pinned Flutter, Java 21, DCM
mise run //mobile:checkout     # pub get + pod install + ALL code generation
```

Three things that fail confusingly:

- **Run `mise install` from `mobile/`.** Flutter and DCM are pinned in
  `mobile/mise.toml`, not the root config. Re-run it after a rebase that moves the
  pin; both build scripts do it if the pinned SDK is missing.
- **Task names are relative**, so `mise run checkout` at the root resolves to
  `//:checkout`, which does not exist. `//mobile:checkout` works from anywhere.
- **`//mobile:checkout` is not optional.** The OpenAPI client, `lib/generated/`
  and every `*.g.dart` / `*.drift.dart` / `*.freezed.dart` are generated, not
  committed. Re-run it after every pull or rebase.

Ignore mise's prompt to `sudo ln -s` the JDK — that is for Android builds.

## 3. One-time signing setup

### 3.1 Fill in your identity

Upstream's signing values point at the Immich project's own team. Override them in
`ios/Signing.local.xcconfig`, which is gitignored so your identity stays out of the
fork. It already exists with placeholders:

```
IMMICH_TEAM_ID        = <your 10-char Team ID>
IMMICH_BUNDLE_ID_PROD = me.yourname.mirrich
IMMICH_BUNDLE_ID_DEV  = me.yourname.mirrich.dev
IMMICH_GROUP_ID       = group.me.yourname.mirrich
```

Team ID: <https://developer.apple.com/account> → Membership details, like
`A1B2C3D4E5`. Do not append `.ShareExtension`, `.Widget`, `.debug` or `.profile` —
the project derives those from the two roots.

**Comments are `//`, never `#`**, which fails with `unsupported preprocessor
directive`.

### 3.2 The App Group

All three targets share one App Group, where the auth cookies live; it is required
even for a build on your own phone. Automatic signing usually registers it (§3.3).
Only if the build fails with *"Provisioning
profile doesn't include the `com.apple.security.application-groups` entitlement"*,
then create it by hand at
<https://developer.apple.com/account/resources/identifiers/list/applicationGroup>
(**+** → App Groups, identifier exactly your `IMMICH_GROUP_ID`) and re-add the
capability in Xcode.

### 3.3 Point Xcode at your team

Open the **workspace**, not the project:

```bash
open ios/Runner.xcworkspace
```

Select the **Runner** project, then for each of **Runner**, **ShareExtension** and
**WidgetExtension** → *Signing & Capabilities*: tick **Automatically manage
signing**, set **Team**, and confirm **App Groups** lists your group.

### 3.4 Confirm the fork's native file is in the build

*Runner* target → *Build Phases* → *Compile Sources* must list
`ios/Runner/Images/OfflineStore.swift`, which this fork registered in
`project.pbxproj` by hand. If it is missing, drag it in (target membership: Runner
only), or the build fails with "cannot find 'OfflineStore' in scope".

## 4. Build and install on your iPhone

1. Connect by cable, tap **Trust**, and enable *Settings → Privacy & Security →
   Developer Mode* (then reboot).
2. From Xcode: pick your iPhone, the **Runner** scheme, and press ▶. Or:

   ```bash
   flutter devices
   flutter run --release -d <device-id>    # debug builds are slower and expire sooner
   ```
3. First launch refuses with an untrusted-developer error: *Settings → General →
   VPN & Device Management* → your certificate → **Trust**.
4. Log into your Immich server, then choose what to keep under *Settings →
   Offline copies*.

### 4.1 Alternative: AltStore

`tools/build_release.sh` (run it with `--help`) builds an unsigned IPA plus the
source manifest to serve beside it; serving those files is your web server's
business. AltStore re-signs on install and has to reproduce the App Group (§3.2) —
suspect that first if the app installs but cannot log in.

### 4.2 A second build alongside the first

A second bundle ID is a second app with its own data; the installed one is
untouched. One AltStore source can list both.

In `ios/Signing.local.xcconfig`:

```
IMMICH_BUNDLE_ID_PROD = me.example.mirrichdev
IMMICH_GROUP_ID       = group.me.example.mirrichdev
```

Separate the group too, or the two apps share cookies and overwrite each other's
server URL.

Then in `tools/altstore.env`, match the ID and name it:

```
ALTSTORE_BUNDLE_ID="me.example.mirrichdev"
ALTSTORE_APP_NAME="Mirrich Dev"
```

Leave `ALTSTORE_BASE_URL` alone and build as before; the first app's entry is
kept. Both apps share the icon and the `immich://` scheme.

## 5. Keeping it installed, and TestFlight

A directly installed build expires with its development profile after a year.
TestFlight builds last 90 days, update over the air and need no App Store
submission.

### 5.1 One-time setup with Apple

1. **Register the bundle ID.** <https://developer.apple.com/account> →
   *Identifiers* → **+** → App IDs → App, using exactly your
   `IMMICH_BUNDLE_ID_PROD`. Tick **App Groups**, **Associated Domains**, **Access
   Wi-Fi Information** and **Push Notifications**, and attach the App Group.
   Background work needs no capability — it is declared by `UIBackgroundModes` in
   `Info.plist`, which is why the portal does not offer one.
2. **Create the app record.** <https://appstoreconnect.apple.com> → *Apps* → **+**.
   The name must be unique across the App Store, so plain "Mirrich" may be taken;
   it is what testers see and is independent of the home-screen name.
3. **Signing.** Xcode → *Settings → Accounts*, add the membership account and press
   *Download Manual Profiles*. §3 already points every target at your team.
4. **Upload credentials** (only if the script should upload). Copy
   `tools/testflight.env.example` to `tools/testflight.env` and fill in either an
   **app-specific password** from <https://appleid.apple.com> — your account
   password will not work — kept out of the file with `@keychain:NAME`:

   ```bash
   security add-generic-password -a "you@example.com" -s MIRRICH_APP_PASSWORD -w
   ```

   or an **App Store Connect API key** (*Users and Access* → *Integrations*),
   whose `.p8` — offered exactly once — goes in
   `~/.appstoreconnect/private_keys/AuthKey_<KEY-ID>.p8`.

Export compliance is already answered: `Info.plist` sets
`ITSAppUsesNonExemptEncryption` to `false`.

### 5.2 Build and upload

```bash
./tools/build_release.sh --testflight            # signed .ipa, nothing uploaded
./tools/build_release.sh --testflight --upload   # and send it to Apple
```

The IPA lands in `dist_testflight/all/`, and on its own in
`dist_testflight/latest/`, ready for Transporter.app, Xcode's Organizer or a later
`--upload` run. `--upload` validates first, so a rejection arrives in seconds
rather than by email.

The build number is a UTC timestamp, passed through `$(FLUTTER_BUILD_NUMBER)` in
`Info.plist` (upstream ships literals there, so keep the fork's side on a
conflict). The version name is `pubspec.yaml`'s numeric core (`3.4.0` for
`3.4.0-rc.1`), since App Store Connect accepts only integers; file names in `all/`
keep the full string.

### 5.3 In App Store Connect

*Processing* takes a few minutes to half an hour, then the build appears under
*TestFlight* and stays installable for **90 days**.

- **Internal testers** — up to 100 on your team, no review. Add them under *Users
  and Access*, then to an internal group.
- **External testers** — up to 10,000, by email or public link, via *Beta App
  Review* once per version (usually a day or less). Fill in *Test Information* and
  *App Privacy* first; nothing can be submitted until those are answered.

The catch for a self-hosted client: **the reviewer has to be able to log in.** An
app stuck on a server-URL prompt is rejected as non-functional. Tick *Sign-in
required* and give a demo Immich server with credentials, explaining that the app
is a client for the user's own server.

The home-screen name comes from `CFBundleDisplayName` and stays "Mirrich"
regardless of the App Store Connect name.

### 5.4 About the App Store

You can submit it. The name and icon are deliberately distinct from Immich, which
keeps you clear of the trademark, but the app is AGPL-licensed and Apple's terms
have historically conflicted with the (A)GPL's redistribution conditions — worth
researching first. None of this affects personal installation or TestFlight.

## 6. After pulling or rebasing on upstream

```bash
git fetch origin
git rebase origin/main
mise run //mobile:checkout       # regenerate everything
cd ios && pod install --repo-update   # if Xcode starts complaining
```

Then go through the rebase checklist in `mobile/FORK.md` §5.

## 7. Android

No developer account, no signing ceremony, no Mac. One command:

```bash
mise run //mobile:checkout        # first time, or after a rebase
./tools/build_android.sh          # universal APK -> dist_android/
```

`dist_android/` is laid out like the iOS routes: `all/` accumulates every build
and `latest/` holds this one under a stable name, so the same rsync-to-a-host
story works. `--split` builds per-ABI APKs instead (about a third of the size
each, but whatever serves them has to pick the right one), and `--bundle` an
`.aab` for Play.

### 7.1 Identity

Upstream's application id is `app.alextran.immich`. A build that keeps it cannot
sit beside upstream's app. Set your own in `android/Identity.local.properties`
(gitignored), beside the committed default in `android/Identity.properties`:

```
applicationId = me.yourname.mirrich
```

Use the reverse of a domain you control. Like the iOS bundle ID, this is a
one-way door: changing it later gives a different app that downloads everything
again. `build_android.sh` warns if it is not set.

### 7.2 Signing

Upstream's mechanism, unchanged: put a keystore at `android/key.jks` and its
passwords in `android/key.properties`, or point `ANDROID_KEYSTORE` at one and set
`ALIAS`, `ANDROID_KEY_PASSWORD` and `ANDROID_STORE_PASSWORD`. `tools/android.env`
is read if present and is gitignored.

With no keystore Gradle signs with the debug key, which works but can never be
upgraded in place by a properly signed build; uninstalling takes the offline
library with it.

### 7.3 The JDK, which is where this goes wrong

Flutter prefers Android Studio's bundled JDK over `JAVA_HOME`, and it is newer
than Gradle accepts (`Unsupported class file major version`). `build_android.sh`
names the JDK explicitly; set `MIRRICH_JDK` if `mise where java` is not the one
you want.

### 7.4 The SDK

Flutter wants **Android SDK 36**. If `flutter doctor` says otherwise:

```bash
sdkmanager "platforms;android-36" "build-tools;36.0.0"
sdkmanager --licenses
```

### 7.5 Checking the store

The file name is derived once, in the Rust core (`native/crates/native_core/src/offline_name.rs`), which Dart, Swift
and Kotlin call. Its fixture holds the names stored files already have:

```bash
cd ../native && cargo test -p native_core --features offline_name
```

After changing the core's exported functions, regenerate the header and the Dart bindings with
`mise run codegen:native` (ffigen needs `CPATH` pointing at clang's headers on Linux).

## 8. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Hundreds of missing files / undefined classes in Dart | Code generation never ran. `mise run //mobile:checkout`. |
| Android: `Unsupported class file major version` | Android Studio's bundled JDK, which Flutter prefers over `JAVA_HOME`. §7.3. |
| Android: `Flutter requires Android SDK 36` | §7.4. |
| Android: R8 fails with `NoSuchFileException` naming an intermediate | Two Gradle invocations into one build directory. Build one shape per run, or `flutter clean` between them. |
| Android: stored photos still hit the network | The Kotlin file name has drifted from the Dart one. §7.5. |
| Android: `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | This build still calls itself `app.alextran.immich` and Immich is installed. §7.1. |
| `No profiles for 'me.yourname.mirrich' were found` | Team not set, or automatic signing unticked. Redo §3.3 for **all three** targets. |
| `Failed to register bundle identifier` | Somebody owns that ID. Change the roots in `Signing.local.xcconfig`. |
| `Provisioning profile doesn't include com.apple.security.application-groups` | The App Group is missing or unattached. §3.2, then re-add the capability. |
| `Cannot find 'OfflineStore' in scope` | The fork's Swift file is not in Compile Sources. §3.4. |
| Associated Domains fails to provision | The entitlement references `applinks:my.immich.app`, which you do not own. Deep links from it will not work; if it blocks signing, delete `com.apple.developer.associated-domains` from `ios/Runner/Runner.entitlements`. |
| `CocoaPods could not find compatible versions` | `cd ios && pod install --repo-update` |
| `Too many open files (os error 24)` | `ulimit -n 8192` in that shell. Persists? `sudo launchctl limit maxfiles 65536 200000`. |
| `mise ERROR no task //:checkout found` | You are at the repo root. `mise run //mobile:checkout`. |
| `Application not configured for iOS` | Flutter cannot find Xcode. `xcode-select -p` must print `/Applications/Xcode.app/Contents/Developer` (§1.1). `pub get` and `pod install` succeeding first is expected. |
| CocoaPods "did not set the base configuration" | Benign, and upstream's design: the Pods config is included one level down by `ios/Flutter/Debug.xcconfig`, which CocoaPods cannot see. Ignore. |
| Flutter version errors | A system Flutter is shadowing mise's. `which flutter` should point inside `~/.local/share/mise`, and every command here goes through `mise exec` for that reason. |
| `Because immich_mobile requires Flutter SDK version X, version solving failed` | Upstream moved the pin and this machine still has the old SDK. `mise install` from `mobile/`. |
| Old Immich icon after a build | iOS caches icons. Delete the app and reinstall. |
| Photos vanish offline | Nothing selected, or downloading unfinished or off. *Settings → Offline copies*. |

## 9. Where the branding lives

| What | Where |
| --- | --- |
| Home screen name | `ios/Runner/Info.plist` → `CFBundleDisplayName` |
| App switcher / in-app title | `lib/main.dart` → `MaterialApp.router(title:)` |
| App icon (all 34 sizes) | `ios/Runner/Assets.xcassets/AppIcon.appiconset/` |
| Splash + in-app logo | `assets/mirrich-logo.png` |
| Icon source of truth | `tools/make_icon.py` |

The icon is generated. Edit the geometry constants at the top of
`tools/make_icon.py` (`R_IN` the aperture opening, `TWIST` the spiral, `GAP` the
seam) and regenerate — needs `python3`, `pillow` and `rsvg-convert`
(`brew install librsvg`):

```bash
cd mobile
python3 tools/make_icon.py /tmp/icons \
  16 20 29 32 40 48 50 55 57 58 60 64 66 72 76 80 87 88 92 100 102 114 120 128 \
  144 152 167 172 180 196 216 256 512 1024
for f in ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png; do
  cp "/tmp/icons/$(basename "$f")" "$f"
done
cp /tmp/icons/1024.png assets/mirrich-logo.png
```

Five blades echo Immich's aperture mark so the lineage is legible, while a single
amber on near-black and a shut iris make it a different app at a glance.
