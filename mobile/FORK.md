# Mirrich: fork requirements and design

This repository is a fork of [Immich](https://github.com/immich-app/immich). Only the **mobile app** is modified: the
Flutter app in `mobile/` and the Rust core it ships (`native/`). The server, web and ML components track upstream
exactly, and the app works against an unmodified Immich server.

## 1. What this fork is

Upstream Immich is a client for a server: photo bytes are streamed on demand into an OS-purgeable cache, and a rejected
auth token sends you to the login screen and clears the synced database.

This fork is a **one-way mirror of the server onto the phone**. The server stays the source of truth and keeps doing
the clever things (search, faces, places). The phone keeps a durable copy of the part of the library the user selected,
up to all of it, and that copy opens with no network, indefinitely, whatever the session state.

### 1.1 Why a fork

Offline use is among the most requested features upstream (#4466, #7627, #9706, #5695, #4560), and maintainers have said
they are moving towards it (`bo0tzz` on #4466, `alextran1502` on #3279 and #12597). Two attempts stalled without a
design review: #29675 was closed by the LLM-contribution policy, and #26204 drew objections that this design addresses:
it shares `URLSessionManager.shared.session`, keeps its state in SQLite, and batches what the image path reads into one
write every few seconds.

So the diff is kept **rebasable and recognisable**: additive, in upstream's own idioms, and never replacing an upstream
feature (R5).

## 2. Requirements

### R1: what the user selected stays viewable offline

Stored bytes render with no network through outages, expired sessions, reboots and storage pressure. Files a selection
maintains leave the device only when the user says so: *Free up space*, or deleting offline copies on sign-out. Nothing
automatic removes them, and they never live where the OS may purge them.

**Spares are the only exception.** Files nothing selects (kept while browsing, saved by hand, or left by a changed
selection) are evicted least recently used first when the store needs room.

### R2: the app never forces a login and never destroys local data to recover from an error

With no network, an expired token or an unexpected server answer, the app opens into the library and reports the problem
passively (the app-bar badge and the offline copies screen). No automatic path may open the login screen, call
`AuthService.clearLocalData()` or call `AuthNotifier.logout()`. The only exception is a session that was never there (no
token or server URL stored).

Every path to the login screen, checked by `test/routing/login_paths_test.dart`, which fails when a call site that can
open the login screen, log out or clear local data appears or moves:

| Site | When |
| --- | --- |
| `auth_guard.dart` | no access token stored |
| `splash_screen.page.dart` | token, server URL or endpoint missing |
| `app_bar_dialog.dart` | the user pressed Sign out |
| `offline_sync.page.dart` | the user tapped the expired-session note; clears nothing |
| `change_password_form.dart` | first sign-in password change |

Sign-out keeps the stored files, and since they are named after their URLs they are valid again after signing back in.
The sign-out dialog offers deleting them as a separate choice, which also clears the selection
(`deleteAll(forgetSelection: true)`), or the next sign-in would download everything again. Neither choice records a
pause: queued downloads are cancelled with `stopDownloads()`.

### R3: server features keep working when the server is reachable

Inherited rather than built. People, places, memories and albums are synced locally and work offline; search and map
tiles need the server and degrade quietly (empty results, never a modal or a navigation). There is no global 401
interceptor; if upstream adds one, it must not log out or navigate.

### R4: downloading happens on the user's schedule

Nothing is stored until the user selects something. After that, keeping it current is automatic, and items that arrive
later follow the rule the user set.

### R5: nothing upstream does is taken away

The mirror is a third place bytes can live, beside the camera roll and the server. Backup, free up space, "On this
device", the camera-roll Download action and the merged timeline all keep working and keep their UI. The mirror never
writes to the photo library and needs no permission of its own. The tile's storage glyph is kept as is, with the
mirror's bar drawn under it.

## 3. How it works

### 3.1 Three places bytes can be

| Fact | Owned by | Removed by |
| --- | --- | --- |
| on the server | server sync | the user, on the server |
| in the camera roll | the OS photo library | the user, free up space, iOS offloading |
| kept offline | the mirror | only the mirror's own controls |

The third is separate because the camera roll cannot keep R1's promise: iOS may offload originals, and free up space
deletes them on purpose.

### 3.2 One store, written by two parties

Every file lives under `mirrich_blobs/pinned/` in Application Support (`filesDir` on Android), bucketed by a hash of its
name:

- the **reconciler** downloads what selections ask for, through the app's own HTTP client;
- the **native image path** (`OfflineStore.swift`, `OfflineStore.kt`) serves stored files before going to the network,
  and keeps whatever it fetched. So a photo looked at is a spare, and becomes library without a byte moving if a
  selection later wants it.

The native side never deletes; deciding what may go needs the selection, which lives in Dart. Every couple of seconds it
reports what it stored and served (`activity` on `mirrich/offline_store`), only to the app's own engine, marked in
`MainActivity` and `AppDelegate`: the background worker's engine registers the same channel, and its `listen` is
refused, or the reports would stop reaching the app until it restarted. Dart records stored files in `held` and stamps
`used_at` on served ones, which is what eviction orders by. Rows are written in batches every couple of seconds; the
in-memory index the screens and the queue read is `held` plus the rows not written yet, so a reload replays them, and a
reload and a write never interleave. All four records (files, `held`, the index, the native sets) change only through
`OfflineLedger`, so no path updates one and forgets another. Recording an arrival takes an `OfflineLedgerTicket`,
taken when the file is first noticed and before anything is awaited; a wipe makes every earlier ticket stale, so a
file noticed before a wipe is never recorded after it. A lost report costs nothing durable: the queue claims an
unrecorded file if a selection wants it, and the integrity pass sweeps it otherwise.

**File names are derived from the URL**, in one place: `native/crates/native_core/src/offline_name.rs`, which Dart
(`package:native_core`), Swift (`NativeCore.offlineName`) and Kotlin (`OfflineNaming`) all call, so the reconciler and
both image paths cannot disagree. A name is the decoded path after the last `api` segment, the `size`, and a token over
the rest of the query. The thumbhash cache buster is in the query, so an edit gives new names. Scheme, host and any
path before the API root are left out, so LAN and external endpoints share files even behind different subpaths; files
older builds stored under the subpath are renamed once at launch. The bucket a name goes in comes from the core too.
The names stored files already have are pinned by `native/crates/native_core/tests/fixtures/offline_names.tsv`, which
the Rust tests and `offline_paths_test.dart` (through the Dart binding) both check.

### 3.3 Selecting is separate from storing

The selection (`SettingsKey.offlinePolicy`, see `offline_policy.model.dart`) is a library rung plus per-album rungs and
exclusions. The library is everything the account can see: its own items, those of partners who share with it, and
those in albums shared with it, the same items upstream syncs to the phone. Excluding an album keeps its items out
however else they are selected. Rungs, lowest first: thumbnails, previews, full quality, full quality with videos. An item is kept at the
most generous rung naming it, and an exclusion beats everything. Deselecting never deletes: what is there becomes a
spare.

*Save offline* on selected items is an **errand** (`wanted.pinned`): it fetches them at the top rung now, ahead of
everything else. What no selection covers is kept as a spare (`on_demand`).

**What the camera roll holds is not fetched again.** For an item whose unedited original the camera roll holds (a
checksum match, as in upstream's merged view), the mirror stores the thumbnail and preview but not the full-size file,
and any full-size copy it has is a spare. An errand overrides this.

### 3.4 The fork's database

`wanted`, `held`, `failures` and `meta` live in `mirrich_offline.sqlite` beside the files, **attached** to upstream's
connection as the `offline` schema on every pooled connection (`ImmichSqliteOpenFactory`). One connection lets a single
statement join the selection with upstream's assets, albums and camera roll; a separate file keeps the fork out of
upstream's `schemaVersion`, its migration tests and `Drift.reset()`. The file is set to WAL on every launch, since an
ATTACH does not inherit the journal mode.

`ensureSchema` brings the file to `schemaVersion`, kept in its `user_version`: one step per version, run once in the
transaction that bumps it. Step 1 probes and upgrades every file from before versions. To change the schema, append a
step; never edit one a release has run. The mirror
never stops the app from opening: a file SQLite reports as corrupt is set aside (`.corrupt`) before it is attached and a
fresh one started, which the next pass refills from the selection (items saved by hand and not selected are forgotten),
and a schema step that fails is logged. Opening reads only the schema, so a query that finds damage further in leaves
`.unreadable` beside the file, and the next launch sets it aside once no other engine has it open. Nothing
upstream can answer (asset type, Live Photo, edited, camera-roll copy) is copied onto a row; it is joined live.

`wanted` is a projection: `derive` re-computes it from the selection in one statement (`OfflinePolicy.resolve` in SQL;
a test checks the two agree for every combination). Whether a held file is a spare is one SQL predicate
(`_unselectedOver`), shared by the storage figures, the cleanup sheet and eviction, so what a screen quotes and what a
deletion takes are the same set.

### 3.5 The passes

`OfflineSyncService` runs one pass at a time:

- **check** does nothing unless something moved: a write to upstream's asset or album tables, a camera-roll write
  (hashing decides whether the camera roll holds an item), a selection change, or work still queued. Writes are watched
  as drift table updates and debounced; after every foreground remote sync, `afterRemoteSync` reconciles too (the first
  one after launch waits ten seconds, leaving the timeline's first query alone).
- **sync** re-derives, walks the wanted list and queues what is missing, up to a budget. It never deletes.
- **reclaim**, the integrity pass, walks the whole store on its own isolate weekly (sooner after a deferred run or a
  change of video form), deletes files nothing accounts for and rewrites `held`. A file is accounted for while its
  asset exists and is not locked (trashed counts, since it can be restored), unless it is a thumbnail or preview of an
  older version; faces always are. Files of an item moved to the locked folder do not wait for it: every pass deletes
  them, since being locked is something upstream says rather than something missing. It defers if upstream's tables move during the walk, and refuses to delete more
  than a set share of the store unprompted, since a half-synced database looks like a library emptied on the server.
  The offline screen then offers to delete them, and only the user's confirmation lifts the cap.

**Downloading** (`offline_queue.dart`) runs in two lanes. Each file is downloaded natively (`OfflineDownloader.kt`,
`OfflineDownloader` in `OfflineStore.swift`) through upstream's HTTP client, which already carries the session; no file
bytes pass through Dart, which on Android crashed upstream's `ok_http` bridge. `background_downloader` is not used: its
WorkManager worker or background-session task per file, and the six-transfer queue it shares with uploads, made
thousands of small files crawl.

- **Light** (thumbnails, previews): many small, latency-bound files. How many run at once is adaptive
  (`offline_concurrency.dart`): six to start, one more after each round of quick successes, halved on a network
  failure and cut by a quarter when a file takes over 10 s, between 2 and 16. A home server gets what it can take
  rather than a fixed burst. Never resumed: refetching is cheaper.
- **Heavy** (originals, videos): three at a time, bandwidth-bound. A stopped download resumes where it stopped
  (`Range`/`If-Range` on Android, resume data on iOS), dropped connections are retried natively, and the finished file
  is checked against the server's SHA-1 when that describes its bytes (an unedited upload; not an edit, and not an
  external library, whose checksum hashes the path). A mismatch counts against the file like a server error.

Every file is staged under `mirrich_blobs/partial/`, flushed to disk, checked against the length the server announced,
and renamed into `pinned/` in one step, so the store only ever holds complete files. Partial files older than a week are
dropped. A response is kept only when its type is an image (or a video, for the queue), `application/octet-stream`, or
not given: a captive portal or login page answered with 200 would otherwise be served ahead of the network for good. The
queue counts a wrong type as a network failure, so the file is tried again and never given up on. One transfer per
file: a second request joins the first, which is how a new Dart engine picks up what the last one left running.

**In the background**, Android keeps the process running while there is work: a user-initiated data transfer job on
Android 14+, a `dataSync` foreground service before (`OfflineTransferKeepAlive.kt`), with an ongoing notification. Both
can only start while the app is on screen, so Dart holds a 90 s lease, renewed while its queue has files; the queue then
simply carries on, both lanes. The user can stop it from the task manager, which cancels the downloads; nothing starts
again, nor is handed over, until the app is on screen. iOS cannot keep the app running: leaving it aborts the light
lane, keeps the heavy one, which runs in a background `URLSession` the system carries on even after the app is
terminated, and hands it up to ten full-size files. Those finish at the system's pace; files it completes while the app
is closed are put in place natively and claimed by the next pass.

**What is left** is shown beside the storage used: "estimated 4.2 GiB left", or without "estimated" once every
remaining byte is a size the server reported. It costs no query of its own over the library: each pass looks up the
EXIF sizes of the full-size files it queues (at most one pass's worth, each item once), originals not queued yet count
at the average of the known ones, and thumbnails, previews and the playback transcodes' shrink are learned from files as
they arrive. So it is exact once what is left fits in one pass, unless thumbnails, previews, edits or playback videos are
among it.

The order: errands, then the most recent decision, then within it thumbnails and previews before full-size files, then
the newest photo. Each lane keeps that order but takes its own next file, so a busy one never leaves the other idle.
The mirror gives way while the backup is actually uploading, for at most `_maxYield`, and waits for Wi-Fi when *Wi-Fi
only* is set. Failures the server gives about a file are retried three times. After a network or
session failure the queue backs off and lets the file go; the next pass queues it again if it is still wanted, since
only a pass knows that. A thumbnail or preview that keeps failing while other files arrive counts against itself like a
server error. Stalled downloads time out in the native client.

**Upstream readiness.** Upstream's tables are only trusted once a foreground remote sync has finished since they were
last wiped (`upstream_complete` in `meta`). `SyncStreamRepository.reset()`, which sign-out and a server-requested reset
both run, clears the mark before wiping; the server then sends assets before albums, so a sync cut short looks like a
library whose albums were deleted. Resets are counted in `meta`, and a sync sets the mark only if none came after it
started, so a reset landing between a sync's end and its write cannot pass for a complete library. Until the mark is
back, the derive only adds and raises decisions, no album leaves the selection, no decision is forgotten for a missing asset, an item missing from upstream is not a spare (so eviction cannot take
it), and the integrity pass waits. The mark is always read *after* the upstream rows it vouches for: a reset clears it
before wiping, so a mark still set means the rows were read whole, and a reset landing mid-pass cannot pass for deletions
on the server. Files from before the mark start with it set when upstream already has assets. Clearing it never fails
the reset, so the mirror cannot stop a sign-out.

This ordering is enforced rather than remembered. `OfflineFlagsRepository.vouch(reads)` is the only way to read the
mark: it runs the upstream reads it is given, then reads the mark, and hands their result over (`ifComplete`) only when
the mark was set. Every decision that treats something missing upstream as gone (vanished albums, forgotten decisions,
the integrity pass's whole walk) takes its input from there. The SQL that needs the mark reads it in the same statement
or transaction, after the rows. Likewise, the service methods that read the mirror's state and then change it take a
`_Pass`, which only the pass lock hands out, so calling one outside the lock does not compile. Stopping downloads and
pausing do not take the lock, so neither waits for a pass: a pass does not queue what it found if the queue was cleared
since it was asked for, even while it waited for the lock. Deleting every copy does take it, and interrupts every pass
running or waiting, which give it up at their next page.

### 3.6 Space

One storage limit, plus 1 GB always left free on the device. Over it, spares are evicted least recently used first, whole
items at a time, never an item with a pending errand. If only the library is left, downloading stops and the screen
says the store is full. *Free up space* on the offline screen is the only way to delete library files, and says what
each item is left with before doing it.

### 3.7 Session handling (R2)

`AuthGuard` and the splash screen report through `sessionIssueProvider` instead of navigating: *offline* (no network),
*unreachable*, *expired* (a 401 while online), or *failed* (the session could not be set up on the device). A failed
remote sync reports unreachable only if the server misses a ping too, a successful one clears it, and an expiry is not
overwritten by a later unreachable.
Only *expired* shows on the app-bar badge, since it is the one the user can act on. A token rejected at launch still
signs in the cached user (`resumeAuthInfo`), so the library and owner-only actions keep working.
`api.service.dart` re-seeds the auth cookie from the stored token on every launch.

### 3.8 The UI

- **Offline copies** screen (`offline_sync.page.dart`), from Settings and the profile dialog: downloading status and
  switches, the selection, and storage by kind (library and spares), with the limit.
- **Albums** screen and an "Available offline" row on each album's options page.
- **Save offline / Remove offline** beside upstream's Download in the bottom sheets.
- **App-bar button** beside the backup button: progress, and the expired-session badge.
- **Tile bar** under upstream's cloud glyph: thumbnail, preview and full copy, each empty, waiting, white (maintained)
  or amber (spare).
- A line on upstream's free up space screen saying what deleting local originals costs offline.

Fork strings are English only, to keep out of upstream's i18n files.

## 4. Map of the change

New files cannot conflict and are not listed; they sit where upstream would put them. Modified upstream files, each
hook tagged `// immich-sync fork`:

| Path | Hook |
| --- | --- |
| `ios/Runner/Images/RemoteImagesImpl.swift`, `android/.../images/RemoteImagesImpl.kt` | Read the store first; keep what was fetched |
| `ios/Runner/Core/URLSessionManager.swift` | URLCache down to 64 MB, since the store holds image bytes |
| `ios/Runner/Core/NetworkApiImpl.swift` | Keep an existing auth-type cookie when re-seeding |
| `ios/Runner/AppDelegate.swift`, `android/.../MainActivity.kt` | Prepare the store and its channel; mark the app's own engine |
| `ios/Runner/AppDelegate.swift` | Reconnect to the offline downloads' background session at launch |
| `android/app/src/main/AndroidManifest.xml` | The keep-alive job and service, and `RUN_USER_INITIATED_JOBS` |
| `lib/data/data_controller.dart`, `lib/data/db/main/database.dart` | Attach the fork's database on every connection |
| `lib/providers/background_sync.provider.dart` | After each remote sync: session state and a reconcile |
| `lib/infrastructure/repositories/sync_stream.repository.dart` | `reset()` marks upstream incomplete before wiping |
| `lib/pages/common/splash_screen.page.dart`, `lib/routing/auth_guard.dart`, `lib/routing/router.dart` | Report session problems instead of logging out (R2); routes |
| `lib/providers/auth.provider.dart` | Keep the cached user signed in when the token is rejected at launch (R2) |
| `lib/services/api.service.dart` | Re-seed the auth cookie from the stored token |
| `lib/utils/image_url_builder.dart`, `lib/presentation/widgets/images/*` | One URL for the original, so a stored one is served; whether it loads stays upstream's setting |
| `lib/presentation/widgets/asset_viewer/video_viewer.widget.dart` | Play stored videos from disk |
| `lib/repositories/asset_media.repository.dart` | Share a stored copy instead of downloading |
| `lib/presentation/widgets/images/thumbnail_tile.widget.dart` | The tile bar under upstream's glyph |
| `lib/presentation/widgets/bottom_sheet/*`, `lib/utils/action_button.utils.dart` | Save offline beside Download |
| `lib/pages/common/settings.page.dart`, `lib/widgets/common/app_bar_dialog/app_bar_dialog.dart`, `lib/widgets/common/immich_sliver_app_bar.dart`, `lib/presentation/pages/album_options.page.dart` | Entries for the offline screens; sign-out dialog |
| `lib/widgets/settings/free_up_space_settings.dart`, `lib/infrastructure/repositories/local_asset.repository.dart` | What free up space costs offline |
| `lib/presentation/pages/asset_troubleshoot.page.dart` | The mirror's view of an asset, behind upstream's advanced flag |
| `lib/presentation/pages/edit/edit.page.dart` | Show the server's reason when an edit fails |
| `lib/domain/models/settings_key.dart`, `lib/domain/models/config/app_config.dart` | Four settings |
| `ios/Runner/Core/NativeCore.swift`, `ios/Runner/Runner-Bridging-Header.h` | The core's naming functions |
| `native/crates/native_core/{Cargo.toml,src/lib.rs}`, `native/crates/native_core_ffi/{build.rs,src/lib.rs}`, `native/native_core/lib/native_core.dart` | The `offline_name` feature and its C, JNI and Dart entry points |

### 4.1 Identity

The app is **Mirrich**, with its own name, icon, splash and application id, so it can sit beside upstream's app.

- `tools/make_icon.py` generates all artwork (`--brand` writes every branded asset in place); never edit the PNGs by
  hand. The splash assets from `flutter_native_splash` are committed.
- `BrandTranslationLoader` renames the app in upstream's translated strings as they load. Strings whose "Immich" is the
  server are listed in `kServerNamingKeys`.
- The app id comes from `android/Identity.properties` and `ios/Signing.xcconfig`, each with a gitignored local override.
  Upstream's id is the committed default. iOS background-task ids are `$(PRODUCT_BUNDLE_IDENTIFIER).background.*`.
- `Info.plist` has a literal display name and takes its version from the build.
- `tools/build_release.sh` (iOS: TestFlight or AltStore) and `tools/build_android.sh` build releases; see `BUILDING.md`.

## 5. Rules for future changes

1. New behaviour goes in a new file, placed where upstream would put it. Upstream files get a tagged hook, never fork
   logic, and never a deletion.
2. Never add a drift table or bump `schemaVersion`; the fork's tables live in its own attached file.
3. Never modify `mobile/pigeon/`. Code outside `mobile/` is allowed only for the app: the Rust core in `native/` may
   gain fork features, used by nothing but the app, and `README.md` may change. Nothing may need a change on the
   server: the fork must keep working against a stock Immich server.
4. Never remove or repoint an upstream feature (R5).
5. Keep the fork's branding on a rebase conflict; regenerate artwork rather than merging PNGs.

### Rebasing

The fork is two commits (identity, mirror) on an upstream release tag. After a rebase, check:

- `grep -rn "immich-sync fork" mobile/` finds every hook, and `login_paths_test.dart` passes, so no automatic path
  reaches `clearLocalData` or `LoginRoute` (R2).
- `lib/main.dart`, `MainActivity.kt` and `localization.service.dart` are **CRLF** upstream; keep them so.
- `OfflineStore.swift` is still in the Runner target's sources in `project.pbxproj`.
- `getThumbnailUrlForRemoteId` and the video viewer still build the URLs the store is named by.
- `flutter test` passes, and in `native/`, `cargo test --workspace` and `mise run lint`. The naming fixture's names
  must not change, or every stored file is fetched again.
- `NativeCore.swift` and the bridging header still declare the `native_core_offline_*` functions.
- `ensureSchema` refuses to start if upstream gains a table named `wanted`, `held`, `failures` or `meta`.

## 6. Known limitations

- **The store is large by design.** Full quality is roughly ten times previews, and videos multiply it again. The
  previews rung, or a storage limit, keeps it in check.
- **Free space is read, not reserved**, before each pass and eviction.
- **A video is stored whole or not at all**; the server offers no smaller playable form.
- **Spares are only reclaimed under pressure** or by *Free up space*.
- **A camera-roll copy iOS has offloaded is trusted anyway.** Upstream's image path does the same; *Save offline* fetches
  the app's own copy regardless.
- **Changing "load original videos" re-downloads every video**, since it changes the URL the player asks for.
- **A server-side deletion's bytes stay until the next integrity pass**, which is weekly.
- **A trashed photo is selected by nothing**, so its copies become spares: the integrity pass keeps them while it can be
  restored, but eviction may take them under pressure. Restoring it selects it again, and anything evicted is fetched
  again.
- **On iOS, thumbnails and previews need the app open.** Leaving it stops them; they resume on return. Up to ten
  originals and videos carry on in the background session, at the system's pace.
- **On Android, a notification shows whenever the mirror has files to download**, even in the foreground: the job or
  service that keeps it running in the background can only be started while the app is on screen.
- **A file the server cannot produce** is tried three times, then counted on the summary with a retry button.
- **A page answered in place of a file costs a download on every pass** while whatever sends it is in the way, and on
  iOS the whole body arrives before its type is checked: a background download cannot be looked at sooner.
- **A reset the server asks for during a sync leaves upstream's tables untrusted until the following sync**, even though
  that sync streams everything again: it cannot tell that reset from a sign-out. Until then nothing is lowered or
  forgotten.
- **A corrupt offline database is set aside only at a launch where nothing else has it open.** An engine that opens it
  between that check and the move keeps writing to the moved file until it restarts.
- **Fork UI strings are English only.**
- **An image's `/original` file is named `.mp4`**, because of how playable URLs are recognised. Harmless, and fixing it
  would rename and re-download every stored original.
