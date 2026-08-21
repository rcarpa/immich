# Building and installing Mirrich on your iPhone

Assumes a Mac, an iPhone, and an Apple Developer account.

## 0. Before you start

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
mise install                   # from mobile/: pinned Flutter 3.44.9, Java 21, DCM
mise run //mobile:checkout     # pub get + pod install + ALL code generation
```

Three things that fail confusingly:

- **Run `mise install` from `mobile/`.** Flutter and DCM are in `mobile/mise.toml`;
  the root config has everything else, and installs *not* Flutter. Confirm with
  `flutter --version` → 3.44.9.
- **Task names are relative**, so `mise run checkout` at the root resolves to
  `//:checkout`, which does not exist. `//mobile:checkout` works from anywhere.
- **`//mobile:checkout` is not optional.** The `openapi/` client, `lib/generated/`
  and every `*.g.dart` / `*.drift.dart` / `*.freezed.dart` / `router.gr.dart` are
  generated and not committed. Skip it and you get hundreds of "undefined class"
  errors that look like a broken checkout. Re-run it after every pull or rebase.

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

**Comments are `//`, never `#`.** A `#` line is a preprocessor directive, so it
fails the build with `unsupported preprocessor directive 'IMMICH_TEAM_ID'`, which
reads like a broken project rather than a typo.

### 3.2 The App Group

All three targets share one App Group container, and it is required even for a
build on your own phone: `URLSessionManager.swift` keeps the auth cookie store and
shared request headers there, and iOS refuses to install an app whose entitlements
its profile does not cover.

**Usually there is nothing to do** — automatic signing registers it when it sees
the capability in §3.3. Come back only if the build fails with *"Provisioning
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
4. Log into your Immich server. Metadata syncs first, then the offline mirror
   pulls image bytes — watch *Settings → Sync status → Offline library*, and let
   the first pass finish on Wi-Fi.

### 4.1 Alternative: AltStore

`tools/build_release.sh` (run it with `--help`) builds an unsigned IPA plus the
source manifest to serve beside it; serving those files is your web server's
business. AltStore re-signs on install and has to reproduce the App Group (§3.2) —
suspect that first if the app installs but cannot log in.

### 4.2 A second build alongside the first

iOS keys apps on the bundle ID, so a second identity is a second app with its own
container, database and offline store; the installed one is untouched. One AltStore
source lists both, each with its own version history, from the same URL and the
same build command.

In `ios/Signing.local.xcconfig`:

```
IMMICH_BUNDLE_ID_PROD = me.example.mirrichdev
IMMICH_GROUP_ID       = group.me.example.mirrichdev
```

Separate the group as well as the bundle ID, or both apps share one cookie jar and
`UserDefaults` suite and overwrite each other's server URL — the working install is
what you were trying not to disturb. The cost is signing in once on the new app.

Then in `tools/altstore.env`, match the ID and name it:

```
ALTSTORE_BUNDLE_ID="me.example.mirrichdev"
ALTSTORE_APP_NAME="Mirrich Dev"
```

Leave `ALTSTORE_BASE_URL` alone and build as before; the first app's entry is
carried through untouched. `ALTSTORE_SOURCE_NAME` renames the source itself.
Both apps ship the same icon (it is compiled into the bundle — §8 to regenerate),
and the shared `immich://` scheme may open either build.

## 5. Keeping it installed, and TestFlight

A directly-installed build expires with its development profile — one year on a
paid account — and stops launching until you rebuild over a cable. TestFlight
trades that for a 90-day clock you can reset over the air, on your own devices and
anyone you invite. It needs no App Store submission.

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

The build number is a UTC timestamp, so it is always higher than the last with
nothing to bump by hand. For it to reach a signed bundle, `ios/Runner/Info.plist`
points its two version keys at `$(FLUTTER_BUILD_NAME)` and
`$(FLUTTER_BUILD_NUMBER)`, as Flutter's own template does; upstream ships literals
there and bumps them with fastlane, so expect a one-line conflict on those keys
and keep the fork's side. `pubspec.yaml` is never edited.

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

Then re-check the fork invariants in `mobile/FORK.md` §5 — in particular that
nothing on an automatic path calls `clearLocalData()` or navigates to `LoginRoute`,
or a token expiry off-grid will wipe your offline library.

## 7. Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Hundreds of missing files / undefined classes in Dart | Code generation never ran. `mise run //mobile:checkout`. |
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
| Flutter version errors | A system Flutter is shadowing mise's. `which flutter` should point inside `~/.local/share/mise`. |
| Old Immich icon after a build | iOS caches icons. Delete the app and reinstall. |
| Photos vanish offline | The mirror is unfinished or off. *Settings → Sync status → Offline library* → **Sync now**. |

## 8. Where the branding lives

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
