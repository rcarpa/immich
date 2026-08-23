# immich-sync — fork requirements and design

This repository is a fork of [Immich](https://github.com/immich-app/immich). Only
the **mobile app** (`mobile/`, iOS and Android) is modified; the server, web and ML
components are untouched and track upstream exactly.

**Read this file before making changes.** It defines what the fork is for. A
change that violates a requirement below is a bug in this fork, no matter how
reasonable it looks in isolation.

---

## 1. What this fork is

**The model in one line:** the server is the source of truth; the phone holds the
part of it the user asked for, and that part keeps working when nothing else
does.

Upstream Immich is a **client for a server**. It assumes the server is normally
reachable: photo bytes are streamed on demand and kept only in an OS-purgeable
HTTP cache, and a rejected auth token sends you to the login screen and deletes
the synced database.

This fork is a **one-way mirror of the server onto the phone**. The server is
where photos live and where the clever things (search, faces, places) happen. The
phone holds a durable copy of a chosen part of the library — up to and including
all of it — that renders with no network at all, forever, regardless of session
state.

The problem being solved, concretely: *"I want to show someone a photo while I'm
off-grid, and the app is either disconnected or never had that photo."*

### 1.1 Why this is a fork, and what upstream actually thinks

Checked against the tracker before the design was built, because the answer shapes
the code. The short version: **this feature is wanted upstream and has no design
there.** It is not a rejected idea.

**It is among the most-requested things missing from the app.**

| # | Ask | Votes |
| --- | --- | --- |
| 4466 | Use the mobile app offline | **192** |
| 7627 | Make an album available offline | **189** |
| 9706 | Improved caching on mobile | 25 |
| 5695 | Sync a time range or all pictures to mobile | 16 |
| 4560 | Limit the iOS cache size | 15 |

with #26914, #27547, #28496, #735 and #23949 all triaged into those three. The
community's own stated preference in #7627 is app storage, *not* the photo library —
the Spotify / Nextcloud "available offline" model. #28496 names the exact collision
this fork has to solve: *"after deleting local originals via Free Up Space, the app
shows only blurry placeholders when disconnected."*

**What upstream has actually said.** Not "no":

- `bo0tzz` on #4466: *"Full offline support is complex and pretty hard, but we're
  always moving towards it."* What is refused there is a **standalone, serverless**
  app — to which the answer is a flat *"No."* This fork does not want that either:
  the server stays the source of truth.
- `alextran1502` on #3279: *"I don't think this should be set as a setting. It should
  be handled by default by fixing, and implementing better support for offline
  cases."* That is why R2 is unconditional here rather than a flag.
- `alextran1502` on #12597: *"The app will have to sync the complete list of albums
  regardless so it can work offline."*
- `NicholasFlamy` on #7627 expects offline albums to arrive as part of a backup
  overhaul, complementing automatic removal of backed-up photos — the same pairing
  §3.6 builds.
- `bo0tzz` on #28496 distinguishes an app-local offline cache from touching the
  device gallery. That distinction is what this fork is built on.

**Why it is still a fork.** Two attempts have stalled, neither on merit. PR #29675
was auto-closed by a bot for the LLM-contribution policy and never assessed. PR
#26204 ("smart caching") drew concrete objections from `mertalev` — don't add
URLSession instances, share the existing session and cache; don't turn *"every read
into a write"* — plus `shenlong-tanwen`'s "use SQLite, not a properties file", and
then went quiet awaiting a network-stack refactor. **This design satisfies all
three**: it shares `URLSessionManager.shared.session`, keeps its state in SQLite,
and batches what the image path read into one write every few seconds, so reading
a blob is never a write of its own.

So the honest position is: the feature belongs upstream, this is a plausible shape
for it, and the fork exists because getting it in requires maintainer attention that
is not currently available for it. That argues for keeping the diff *rebasable and
recognisable* rather than for diverging.

**Three consequences for this codebase:**

1. **Additive by default.** Nothing upstream does is removed (R5). Where the mirror
   and an upstream feature meet, they compose.
2. **Upstream's idioms are followed where they exist.** Reconciling two stores means
   detect → present → let the user choose, which is what `alextran1502` describes on
   #4282 and what the cleanup note in §3.6 does.
3. **Upstream's download path is not reused, and not replaced.** It ends in
   `FileMediaRepository.save*`, which writes to the photo library — a different
   promise, so it becomes a second action rather than a changed one (§3.6).

**How upstream tracks "downloaded", and why the mirror cannot.** There is no
downloaded flag. Upstream joins remote to local **by checksum**
(`merged_asset.drift`); an asset counts as held when a camera-roll asset with a
matching hash exists. That is exactly right for the camera roll and cannot describe
app storage, which holds three variants per asset under names derived from URLs. The
two answers coexist rather than compete (§3.1.1).

## 2. Requirements

These are ordered by importance. R1 and R2 are the reason the fork exists.

### R1 — What the user selected is viewable offline, indefinitely

Once an asset's bytes are stored, they render with zero network access and keep
doing so through flat network, expired sessions, reboots and OS storage pressure
alike.

Library bytes leave the device for exactly two reasons, both of them decisions:

1. the user said this photo is no longer wanted — by a button, or by a bulk
   action that included it;
2. the user signed out and chose to delete the downloads, which is the one
   control that abandons the mirror rather than editing it (see R2).

Nothing opportunistic, automatic or defensive may remove what a selection
maintains. Specifically **not** acceptable as a store: anything the OS may purge
under storage pressure (`Caches/`, `tmp/`), or anything whose size cap evicts the
library.

**Spares are the one exception, and only spares.** What browsing kept, copies
saved by hand, and copies a changed selection left behind are evicted least
recently used first when the store runs out of room (§3.4.1). Nothing selected
them, so nothing promised to keep them; the alternative — a second, separately
capped cache beside the store — was two limits for one disk.

### R2 — The app never forces a login, and never destroys local data to recover from an error

If the network is down, or the token expired, or the server returns anything
unexpected, the app opens straight into the library. The *only* permitted
reaction is a passive note on the offline copies screen.

Never, on any automatic path:

- redirect to the login screen
- call `AuthService.clearLocalData()` (it drops every synced remote asset)
- call `AuthNotifier.logout()`

Those remain available for **explicit user action only** (the logout button).

The single exception is a genuinely absent session — no access token or no server
URL in the store at all, meaning the user has never signed in. That still goes to
the login screen, because there is nothing to show.

**Every path to the login screen, and why each is safe** (re-check this list after
a rebase; it is the requirement's only real proof):

| Site | When | Safe because |
| --- | --- | --- |
| `auth_guard.dart` | no access token in the store | never signed in, or signed out on purpose |
| `splash_screen.page.dart` | token, server URL or endpoint missing | the same absent-session case |
| `app_bar_dialog.dart` | the user pressed Sign out | explicit, and confirmed |
| `offline_sync.page.dart` | the user pressed the expired-session note | explicit, and clears nothing |
| `change_password_form.dart` | the user changed the password the server asked them to change | explicit; only reachable from the first sign-in, before anything is stored |

There are five, and each is an absent session or an explicit choice. A rejected
token reaches none of them by itself: the guard reports it and returns, and the
splash screen's error path reports it and carries on into what is stored. The
fourth is that report becoming a control — the screen said "sign in to resume"
while the only route to the login screen was *Sign out*, which is the opposite of
what the user wants. It pushes the login screen and nothing else: the token, the
database and the stored files all stay, and the saved server address is what the
form signs in against.

Only the last one clears anything, and `logout()` is the only caller of
`clearLocalData()` on any path. Note what it does and does not do: it resets the
synced database, the token and the current user, so the timeline is empty until
the next sign-in — but it does **not** touch the stored files, and since those are
named after the URLs they came from, signing back in finds every one of them
still valid. Nothing is re-downloaded. The confirmation dialog says so, and
offers erasing them as a separate, explicit choice, because the screen that
manages them sits behind the auth guard and is unreachable once signed out.

That second choice takes the **selection** with the bytes, and has to: the
selection is a settings value and the decisions derived from it are in this fork's own
schema, and `clearLocalData()` touches neither — nor does `Drift.reset()`, which empties
`main` and is exactly why the fork's tables are attached rather than merged (§3.2.1). Deleting the files alone
leaves the instruction to fetch them standing, so the next sign-in re-derives the
whole selection and downloads the library again — which is the opposite of what
the button says. `deleteAll(forgetSelection: true)` is the only path that clears
both, and the dialog states it.

Neither choice records a **pause**. Downloading does stop — a revoked token would
fail every queued task — but through `stopDownloads()`, which hands the queue
back without writing the persisted flag. *Paused* is a state the offline screen
presents as the user's own decision and it survives restarts, so setting it here
would greet the next sign-in with downloading silently off and nothing able to
explain why.

### R3 — Server-backed features keep working when the server is reachable

Mostly **inherited, not built** — this requirement is something to avoid
breaking, not something to implement. No "online mode" switch is needed or
wanted: the features below already gate themselves on whether the server
answers, so a mode flag would only add a way to be wrong.

Upstream syncs more than asset rows into the local database, so most of what
looks like server intelligence is already local. Face detection and clustering
run server-side but arrive as `asset_face_entity` / `person_entity`, so browsing
by person keeps working off-grid.

| Feature | Source | Offline |
| --- | --- | --- |
| People / faces browsing | `PeopleRepository` | works |
| Places | drift, from synced EXIF | works |
| Memories | `allMemoriesProvider` | works |
| Albums, favorites, archive, trash | drift | works |
| Smart / contextual search | server API | empty result |
| Search suggestions | server API | empty list |
| Map tiles, activity, comments | server | blank / no-op |

Only CLIP-embedding search genuinely cannot be local — the embeddings and the
model live on the server.

What must stay true: these degrade **quietly**, never with a modal, a toast or a
forced navigation. Today they do, and it is worth re-checking after a rebase:

- `SearchService.search` catches everything and returns `null`;
  `PaginatedSearchNotifier` treats `null` as "leave state alone".
- `getSearchSuggestions` catches and returns `[]`.
- There is no global 401 interceptor in `api.service.dart`. If upstream ever adds
  one, it must not log out or navigate — see R2.

### R4 — Downloading and re-login happen on the user's schedule

Nothing is stored until the user says so, including after the first login. Once
they have said so, keeping those items downloaded is automatic — that is what they
asked for — and items that arrive later are governed by a rule they set, never by
one assumed on their behalf. With no rule set, nothing is decided for them and the
bulk action is inert.

Session problems are surfaced passively, in one place (§3.5). Nothing nags,
blocks, or interrupts.

### R5 — Nothing upstream does is taken away

The mirror is a third place bytes can live, added beside the two upstream already
manages. Everything upstream does keeps working and keeps its UI: camera-roll
backup, "free up space", the local-albums card, the background worker, the
camera-roll download, the merged timeline.

This is a requirement, not a courtesy, and it points the same way as upstream. The
lead maintainer, asked on discussion #12597 whether "On this device" would list all
device folders like Google Photos, answered *"Yes, it will be."* Device-local
browsing is expanding there; a fork that deleted it would be diverging from the
thing it wants to keep rebasing onto.

So the mirror never writes to the photo library, never holds a camera-roll-only
asset, and never asks for a permission of its own. Where it and an upstream feature
touch the same bytes, they are made to compose (§3.1.1, §3.6) rather than to
replace one another. There is exactly one upstream UI element the mirror
extends — the storage badge, which answers "where are the bytes" and cannot also
answer "what would survive losing the network". Upstream's own glyph is kept
verbatim and a meter is drawn under it (§3.6), so the fork's diff there is an
addition rather than a replacement, and it stays behind upstream's own setting for
it.

## 3. How it works

### 3.1 What upstream already gives us

Upstream syncs all asset **metadata** into a local drift (SQLite) database:
assets, EXIF, albums, people, memories, stacks. The timeline, albums and people
views are built from that database, so they already work with no server. This
fork does not touch any of it.

What upstream does not keep is the **pixels**. That is the entire gap this fork
closes.

### 3.1.1 Three places bytes can be

Upstream models one axis: an asset is in the camera roll, on the server, or both
(`AssetState.local / .remote / .merged`, matched by checksum). One icon can carry
that. The mirror adds a third place, so the model has to grow to three independent
facts that are never conflated:

| Fact | Owned by | Destroyed by |
| --- | --- | --- |
| on the server | server sync | the user, on the server |
| in the camera roll | iOS photo library | the user in Photos, free-up-space, iOS offloading |
| kept offline by Immich | the mirror | only the mirror's own controls |

The third exists because the second cannot make the promise R1 needs: with
"Optimise iPhone Storage" on, iOS replaces a camera-roll original with a
network-needing placeholder, and free-up-space is *designed* to delete those
copies. It is not a better version of the camera roll and does not replace it —
they answer different questions and both stay.

**The destination is deliberately not configurable.** Offering "download to camera
roll" versus "download to app storage" as one setting would be four lies in one
switch: only one of the two survives iOS offloading, only one is safe from
free-up-space, only one has a preview tier (so "preview quality" cannot exist for
the other), and only one avoids iCloud Photos re-uploading what the user
self-hosts. They are two features with two honest names, not two backends.

### 3.1.2 One region, one index

Every blob lives in `pinned/` — the name is historical — whoever wrote it: the
reconciler for what a selection wants, the native image path for whatever was
looked at. A file is library or spare by what the selections say about it
(`_unselectedOver`), never by where it sits, so a photo looked at and later
selected is already the library's without a byte moving.

Older builds kept what browsing fetched in a second region, `cache/`, trimmed by
the native side to a budget of its own. It is deleted at launch: nothing recorded
those files.

**The native side never deletes.** What may go is a question about the selection,
which only Dart's database can answer, so the native store writes, reads and
reports, and Dart does every deletion — *Free up space*, eviction, the integrity
pass. What it reports, every two seconds while anything happens, is the files the
image path stored, with their sizes, and the files it served (`activity` on
`mirrich/offline_store`). Dart writes the first down as `held` rows and stamps the
second's `used_at`, which is what eviction orders by. A report lost to the app
being killed costs nothing durable: an unrecorded file is claimed by the queue if a
selection wants it (`offlineAdopt`), and swept by the integrity pass if not.

**Reports go to the engine that asked for them.** The background worker runs an
engine of its own and registers the same channel, so the native side does not
report to whichever registered last: Dart's sync service calls `listen` when it
starts, and only that channel gets `activity`. Reporting to the last registration
sent every report after a background run to an engine that was not listening, and
then to one that no longer existed — files nothing recorded, counted against no
limit and evictable by nothing.

**A stored name is filed under a variant only if it is that variant's name.**
`held` keeps one row per asset and variant, so a file the image path stored is
recorded as the thumbnail, preview or original only when its name is exactly the
one `filesFor` gives that variant of that asset *now*. Anything else — a face, a
full-size rendition, a preview under a thumbhash an edit has replaced — gets a
row keyed by its own name, which makes it a spare of no asset: counted, evictable
and swept weekly, and never able to push out the row of a file the mirror wants. A
file of an asset the mirror may not store — in the locked folder, in the trash, the
hidden half of a Live Photo, or not yet delivered by the metadata sync — is deleted
when its report arrives. That is seconds after the image path wrote it, not
instantly, and if the app is killed in between, the integrity pass takes it.

**A count of files is filtered to what is wanted; a total of bytes is not.**
Progress is measured against what the decisions imply, so a file nothing wants is
not progress towards anything. Storage is what the device gave up, so that same
file counts against it. `heldTotals()` and `OfflineIndex` split it the same way, or
the figures move every time the index reloads.

### 3.2 Selecting and storing are separate

The design turns on one distinction: **selecting decides what the app maintains;
storage is what is on the phone.** Selecting more downloads. Selecting less only
stops maintaining. What a selection stops maintaining becomes a spare, and leaves
only by an explicit "free up space" or by eviction when the store runs out of room
(§3.4.1) — never because a row was tapped, which is what makes every row on the
screen safe to mistap.

The alternative — deleting on the way down — was rejected. It needs a confirmation,
a confirmation is the weakest guard there is, and the costs are wildly asymmetric:
selecting spends bandwidth you can pause, while deselecting would spend hours of
re-downloading and possibly the thing the library was kept for. The figure such a
confirmation needs also takes a pass over the library to compute, so the dialog
arrives after the finger has moved on.

**Three things select, resolved most-specific-first:**

1. an **excluded** album — never keep these, whatever else says. This is what makes
   "everything except Screenshots" expressible; a plain union could not;
2. otherwise the **most generous** of the whole-library setting and every
   **included** album. Quality is a ladder, none ⊂ thumbnails ⊂ previews ⊂ full
   quality ⊂ full quality + videos, so combining is a maximum;
3. **items fetched on demand** are not a selection at all — see below.

#### One ladder, five rungs, and videos on top

Quality is deliberately **one dimension**. "Videos as well" as a second axis — a
checkbox beside the rung — would be a setting whose meaning depends on the setting
next to it, and it would have to be carried, explained and stored twice on every
row, every album, every figure and every predicate. So it is a rung instead:

| Rung | Thumbnail | Preview | Photo's original | Video's playable file |
| --- | --- | --- | --- | --- |
| Not selected | — | — | — | — |
| Thumbnails | ✓ | — | — | — |
| Previews | ✓ | ✓ | — | — |
| Full quality | ✓ | ✓ | ✓ | — |
| Full quality + videos | ✓ | ✓ | ✓ | ✓ |

**Thumbnails** is for a library too large to mirror any other way: a few kilobytes an
item keeps the whole timeline browsable off-grid. The items are **available** — they
draw in the grid and open to that same small picture — in the same sense a video's
still is: it is what the rung asked for. So `OfflineAvailability` gained a
`thumbnail` value below `preview`, and an item counts as complete for its album's
progress once it reaches what *its* rung asks for (`OfflineQuality.availableAt`):
the thumbnail here, the preview everywhere above, as before. A preview held for an
item at this rung is a spare.

The rung went in under Previews after the others had shipped, and `wanted.quality`
stores the rung as a number compared with `MAX` and `>=`, so every code above it moved
up by one. An installed database is carried across once, in `ensureSchema`, under the
`rungs_renumbered` key in `meta` — not left to the next re-derivation, because the
integrity pass may read `wanted` first, and to it an old preview row read as a
thumbnail row has a spare preview, which it deletes.

Videos sit at the top because a video is stored whole or not at all. There is no
preview tier for one — the server produces a playback file and nothing smaller —
so it is the only thing on the screen that can multiply the size of the store,
often a hundred times its own preview. Wanting a library of previews is almost
never wanting a library of videos, and the phone that mirrors a library is
usually the device with the least room.

Below the top rung a video keeps its thumbnail and preview like everything else,
which is its **still**: it appears in the grid, it opens off-grid, and it plays
when there is a network — exactly what the previews rung promises for a photo.
That is why `OfflineAvailability` has four values and none of them names a media
type: availability describes what an asset can show, and a still is a real answer
for a video just as a preview is for a photo.

The rungs are the user's vocabulary; `keepsOriginal` and `videoTier` are how the
reconciler reads one. That indirection is the extension point: if the server ever
produces a smaller video, it becomes a value of `OfflineVideoTier` and a rung
that maps to it, and `filesFor` gains a case. Nothing else learns a second axis.

Album states borrow upstream's own vocabulary (`BackupSelection.selected / none /
excluded`), which users have already met on local albums.

A user-sortable precedence list was considered and rejected. Order is load-bearing
but invisible: it changes nothing for items matching one rule, right up until the day
it silently decides one, and then "why is this photo only a preview?" can only be
answered by re-running the evaluation in your head. "Most generous, minus exclusions"
needs no evaluation to predict.

#### What a downgrade does

A step down the ladder is the case worth stating, because nothing is lost. The
originals and playable files stay on disk and those items still open — and play —
at full resolution off-grid; they merely stop being maintained. So a downgrade is
purely forward-looking: stop fetching originals or videos for new items, stop
replacing missing ones. What is already there is a bonus to cash in for space
whenever you like.

That is also why reclaimability is decided **per variant, not per asset**: an item
selected at preview quality still needs its thumbnail and preview, and only its
original has stopped being selected; a library dropped from videos to full quality
makes exactly the playable files reclaimable and nothing else. One SQL predicate
expresses it, shared by the figure on the button and the deletion behind it so the
two cannot disagree.

#### Fetched on demand is a cache, not a selection

"Save offline" on a selection is an errand — "grab these before I board" — and
the copies behave as a cache rather than as a standing choice: they keep working
offline until they are taken back.

**They are saved as spares**, which is what the action says before and while it
does it — the button reads `Save offline as spares`, and the toast that follows
`Downloading 3 copies, saved as spares`. Nothing maintains them: no setting
lists them, nothing re-downloads them if they go, and a cleanup or eviction can
take them like any other spare (§3.4.1). Saying so at the moment of saving is what stops the storage
screen looking wrong later — the copies land in the spares column, not in the
library — and a removal that includes some names them before it runs, since
nothing else on screen ever would.

Its inverse is the same button. While anything selected is missing it reads
**Save offline**; once every selected item is here it reads **Remove offline**,
which returns those rows to what the *selection* says and then offers to free
what that leaves behind. Releasing before quoting is what makes the figure real
— an original fetched on top of a previews-only album is only reclaimable once
the row stops asking for it — and it is what stops a removal the policy would
undo on the next pass. A button that vanished the moment it succeeded left no
way back, and no way to tell "done" from "not offered".

None of this is a per-item pin: what the errand added is undone by the same
gesture, and what a selection maintains is still only changed by the selection.

A standing per-item pin was considered and rejected for now. It would be a fourth
kind of selection with no page behind it, so nobody could review or audit it, and
"14 individually chosen items" in a list of standing selections is a category error:
switching it off is a hidden bulk delete and switching it on is meaningless. The
`on_demand` column exists so that feature can be added later by changing how reclaim
treats the flag — not by changing the schema.

**Being reclaimable and being urgent are different questions**, which is why the
errand's place in the queue is a mark of its own (`wanted.pinned`, §3.3) rather than
a reading of `on_demand`. That column is false whenever a selection also covers the
item — marking it a cache would make every file it has reclaimable — and that is
precisely the case where "get me these now" still has to jump the queue.

**And the errand's appetite is not written onto the row either.** `wanted.quality` means
what the *selection* maintains, and that is what `_unselectedOver` reads to decide
whether a held file is a spare. Recording the errand's own top rung there — the obvious
way to make it fetch the whole item — makes a hand-saved copy indistinguishable from
library: a phone kept at previews reports full-size copies as its persistent library,
they land in the band that is locked until every spare above it is going, and no sequence
of taps can free them. So the row keeps the selection's rung (or `kOfflineErrandQuality`
when nothing selects the item at all, where `on_demand` already makes every file a
spare), and the wider fetch comes from the mark: `filesFor` substitutes the top rung for
a marked item, and `barOf` shows its sections as wanted. One constant, three readers, no column
doing two jobs.

#### `wanted` is a projection, and re-deriving it is one statement

`wanted` holds one row per selected asset and is *derived*: the selection plus the
albums decide it, and nothing about a policy change reaches the filesystem. On-demand
rows survive a re-derivation, being a cache rather than a stale projection — nothing on
the settings screen ever asked for them, so no change to the settings may take them
away.

The whole of it is re-derived at once, every time, by a single `INSERT … SELECT` against
a temporary table of album rungs (`OfflineFlagsRepository.derive`). That is the load-
bearing fact this section used to be full of exceptions to. Because the selection and the
assets are in one database now, resolving every item costs one grouped scan, and working
out *which* albums a change touched costs more than acting on all of them.

So there is no scope to lose, no generation counter to decide which pass owns one, no
record of work handed back by a derivation that failed, no remembered album sizes to
detect a changed album, no reverse walk for an album that shrank, and no watermark. Each
of those existed to avoid a derivation that cost a page-by-page walk of the library, and
each was also a way for a change to be missed: two quick taps on different albums, an
album whose size happened not to move, a row delivered below the mark.

`touched_at` is the one thing the statement is careful with. It means *when the change
that selected this was made*, never *when a walk last passed over it*, because it is what
orders the download queue — so the upsert stamps only rows whose decision actually moved.
Without that, re-deriving would re-order the whole backlog behind work nobody changed.

**The two expressions must agree.** `derive` is `OfflinePolicy.resolve` in SQL: an
exclusion anywhere wins, otherwise the most generous of the library rung and every album
naming the item. One decides what the mirror fetches and the other is what every screen
reads, so they are checked against each other rather than trusted to look alike —
`offline_flags_repository_test.dart` builds a library whose assets sit in every subset of
two included albums and an excluded one, and compares the rows the statement wrote with
what the Dart says, for every combination of rungs.

#### What wakes a pass, and why it is not a fingerprint

A pass is asked for by a **write**, not by a periodic comparison of what the data looks
like.

The mirror used to keep a fingerprint of upstream — asset count, album-link count,
`MAX(updated_at)` — and skip the pass when it had not moved. That cannot work, and the
reason is worth stating plainly because it produced the worst symptoms this fork has had:
**a fingerprint of column values cannot see a row change in place.**
`remote_asset_entity.updated_at` is filled from `fileModifiedAt`
(`sync_stream.repository.dart`), so it is a property of the photograph and not a clock,
and the count was over every row, trashed ones included. Applying an edit, reverting one,
favouriting, trashing — none of them moved any component of it. Reverting an edit and
watching the mirror ignore it is exactly that fault. So was hashing a camera-roll row,
which is what decides whether the mirror owes an item a full-size copy at all, and which
moves no count whatsoever.

What starts a pass now: a cold start, an app resume, **any write to upstream's assets,
albums or album links**, and **any write to the camera roll**. The first is
`onRemoteChanged`, which every path that applies server state already fired; the rest are
drift table-update streams (`watchRemote`, `watchLocalAssets`), which cost nothing to
observe and say exactly as much as is needed — that something wrote. Both are debounced,
because these arrive in bursts.

Each of them **marks a flag as well as asking for a pass**, and that is the half that is
easy to leave out: a pass that is asked for and then decides nothing has changed is the
same as no pass at all. The flags are claimed at the start of a pass and given up only if
it finished without being overtaken, so a write landing mid-pass is not swallowed by the
pass that could not have acted on it.

"Overtaken" is decided by **counting writes, not by comparing the flag**. The flag is
already set whenever a pass begins after one that did not settle — every launch, and
every pass that stopped at its budget — so a write during the pass sets it to what it
already was, and a before-and-after comparison of it reads "nothing happened". The
remote watcher therefore counts each write the moment it arrives, ahead of its debounce;
only the request for a pass waits for the burst to end.

It is also cheaper than what it replaced. `updated_at` is unindexed, so `MAX` over it was
a full scan of the widest table in the schema, paid on every resume and every websocket
batch. What is left is one `COUNT(*)`, and only as a guard against acting on a database
that is still being repopulated after a fresh install, a sync reset or a sign-out.

### 3.2.1 Why the flags live in their own file, attached to upstream's connection

Per-asset state wants to live next to the assets. It does — the fork's tables are in a
file of their own, `mirrich_offline.sqlite`, **attached to upstream's connection** as the
`offline` schema in the pragma list every pooled connection already runs
(`data/db/main/database.dart`). One connection, so a statement can join what the user selected
against the assets, the albums and the camera roll; a separate file, so none of
upstream's schema machinery is the fork's business.

**Attached rather than merged**, for three reasons in order of how badly each bites:

- `Drift.reset()` empties `sqlite_master` of `main` and vacuums, and the sync settings
  screen can reach it. Tables in `main` would go with it, leaving every stored byte on
  disk with nothing left to describe it. An attached file is untouched.
- Upstream's schema is a single `schemaVersion` integer with a step-by-step migrator and
  a committed snapshot per version. That number line cannot safely be shared with an
  upstream we do not control: whichever side renumbers after shipping leaves installed
  databases stamped with a version that now means something else, and the migration that
  should have run for them never does.
- It keeps the fork out of upstream's generated migration files and its all-pairs
  migration test, which is most of the rebase surface a merged schema would cost.

The fork's own schema is **not versioned at all**. These tables are derived — `wanted`
from the selection and the albums, `held` from what is on disk — so there is no data to
carry across a change of shape, only a shape to ensure, and idempotent DDL says that in
one step (`ensureSchema`). A startup check refuses to run if upstream has grown a table
by one of the fork's names, because unqualified names resolve to the attached schema only
while `main` has nothing by those names; that turns a silent shadowing into a crash on
the first run after the rebase that caused it.

**Nothing is copied that can be joined.** A `wanted` row carries what the *selection*
says — the rung, whether it was fetched by hand, whether a *Save offline* is outstanding,
and when the change that selected it was made. What the item *is* is upstream's to answer:
its type, whether it is a Live Photo, its thumbhash, whether it has been edited or
trashed, and whether the camera roll holds it. The one exception is `created_at`, and it
earns its place: it is the second key of `idx_wanted_queue`, so reading it from the asset
row would make every page of the download queue sort the whole selection instead of
walking an index.

That exception aside, the rule is absolute, and it is the lesson this fork learned the
hard way. Three of those facts *used* to be columns, refreshed by whichever pass happened
to walk the row, and the worst of them was the camera roll: hashing an existing local
asset is the most ordinary write a phone makes, it moves no count, and every way of
missing that refresh was a way for the mirror to fetch a full-size copy of a photo the
phone already held and then draw it as though a setting maintained it. A remembered
answer can be wrong. An asked one cannot.

**What counts as storable** (`_storable`, `offline.repository.dart`) is: not
trashed, not in the locked folder — storing those would leave bytes readable
outside the PIN gate — and **not hidden**. Hidden is the video half of a Live
Photo, which upstream hides so the pair does not show twice and then excludes from
every query of its own. The mirror must match, and not only for consistency:
upstream *skips thumbnail generation* for a hidden asset, so it has no thumbnail
and no preview and never will. Wanting one is a 404 on every pass forever: three Live
Photos in a library are six files re-found and re-abandoned indefinitely, with nothing
on screen able to explain it.

#### What the phone already holds is not fetched again

Upstream renders a photo from the **camera roll** whenever it can:
`_shouldUseLocalAsset` in `image_provider.dart` prefers the local file for both the
grid thumbnail and the full image, and the share and save paths do the same. So for
an asset that exists on the phone *and* on the server, a mirrored original is never
read — it is insurance, not a cache, and downloading it doubles the bytes on the
device for no gain until the local copy goes away.

So the mirror skips the expensive half — an image's original, a video's playable
file, a Live Photo's motion part — while the local copy is the one the app would
render. It skips nothing else: the thumbnail and preview are still mirrored at
whatever rung the selection asked for, and they are the floor that keeps the item
openable the instant the local copy stops being usable. A rung that selects nothing
still fetches nothing; this rule removes files, it never adds any.

**One copy per device is the rule** (`OfflineAsset.localCopyUsable`): the phone
holds the photo, so the mirror does not hold it twice. Two qualifications, and only
two:

- an **edited** asset is excluded — the server's rendition is the picture now, and
  the local file is the pre-edit one, so it is no substitute;
- the camera-roll match is by checksum, exactly as upstream's merged view does it
  (`merged_asset.drift`).

Upstream's **Prefer remote images** deliberately does *not* enter into it. That
setting says which copy to decode while online; it says nothing about whether the
phone has the photo. Conditioning the skip on it would mirror a merged photo in full
for anyone with the setting on, which is the duplication this rule exists to remove.
The cost is that with the setting on and no network, the viewer falls back
to the mirrored preview instead of showing full quality from the camera roll — an
upstream gap, since the local file is right there.

An **errand overrides all of it**: "Save offline" asks for this app's own copy,
usually because the camera-roll one is about to go.

**And what that errand fetches is a spare, at every rung.** This is the one place the
selection does not decide what is maintained: a full-size copy of an item the camera
roll holds is one the mirror would never have fetched, so no setting can be said to be
maintaining it — not the library at "full quality", not an album at "full quality +
videos". Reading the rung instead would file that copy as *library*, which promises a
maintenance it does not get and puts it out of reach of the removal that should take
it, since the maintained band is locked until every spare above it is going (§3.6).
The item's thumbnail and preview are unaffected: those the selection does ask for, and
they stay in the library band, so a removal cannot strand the item off the grid.

That predicate is SQL, and the camera roll is one join away: both databases are on one
connection (§3.2.1), so it asks `EXISTS` against `local_asset_entity` on the checksum —
the same match upstream's merged view makes — with an edited asset excluded, because the
server's rendition is the picture now and the local file is the pre-edit one. `EXISTS`
rather than a join, because a checksum can match several camera-roll rows and one extra
row would multiply every `SUM` the storage figures are built from.
`test/medium/repositories/offline_flags_repository_test.dart` puts a real camera-roll row
in and takes it away again, which is what Free Up Space does.

This is the most volatile input the mirror has — Free Up Space exists to delete those
local originals, and the moment one goes the mirror owes that item a full copy again — so
it is the last thing that should ever have been written down. It was, once, as a
`local_copy` column refreshed by whichever pass happened to walk the row, and that is the
single worst fault this fork has had:

1. **A remembered answer is one that can be wrong.** Hashing an existing camera-roll row
   is the most ordinary write a phone makes and it moves no count, so a pass that gated on
   what the data *looked like* concluded nothing had happened and skipped the refresh. The
   mirror then fetched a full-size copy of a photo already on the phone and drew a full
   white bar over it, claiming a setting was maintaining the thing. Re-deriving the
   selection could reset the column too, so the fault had two independent sources. Asked
   rather than remembered, it has none.
2. **A skipped file is counted, but not as a failure.** Otherwise the progress line
   sits short for ever over photos that are on the phone twice over. It has a
   counter of its own (`onDevice`) rather than joining `unavailable`, which means
   "upstream will not give us this": beside downloading, a deliberate saving read as
   a stack of errors, so it is stated in **Storage** instead, as why the store is
   smaller than the selection implies. Derived per pass from the difference between
   what the row implies and what the live asset asks for, so there is no column to
   keep in step and it cannot drift from `filesFor`.
3. **Nothing is fetched for an asset the server has not derived yet.** No thumbhash
   means no thumbnail and no preview exist, so every URL would 404 — and the cache
   buster is *in* the blob name, so those 404s would be recorded against names
   nobody asks for again, which is how a preview ends up abandoned. A photo uploaded
   from this phone is in that state for a few seconds, which is exactly when a pass
   runs. Those files are missing, not `onDevice`: they are coming.

Still open: iOS *Optimise iPhone Storage* means a local asset can be a placeholder
whose bytes are not resident, and `hasLocal` does not say which. Skipping the
original for one of those leaves nothing to render off-grid until a later pass. It
needs a PhotoKit residency check.

#### A Live Photo is one item, with four files

Excluding the hidden half must not lose the motion video, or the top rung would
quietly stop meaning "and videos" for Live Photos. So the motion part is fetched as
a **file of the photo**, not as an item of its own:

- `detailsFor` carries `motionVideoId`, and `filesFor` adds the playable file at
  any rung whose `videoTier` is not `none` — a fourth file beside the thumbnail,
  the preview and the original;
- it is stored under the **motion asset's URL**, because that is what the viewer
  asks for (`offlineVideoUrl(livePhotoVideoId ?? id)` in
  `video_viewer.widget.dart`), and recorded in `held` under the **photo's** id,
  because that is the item the selection covers. Reclaim, progress and *Remove
  offline* then all follow the photo;
- the two places that have to know it — the reclaim band, where without it a Live Photo's
  video is "maintained by nothing" and the integrity pass deletes it the moment it lands,
  and the file count behind the progress line, which is 4 rather than 3 for these items at
  the top rung — read `live_photo_video_id` off the asset row, which is where it has
  always been true.

A decision written about a hidden half *before* this existed is stale rather than
blocked, so the pass forgets it (`hiddenIds`). That is the one case where an asset
upstream still has a row for is dropped anyway: unlike the trash and the locked
folder, being the hidden half of a pair is not a state the user put it in.


### 3.3 The three passes

`lib/domain/services/offline_sync.service.dart`

Reconciliation is three passes of very different cost, and which one runs is the
whole performance story. Everything the app does routinely must be cheap enough
to be invisible; only the rare pass is allowed to be proportional to the library.

| Pass | Cost | When |
| --- | --- | --- |
| `check` | one `COUNT(*)`, and nothing else unless something wrote | every resume, and every write upstream or to the camera roll |
| `sync` | one statement to re-derive, then a walk of the wanted list | when a write says so, and after every decision |
| `reclaim` | one isolate, one walk of the whole store | weekly, or on demand |

**`check`** stops immediately unless a flag says something has been written since the last
pass read it (see *What wakes a pass*, §3.2). Past that gate it re-derives every decision
— one statement — drops any album upstream no longer has from the selection, and runs
`sync`. Nothing in there is proportional to what *changed*, because nothing needs to be:
total is cheaper than incremental once the selection and the assets share a database.

**`sync`** pages the wanted list and asks the **in-memory index** (§3.4.2) which files are
missing. It does not touch the filesystem: a `stat` per file is three system calls per
asset per pass, and the index already knows. What it finds goes to the queue in the order
§3.3 defines, and the hand-over window is small on purpose (§3.3).

Two consequences worth knowing. During the thumbnail phase only items kept at the
thumbnails rung become *available* — every other rung asks for the preview too — so for a
library at previews or above the item counter sits still while the file counter climbs,
and the tiles' first sections fill. And tasks already handed to the downloader keep their place: a re-order
cancels nothing that is already spending data, so a change takes effect at the next batch,
not mid-flight.

A pass that is **not allowed to download** — opening the offline screen, a resume that
could not reach the server — looks but does not act. It does not mark the flags as read,
and it does not load what it found into the queue either. Both halves matter and only the
first was obvious: marking them read would let a pass that merely looked silence the next
one, and *planning* without handing anything over leaves a queue full of work with nothing
driving it, which the screen then reported as files on their way for as long as it took
something unrelated to shake it loose. A read-only pass is for the figures; the plan
belongs to the pass that can act on it.

The same reasoning applies to a pass that **handed tasks back** — trimming the downloader
to the window, or dropping one that had stopped moving. Those files were skipped by the
walk as in flight, so nothing planned them, and a pass that then called itself finished
would be claiming everything was accounted for.

And the flags are **claimed at the start and given up at the end**, never simply cleared.
Everything in between is a decision made from a snapshot, so a row that changed while the
pass ran is one the pass could not have acted on — and calling it seen is how a photo
uploaded seconds earlier ends up with its preview never fetched: the thumbhash it was
waiting for landed mid-pass, and the next check was told nothing had happened since.

#### What gets downloaded first

Mirroring a library takes hours, so the order decides what the phone can do for
those hours. One tier above three keys:

0. **an errand, before everything.** "Save offline" on a selection is a claim on
   the next few minutes of bandwidth rather than a preference. It is a tier and not
   a key because it needs no comparison with the rest: whatever is asked for by
   hand comes first. The mark is a column of its own (`wanted.pinned`, set until
   the item's files are here) because `on_demand` cannot express it — that column
   answers whether the copies are reclaimable as a cache, which is false
   whenever a selection *also* covers the item, exactly the case where the errand
   still has to jump the queue;
1. **the most recent decision first.** Every `wanted` row records `touched_at` —
   when the change that selected it was made, to the second — and the list is paged
   by it. Ticking one album during a library-wide sync therefore fetches that album
   next, videos included, rather than behind a hundred thousand files. Whole
   seconds is deliberately coarse: one re-derivation is one batch, and finer would
   sort the rows of a single change by the order they happened to be written, which
   says nothing about what anyone wants first;
2. **cheapest and most useful file first**, within one decision: every thumbnail,
   then every preview, then full-size photos, then videos
   (`OfflineVariant.fetchOrder`). Each step up is roughly an order of magnitude of
   bytes for one step down in what it buys — thumbnails make the whole grid
   browsable for a few percent of the store, previews make those items open,
   originals only make them sharper;
3. **the newest photo**, to break what is left.

**The order between keys 1 and 2 is load-bearing in both directions, and both
mistakes have been made here.** Cheap first *above* recency looks tidier and
silently redefines what a decision means: switching one album to full quality
during a library-wide preview fetch stops fetching that album at all, because every
missing preview in the library outranks its originals. Recency *above* cheap, with
no tier above it, starves an errand instead: hand-saving photos queues their
originals and nothing else, at the bottom of the ladder, behind a stream of
previews that is topped up faster than it drains. Decision, then the ladder, with
errands lifted out of both, is the only arrangement that answers all three.

**The hand-over is where an order stops being one.** The downloader has a holding
queue — `(Config.holdingQueue, (16, 16, 8))` in `main.dart`, raised by the fork from
upstream's `(6, 6, 3)` — so **at most eight tasks of one group run at once**, the
rest wait inside the plugin in priority order, and nothing already handed over is
ever re-ordered. A priority is a small integer, so it cannot carry key 1 at all. It
carries what fits (`offlineTaskPriority`: an errand at 6, then 7 to 10 down the
ladder), and the window carries the rest.

**The window is sized for speed, not only for order.** Most of a library is
thumbnails and previews, which transfer in a fraction of the time a task costs to
schedule, so how fast a large mirror fills is decided by how many run at once and
by never letting a slot sit idle — not by bandwidth. Upstream's three per group,
fed two dozen at a time, made a six-figure library a matter of days on any link.
So `_maxOutstanding` is 200, handed over 50 at a time: enough to keep eight slots
busy between top-ups, and enough to keep downloading for a while after iOS
suspends the app, since nothing tops the window up until it is back. The price is
that a decision made a moment ago waits behind up to 200 small files — seconds —
while an errand waits behind none, its priority putting it first inside the plugin.

Full-size files are capped separately, at 16 in flight
(`_maxOutstandingFullSize`). They are bandwidth-bound, so a deeper queue of them
buys nothing but delay: two hundred videos queued behind eight running ones would
hold every decision made after them for hours. The cap waits at the head of the
queue rather than skipping past it, so it never reorders what the pass decided.

A pass that finds the downloader holding more than the window — an older pass's doing, or the build before an update, since the plugin's
queue outlives the process — hands the worst-priority excess back, and the next
pass asks for those files again in the order it decides.

**Every one of those numbers sits below an upload.** The backup shares this
downloader, this holding queue and this host, and an upload task is priority 5
(`background_upload.service.dart`), or 0 for a Live Photo's companion. Sending a
photo that exists nowhere else matters more than copying back one the server
already has. Anything here that outranked 5 would put a flood of previews in front
of a backup, so a test pins the rule.

**And priority is not enough, so the mirror also gives way outright.** A queue the
mirror keeps full is a queue the backup waits behind for as long as one of its own
tasks takes, whatever the numbers say, so the hand-over stops while upstream's
backup is transferring (`isBackingUp`, beside the pause and the storage limit in
`_isStopped`). It resumes when the backup goes quiet — a finished upload is itself a
remote change, and the provider also nudges a pass when the backup falls idle,
because the last upload may have failed and then nothing else would.

**Activity, not backlog, and never for ever.** Two things make that courtesy safe,
and both are the difference between yielding and deadlocking:

1. it asks for **tasks in flight that have not failed** — `uploadItems`, minus the
   ones marked failed, which is the only figure in `BackupState` that means bytes
   are moving. The two that look like it are not: `remainderCount` is the backlog
   ("assets that do not yet exist on the server") and `processingCount` is assets
   still waiting to be hashed. Both stay non-zero for ever over a photo the backup can
   never send, and iOS supplies them — a camera-roll original whose temporary copy has
   gone fails with `PathNotFoundException` on every retry. A failed item also *stays*
   in `uploadItems`, because that is what draws the error list, so it is excluded by
   name rather than by hoping the map empties;
2. even in-flight work only earns `_maxYield` of patience. Past that the backup is
   not transferring so much as failing, and the mirror hands work over anyway. The
   fallback is not "no protection": every mirror task sits below every upload in the
   shared holding queue, and its group concurrency caps it at eight of the sixteen
   slots, so the ordering alone still does most of the job.

**Which is why the pass line names what stopped it.** The queue owns every reason it
is holding still (`stoppedBecause`), and the log prints it, because a pass that finds
work, hands none over and says nothing reads exactly like a pass that found nothing
to do — the one shape of failure that is invisible in a log full of healthy-looking
lines.

**Sorting a batch is not enough, because the batch is a window.** The pass stops
once it has found 3000 missing files, and collecting them in `wanted` order fills
that budget with everything the newest items need — their originals included —
while older items still have no preview at all. So the walk spends the budget on
the errands first, then **one decision at a time**, newest first, and within each
decision takes the cheap half before the full-size one. The same order again,
applied where it decides something else: which three thousand files a bounded pass
can see at all.

That leaves the walk's own cost, which must not grow: stopping at the budget is
what keeps a pass proportional to what it can *do* rather than to the library. It
stops as soon as the current decision's cheap half fills the room left — every
decision behind it is older — and, when nothing cheap is missing at all, as soon as
the full-size half does, which is where a full-quality library spends its life.
Each half is capped at the budget too, or a decision covering the whole library
would buffer it before handing anything over. Knowing whether to chase cheap files
costs one `EXISTS` (`hasMissingBase`), where `wanted` and `held` sit side by side, rather
than a walk to find out. Its one blind spot is a
*superseded* preview, whose token lives in `held` but whose comparison needs
upstream's thumbhash: it reads as present, so a later pass picks it up once the
full-size half is no longer filling the budget.

The errand bucket never stops the walk. It is small by construction — the size of
what the user tapped — and it outranks whatever the budget would have dropped
anyway. A pass that reads an errand's row and finds nothing missing clears the
mark, so a finished errand stops outranking a selection made after it; a pass that
stopped at its budget concludes nothing about rows it never read.

**`reclaim`** is the integrity pass, and it is *not* how storage normally comes
back. "Free up space" is, and it works from the same rows — one query and one
`unlink` per file it quoted. `reclaim` exists for what that cannot see: files left
by an interrupted pass, a thumbnail superseded by an edit, a row describing a file
that is gone. It runs on its own isolate, and does its set difference in SQL
against a temp table, so a six-figure store never becomes a six-figure Dart
collection. The wanted set crosses to the isolate as 64-bit name hashes — two
megabytes of integers rather than ten megabytes of strings. A hash collision keeps
a file that could have gone; it can never delete one that was wanted.

Its "did the table move under me" guard is the same write count that wakes a pass
(§3.2), which makes it stricter than the fingerprint it replaced: that one could not
see an asset change in place at all. Behind that guard the isolate refuses any sweep
that would delete more than a quarter of the store. A flipped video form is the one
instructed reduction, and it is exempt only for what it supersedes — the playable
`.mp4` names — so a flip that coincides with a half-repopulated asset table still
cannot take the previews with it.

It reconciles in one direction. Wanted-ness decides which files live, and a file
that is gone retracts its `held` row — but a file found *without* a row creates
nothing: recovering the asset id and variant would mean parsing a name back into
its parts, a third implementation of the naming scheme, to repair a state that
costs one redundant download and then corrects itself. Absence wins both ways;
presence only counts where it was recorded.

**It does not delete on the strength of the selection.** Deselecting never makes a
file deletable — only "free up space" does (§3.2) — so the pass walks what is
*recorded as held* and removes only what nothing accounts for: a file with no row
behind it, or one whose row was superseded when a newer generation of the same
variant arrived. That is a narrow licence, and it is why it needs little guarding.

The one deletion it still makes unasked is a file whose asset **upstream no longer
has**. There is nothing to show the user, no way to recover it from the server, and
keeping the bytes helps nobody. It forgets that asset's *decision* in the same pass,
and only there: a row for a photo that can never arrive would otherwise hold the
progress figures one file short of complete for good. It is careful about which
absence counts — an asset missing because it is trashed or locked keeps its
decision, since the trash is undoable, so only an asset with no row upstream at
all is forgotten. Both happen past the gate that checks the asset table did not
move mid-pass, because a half-populated database looks exactly like a library
someone emptied on the server.

Two gates remain, both because a bad sweep would empty the offline library:

1. it refuses to run when upstream's asset table is empty — a database
   mid-repopulation is not an empty library;
2. it defers if that table moves while it is reading, since the set it builds spans
   many queries and would otherwise describe half of one library and half of another.

A pass that defers sets `reclaim_pending`, so the next launch retries rather than
waiting out the weekly interval — what stops it clears in minutes. A flipped
`loadOriginalVideo` also beats the interval, because it renames every video's file at
once.

Passes are serialised through a single lock. A flag would let `reclaim` and a
decision written from the UI interleave, and let `setPaused(false)` silently do
nothing because something else happened to be running.

### 3.4 Where bytes live

`lib/utils/offline_paths.dart`, `ios/Runner/Images/OfflineStore.swift` and
`android/.../images/OfflineStore.kt`

One store under `mirrich_blobs/` — Application Support on iOS, `filesDir` on
Android, which are the same thing: the place the system does not empty on its own,
as against Caches and `cacheDir`, which it does. One region, `pinned/`, written by
two parties (§3.1.2):

| Written by | When | Evicted |
| --- | --- | --- |
| the reconciler, through `background_downloader` | a selection or *Save offline* wants it | only if it is a spare |
| the native image path | every successful fetch for the screen | only if it is a spare |

**Viewing a photo counts towards mirroring it.** Upstream puts bytes fetched for
the screen into a `URLCache` no reconciler can see, so a photo the user has just
looked at would be downloaded a second time and stored a second time to end up
offline — and that `URLCache` is a gigabyte, under `Caches/`, where iOS purges it.
Here it is cut to 64 MB and holds API traffic only, and the bytes the image path
fetched are already in the store, where a selection that wants them finds them.

- **Application Support, not Caches.** iOS purges Caches under storage pressure,
  which would silently empty the offline library.
- **Excluded from iCloud backup.** Every blob is re-downloadable and a mirrored
  library is tens of gigabytes. `OfflineStore.prepare()` sets
  `isExcludedFromBackup` on the root at launch.
- **Filenames are derived, not hashed.** The path already carries the asset id
  and the variant, so a name reads `assets_<id>_thumbnail_preview_<token>` — an
  asset's files sort together, the store is inspectable, and there is no
  cryptographic hash on the render path. Scheme and host are excluded on purpose,
  so a file fetched over the LAN endpoint still resolves after upstream's auto
  endpoint switching moves to the external one. The rest of the query becomes the
  8-hex `token`, because upstream appends a `c=<thumbhash>` cache buster that
  changes when an asset is edited — an edited asset lands on a fresh name rather
  than serving stale bytes. `held` keeps at most one row per asset and variant, so
  writing that new name drops the row for the old one, and the integrity pass then
  finds a file nothing accounts for and sweeps it. Without that both generations
  would sit on disk for good, each vouched for by its own row.
- **`/original` needs that buster adding, and only when there is an edit**
  (`offlineOriginalUrl`). The server resolves `/original?edited=true` to
  `editedPath ?? originalPath`, so its bytes change on an edit while a name derived
  from it does not — the full-size copy stayed the pre-edit picture for good, since
  nothing ever asked again. An edited asset therefore carries the thumbhash; an
  unedited one carries nothing, because busting it would rename every original
  already on every device for identical bytes. Three parties build that URL (the
  reconciler, `RemoteFullImageProvider`, the share sheet), so there is one function
  and all three call it. `OfflineIndex.holds` compares an `originalToken` rather
  than trusting the presence bit.
- **Buckets are hashed, the names are not.** Every name begins `assets_`, so
  sharding on the first characters would put the entire library in one directory.
  A byte of FNV over the name gives 256 buckets.
- **Playable URLs get an `.mp4` extension.** AVFoundation infers the container
  from the path; an extensionless file opens as a black frame. "Playable" is any
  name whose last path segment is `video` or `original`, which also catches an
  image's `/original` — see §6 for why that is left alone.
- **URLs come from upstream's own `image_url_builder.dart`**, and the video URL
  mirrors `video_viewer.widget.dart` including its `loadOriginalVideo` branch.
  Anything else would store bytes under a name the rendering path never looks up.

Several parties must agree on that naming, and they are named in each other's
comments: the downloader that writes it, the reconciler that lists it, and the
native readers in Swift and Kotlin (§3.4.3). **If a native naming diverges from the
Dart one, every read misses silently.** Change them together, and mind the three
places Dart and Swift differ by default. Each agrees on every URL Immich emits today and need not agree
on the next one, and a disagreement shows up as a store nothing can read back:

> **Percent-encoding.** Swift's `URLComponents.path` / `queryItems` return the
> decoded form; Dart's `Uri.query` returns it as written, while `Uri.pathSegments`
> / `Uri.queryParameters` return it decoded. Upstream appends the thumbhash as
> `c=<base64>`, whose `+ / =` are escaped, so hashing a raw URL agrees on
> unedited originals (`edited=true` has nothing to escape) and disagrees on every
> thumbnail — and, since the buster reaches originals too, on every edited photo at
> full size. An app that opens some full-size photos offline and shows no
> thumbnails. Both sides read the decoded accessors and hash UTF-8 bytes.

> **Repeated query keys.** Dart's `queryParameters` is a map and keeps the last
> value; Swift's `queryItems` is an array and keeps both. Both sides take
> last-wins.

> **String order.** The query is folded into a token by sorting `k=v` pairs, and
> Swift's `String.<` orders by Unicode canonical equivalence while Dart's
> `compareTo` orders by UTF-16 code unit. Both sides sort by UTF-8 bytes, the one
> ordering each language can state exactly.

Upstream's "clear cache" setting empties the `URLCache` and nothing else. It does
not touch the store, and must not be changed to: spares already leave on their own,
and the library has its own control on the offline copies screen.

A fourth party is the share sheet, which asks for `edited=<asset.isEdited>` and
no thumbhash. Same bytes, different key, so it looks the file up under the
canonical form instead of its own (`asset_media.repository.dart`). A video is
stored in the form the player asks for — its playback file, or `/original` while
"load original video" is on — and `offlineVideoUrl()` is the single definition,
shared by the reconciler, the player and the share sheet. The share sheet always
asks it for `/original`: a playback file shared under the original's name is the
wrong bytes, so with no stored original it downloads one.

Two traps in `offlineBlobPath`:

- `getApplicationSupportDirectory()` is a **platform channel round trip on every
  call** — path_provider does not cache it. Called per lookup that is several
  channel hops per thumbnail while scrolling, so the path is resolved once and
  kept.
- It is `async`, so every caller has an await gap. `video_viewer.widget.dart`
  checks `mounted` after every other await for a reason: returning a video source
  after the viewer is gone creates a native player nothing owns, which then sits
  above the entire app swallowing gestures.

#### 3.4.1 One limit, and spares make room

There is one figure: **Storage limit** (1 GB … 200 GB, or No limit). It caps the
whole store, library and spares together, and whatever it says, the store also
leaves 1 GB free on the device (`_freeSpaceFloor`) — so No limit means "until
the phone is nearly full", not "until it is full".

**Over the ceiling, spares are evicted, least recently used first**
(`OfflineSyncService._evict`), down to a twentieth below it (at most 256 MB) so a
store at its limit is not evicting on every file that lands. It runs after every
batch of files is written, before every pass hands work over, and when the limit
changes. Which items go is one query (`evictionCandidates`): a running total over the
spare items, oldest first, stopping at the one that covers what is over the target —
paging a fixed number of items at a time re-scanned the store per page, and a few
hundred megabytes of thumbnails is tens of thousands of items. Three rules keep it safe:

- **Only spares.** The candidates come from the same `_unselectedOver` predicate
  as the spares band on the cleanup sheet, so eviction can only take what that
  band shows. The library is never evicted to stay under a number.
- **Whole items.** An item's spares leave together, ordered by the most recent use
  of any of them, so eviction never strands a spare original without its spare
  preview.
- **Never an item whose *Save offline* is still on its way.** Otherwise a save
  larger than the free room evicts its own first files, the queue finds them
  missing and fetches them again, in a loop. Once the errand is done its files are
  spares like any other — saving stamps the copies already here as just used, and
  the ones it fetches are stamped as they land, so they are the last to go.

A hand-saved item whose files have all been evicted stops being wanted
(`dropFetchedWithoutFiles`), or the next pass would fetch it straight back.

**Used means stored or shown.** `held.used_at` is stamped when a file lands and
when it is served — by the native image path, reported in its batches, or through
`offlineBlobPath` for the player and the share sheet. One `UPDATE` per batch,
not one per read.

**When only the library is left, downloading stops.** That is the old ceiling's
behaviour, and it is still the only automatic answer for the library: the queue
stops handing work over, the screen says the store is full, and it clears itself
when space is freed or the limit is raised.

#### 3.4.2 Two indexes, and why neither is optional

Nothing on a hot path is allowed to ask the filesystem.

**Native — `OfflineStore.present`.** A set of 64-bit name hashes, built once at
launch on a background queue. The image request runs on the platform's own
thread, so all it does there is derive the name and ask this set whether a
syscall is worth it; the read itself happens on the store's own queue or pool,
never on the one decoding is already saturating. A false positive costs one
failed `open`, never a wrong image. Dart keeps it in step through
`mirrich/offline_store` — `noteStored`, `noteRemoved`, `forgetAll` — because the
reconciler writes into `pinned/` and Dart deletes from it behind the native side's
back, and a blob it has not been told about would stay invisible until the next
launch. The same channel carries `freeSpace` one way and `activity` the other
(§3.1.2).

There are two of these, one per platform, and they are the *only* thing the fork
writes twice. Everything above them is shared: the reconciler, the queue, the
selection, the integrity pass and the whole UI are Dart with no platform branch
in them, and downloads run on both through `background_downloader`. What a
platform has to supply is a place to put bytes and a read that beats the network,
because the image path is native on each.

**Dart — `offline_index.dart`.** One entry per asset that is wanted *or* stored:
the quality asked for, a bitmask of the variants on disk, and three tokens saying
which files those bits refer to. One covers the thumbnail and preview, which share
upstream's cache buster; one the original, which carries that buster once the
asset has been edited (§3.4); one the video, whose URL depends on
`loadOriginalVideo`. A bitmask alone cannot tell that a file was superseded, and
all of those inputs change under the app's feet. Loaded with a single aggregating query
— which is also where it gets what an item *is* and whether the camera roll holds it,
both joined from upstream's tables rather than stored — and reloaded whole whenever a
statement changes the rows underneath it.

**Its figures are counted, never adjusted.** How many items are wanted, how many files
they imply and how many of those are here used to be maintained by hand, with every path
that recorded a decision or a file adding and subtracting its own share. Nine places, and
each of them a chance for a total to part company with the rows it claims to describe:
progress reading complete over a store that was not, a count only a relaunch could
correct. They are derived from the entries now and memoised, and a mutation marks the
tally stale rather than trying to keep it right. That costs one pass over the entries per
burst, because every reader sits behind the coalescing emit.

The badge reads it synchronously behind a revision counter. Anything else — a
provider per tile, a query per tile, a `stat` per tile — puts I/O in the frame that
is trying to draw the grid.

#### 3.4.3 One name, derived three times

The blob name is derived in Dart when the reconciler downloads a file, and again
in Swift and in Kotlin when the image path looks for one. All three must agree
**byte for byte**, and a divergence is silent in the worst way: every image falls
through to the network, the mirror appears to do nothing at all, and nothing
anywhere says why.

So the rules are written once, in `offline_paths.dart`, and the other two
reproduce them. Three of them are places where each language's obvious spelling is
wrong:

- **the path is percent-decoded, the query is percent-decoded *and* `+` becomes a
  space.** That is what Dart's `Uri.pathSegments` and `Uri.queryParameters` do
  respectively, and one decoder used for both halves is wrong for one of them.
  Kotlin's `URLDecoder` is the `+`-decoding kind, so the path half needs its own.
- **a repeated key takes the last value**, because Dart's `queryParameters` is a
  map. Android's `Uri.getQueryParameter` returns the *first*, so it cannot be
  used.
- **the query is ordered by UTF-8 bytes.** Swift's `String` comparison orders by
  Unicode canonical equivalence and Dart's and Kotlin's by UTF-16 code unit;
  those agree on ASCII and need not agree beyond it.

`test/utils/offline_paths_test.dart` pins the Dart half to literal names and
`OfflineStoreNamingTest.kt` pins the Kotlin half to *the same literals*. When one
of them has to change, every side changes in the same commit — and every user
re-downloads their library under the new names.

### 3.5 Session handling (R2)

`lib/providers/session_state.provider.dart`

`AuthGuard` no longer redirects or wipes. It reports through injected callbacks,
and the notifier decides what the report *means*:

- `SessionIssue.offline` — there is no usable network. Signing in cannot help.
- `SessionIssue.unreachable` — online, but the server did not answer.
- `SessionIssue.expired` — online, and the server rejected the token.

**Connectivity is checked before anything is called expired.** A 401 is not proof
of a bad token: in airplane mode the request never reaches the server, and a
reverse proxy can answer 401 for its own reasons. Telling someone to sign in when
signing in is impossible is the bug this ordering exists to prevent.

`unreachable` is fed from the places these failures actually surface, and each is
easy to lose in a rebase:

- the guard's `ApiException` handler: the generated client wraps transport
  failures (`SocketException` and friends) in `ApiException(400)` **with an
  `innerException`** — a genuine HTTP error response has none;
- a failed `syncRemote()` at cold start and on resume. The splash path cannot
  rely on `saveAuthInfo` rejecting — it catches network errors internally and
  resolves normally when a local user copy exists.

Both are cleared on the next successful validation or sync.

**Order matters, because cold start and resume report twice.** The guard validates
the token in one request while `syncRemote()` is still working, so a session that
lapsed produces `expired` and then, a second later, a failed sync. `expired` is the
sharper fact and survives that — `reportUnreachable` will not downgrade it — while a
fresh reading of "no network" still wins over both, since signing in cannot help
then. Without this the badge below appeared at launch and vanished before anyone
saw it, coming back only on the next guarded navigation.
`test/providers/session_state_provider_test.dart` pins the precedence down.

**The issue is reported, never acted on.** Nothing in the app may navigate, sign
out or clear anything because of it. It is *rendered* in two places, and only
`expired` reaches the second one:

- a line on the offline copies screen (`_SessionNote`), which for `expired` is
  also the control that opens the login screen;
- a red ✗ badge on the app bar's offline button, above every other badge state.
  The app goes on working signed out, so without it the only sign of a lapsed
  session is a line on a screen there is no reason to open. `offline` is what this
  fork is for and `unreachable` is indistinguishable from a flaky network, so
  neither appears here — a badge that is always on says nothing.

### 3.6 The UI

| Where | What |
| --- | --- |
| Album ▸ Options | **Available offline** — follow the library / thumbnails / previews / full quality / full quality + videos / never keep, with progress |
| Multi-select, and the viewer's ⋮ menu | **Save offline as spares** beside upstream's Download, becoming **Remove offline** once everything selected is here |
| Settings / profile dialog | **Offline copies** — downloading, selections, storage |
| App bar | Two cloud buttons, one per direction: offline copies and upstream's backup. Gated separately, so hiding the upload button on the library tab or an album does not hide this one. The offline one badges a red ✗ while the session is expired (§3.5) |
| Thumbnail badge | Upstream's own cloud, kept verbatim, plus a meter under it for what the mirror holds (below) |
| Free up space | Upstream's screen, plus one line saying what the deletion costs offline |

**The progress line only counts what can actually arrive.** A decision survives
its item going into the trash, being moved to the locked folder, or leaving the
server, because the first two are undoable and dropping the row would lose the
selection. But those files will never download, and counting them would leave the
line reading `160 of 166` for good with nothing on screen to explain the gap — the
one stuck state with no reason to show at all, unlike a pause, a limit or a failure.
The reconciler counts them as it pages (`unavailable`, only from a pass that
reached the end of the list), progress is measured against `wanted - unavailable`,
and the screen names them — `· 6 can't be downloaded` beside the total, and a line
under the bar saying the items are in the trash or the locked folder, or hidden.
They are not failures and there is nothing to retry; if the items come back, so do
the files.

**A decision about a photo the server no longer has is stale, not blocked**, and
the same pass settles it: the ids that resolved to nothing are checked against
upstream's table (`existingIds`), and the ones with no row at all are forgotten
on the spot. Leaving it to the integrity pass would do the same thing weekly, and a
counter that sits short for days over photos deleted from another device — with
nothing on the screen able to fix it — is the state this avoids. Absence from
`detailsFor` alone is not
enough to conclude it, since that filters to what can be *stored*: the trash, the
locked folder and hidden assets are all missing from it too, and the first two are
undoable.

**And it clears the moment the reason does.** Freeing space is the cure for the
limit, so the reclaim ends by looking again — the ceiling is only ever re-read by a
pass, and without that the store sits under its limit with an idle queue until the
next resume, which makes pressing *Free up space* look like it did nothing. Raising
the limit runs a pass for the same reason. Neither resumes a pause: the queue asks
that for itself.

**A stop the user did not ask for says so in three places.** A store whose library
alone fills the ceiling is the one state where downloading stops on its own, so
it is not left to be discovered from a progress line that has stopped moving: the
app-bar badge turns to a storage icon on the error colour — told apart from the
failure badge by its icon, since a full store is not a broken one — the summary
line carries `· storage full`, and the screen states it in full with
a **Free up space** button under it. That button is the point: it is the only
stopped state with something to do about it on this screen, so the way out is a
tap rather than an instruction to go and find one. A pause, by contrast, has one
cause and one cure and needs none of this.

**A pause stays paused.** It is an instruction about spending data, not about
what may be asked for, so choosing an album or saving items offline records the
want and leaves downloading stopped. Anything that can be reached while paused
says so instead — the multi-select action answers `Added — downloading is
paused, so these will arrive when you resume` rather than quietly starting the
radio. Resuming has exactly one cause: the button that says Resume.

**A long list of albums is a short list plus a search box.** A library with two
hundred albums would otherwise put two hundred rows between the setting they all
fall back to and the storage figures that report what the lot costs, and both
ends of the section become unreachable. So the albums the selection names come
first and are never hidden — those are the only ones there is a reason to read —
and the rest is capped at eight until *Show all* is pressed. The search box
appears only once there are more albums than the cap, and searching looks through
every album regardless of what is selected or collapsed. The section is a sliver
rather than a column for the same reason: rows that are not on screen are not
built.

**No apply button.** A selection *is* the action. With a separate button it is never
clear which rows have taken effect and which are waiting, it is inert on a fresh
install with nothing to explain it, and once album rows act immediately it can be
pressed and visibly do nothing.

**An option that cannot be picked is disabled, not removed.** "Exclude from
offline" only means something when there is a selection to override, so with the
library unselected it greys out and says why — `The global settings keep nothing,
so there is nothing to exclude`. Dropping it from the menu instead leaves the user
to work out both that it existed and what brought it back, and a menu whose length
changes with a setting three rows up is a menu nobody can learn.

**The albums are one screen further in.** *What to keep offline* is the library
rung and a row reading `Albums · 3 kept · 1 excluded`; the albums themselves are a
screen of their own (`offline_albums.page.dart`), shaped after upstream's album
picker (`backup_album_selection.page.dart`) so the two read as the same app
— title and search in the app bar, the same marks and tints down the list. What
is deliberately not shared is the interaction: upstream selects on tap and
excludes on double-tap, which needs a hint line and an info dialog to be
discoverable, while a rung has to be *named* anyway. And the two lists choose
from different libraries — device albums for upload there, server albums for
download here — so a difference in shape is worth keeping rather than a cost.
Upstream's chips summarising what is picked are not copied, because this list
puts those albums first and has answered the same question by the time chips
would be read.

**Downloading means downloading.** The summary counts what the downloader is
actually holding, and names what a pass merely *planned* separately — `· 12
downloading` against `· 2140 waiting`. They used to be one number, and the sum is
not a thing that can be described in one word: a plan of three thousand files with
nothing handed over reads as three thousand files in progress, and does so for
exactly as long as whatever stopped the hand-over lasts. Two figures cost a line of
prose and buy a screen that cannot claim work is happening when it is not.

Every reason a hand-over stops clears by itself — the backup falls quiet, the
courtesy window expires, space is freed — and none of them announces it, so **the
queue keeps a clock of its own**: work left over with nothing running for it is
looked at again half a minute later. Without it the queue waited for whatever
happened to wake the *service* next, which on a quiet phone is nothing at all, and
the way out was to turn downloading off and on. A pause is the one exception, since
that has a resume that says so.

**The screen is three sections, in the order the questions get asked.**
*Downloading* — how it is going, then whether it may run at all, then Wi-Fi only
— comes first: it is what the screen is opened to check, and a stop that has to
be found past a hundred album rows is not a stop. Both controls are switches
rather than buttons, because both are standing preferences that outlive the
launch, and both are worded so that on means on: "pause downloading" as a switch
would be one that stops something when you turn it *on*. It is status with its
own two controls attached, not a second
place to configure what gets downloaded; that is *What to keep offline*, which
comes next, followed by *Storage*, which reports what those selections cost. The
three things that govern downloading sit together for the same reason a switch
that changes what the app spends does not belong beside buttons that remove bytes.

**Storage reports; nothing on it deletes.** Every held file sits on two axes —
maintained by a selection or not, and which of the four kinds of file it is —
drawn as one stacked bar plus a row each (`OfflineFlagsRepository.storage`). The
two groups are named for what they *are* rather than for their state:
**persistent offline library** is what the settings maintain, and **spares** is
everything else the app is holding. A copy fetched by hand is a spare: nothing
re-downloads it and nothing holds it back from a removal, so counting it as
library would promise a maintenance it does not get. What it gets instead is a
line at the point of removal naming what is about to go — the only place the
distinction can change a decision. The spares column therefore has two sources
that look nothing alike, so the legend says so in a line under the colours;
"leftovers" was dropped as its name for the same reason, since a copy the user
asked for by hand is not a remnant. Both groups
list the kinds in the same order, so the two columns of figures can be read
against each other.

The section reads figures, then the limit, then the one control that removes
anything by hand: the bar, the four kinds, the `Storage limit` and `Free up
space`. What browsing kept is not a section of its own — it is spares, and sits in
the spares column like any other.

**Four kinds, the same four everywhere**: videos, full-size photos, previews and
thumbnails — the overview's rows, the cleanup sheet's check boxes, and the sections
of a tile's bar. At the thumbnail rung the thumbnail is library and the preview a
spare, which one combined row could only show as a sum, and one combined check box
could not free the previews while keeping the thumbnails. A file the image path kept
that is none of the tracked variants is filed under the row it looks like
(`offlineVariantOfName`): a full-size rendition with the full-size photos, a face
with the thumbnails. Neither is an item, so neither counts as available offline.

**The figures are not the controls.** A tap on one offering to remove that kind makes
every glance at the numbers one mistap from a deletion, and it can only ever offer one
kind at a time — which cannot say "the videos and the full-size photos, but not the
previews", and cannot free a preview at all while the copy holding it up is still
here.

**Removing happens on a sheet of its own** (`offline_cleanup_sheet.dart`), reached
from one row under the table. It is a grid: two **bands** — whether the settings ask
for the file — each with a check box per kind of file, each carrying its own
figure.

```
SPARES                                                     1.73 GB
Opened, saved by hand, or left by a change to your settings.
Nothing re-downloads these, and the least recently used are
removed on their own when space runs out.
  ☑ Videos                                          1.3 GB
  ☐ Full-size photos                                400 MB
  ☑ Previews                                  3 MB of 18 MB
      Select "Full-size photos" for the other 15 MB.
  ☐ Thumbnails                                        4 MB

🔒 KEPT BY YOUR SETTINGS                                    5.1 GB
Available once everything above is selected.
  ☐ Videos                                          4.1 GB
  ☐ Full-size photos                                900 MB
  ☐ Previews                                         80 MB
  ☐ Thumbnails                                       20 MB

                     [ Free 1.30 GB ]
```

**The bands partition the store**, so the eight figures add up to the one on the
button instead of containing one another. The alternative is nested tiers offered as
radio buttons — spares, then *also* the hand-saved, then *also* the maintained —
where nothing on screen shows that each contains the last, and the figures beside
them move whenever the tier changes.

Hand-saved copies are not a band of their own, because they are not a different
kind of thing: no setting asks for them either. What they are is the part of a
removal nobody can see coming, since nothing on the settings screen ever listed
them — so the confirmation names them: `Includes 3 videos (240 MB) and 12 photos
(48 MB) you saved offline by hand.` The figure comes from the same query as the
total (`reclaimPlan` counts them by media type), so it cannot disagree with what
goes. It is said there and nowhere else, like every other consequence: the sheet
carries figures, the confirmation carries sentences, and printing them in both
means reading the same two lines twice on the way to one deletion.

**The last band is locked until everything above it is going.** Taking what the
settings keep while free space is still lying above it is never what anyone
means: those copies cost a re-download and the ones above cost nothing. It also
buys the property that makes the grid explainable — *every remaining blocker is in
the section you are looking at*. If an item's previews are spares, its full-size
copies are spares too (a rule that keeps an original keeps its preview), so an
item's files straddle the two bands in only two ways, both with the spare being the
bigger file: a photo dropped to preview quality, whose original is a spare, and an
item at the thumbnails rung, whose preview is — and this rule has already taken the
spare before the maintained band can be reached. Untick anything above and the band closes again,
dropping what was ticked in it.

Every band explains itself in one sentence under its heading rather than leaving
each cell to imply it, and the second — the only one that costs a re-download to
undo — is the only one in red, with the pause stated on it rather than discovered
at the confirmation. It pauses because those files are ones a selection asks for and
the next pass would fetch them straight back. Nothing is ever deselected; Resume
downloads them again.

A cell holding nothing stays visible and inert. A grid whose cells come and go
cannot be learned, and `0 B` is an answer.

**The removal order is derived, not declared.** A preview may only go once its
item has no full-size copy left, and a thumbnail only once it has neither a
full-size copy nor a preview; otherwise a bigger file is stranded without the ones
that draw the item in the grid and give the viewer a rung to start on — worse than
keeping or dropping all of them. Enforcing that with a rule of its own strands the
bytes instead: they can then never be freed by any sequence of taps, because
removing the originals does not revisit the previews. So the predicate asks which
bigger files *survive this pass* — ticking previews together with the copies holding
them up frees them, ticking previews alone does not, ticking previews without
thumbnails leaves every item in the grid as a thumbnail, and there is no special
case anywhere. An item's files can sit in
two bands at once (a photo dropped to preview quality keeps its previews in the
maintained band while its original is in the dropped one), which is why the
question is asked per file and not per band.

**And the row says so itself.** A ticked previews row reads `3 MB of 18 MB` and
says what the rest needs — `Select "Full-size photos" for the other 15 MB.`,
quoting whichever bigger rows that band is leaving behind (a thumbnails row names
the previews too) — because the
alternative is a total that quietly fails to add up to the figures above it. It
is also where "full-size" gets defined as covering a video as well as a photo's
original. That number is measured, not
guessed: `reclaimBytesByCell` groups the same predicate the deletion runs by band
and kind, so a row is quoting the deletion rather than estimating it.

**The button carries the figure.** The cells cannot simply be added up — whether a
preview may go depends on the rest of the choice — so the total comes from the
same query the deletion runs (`reclaimPlan`), the button stays inert until it
arrives, and it never shows the previous answer while the next one is on its way.
The sheet opens with nothing ticked: a screen that opens armed is one where a
mistap costs hours of downloading.

Freeing is a barrier with a spinner, and the deletes run on an isolate: thousands
of `unlink` calls on the rendering isolate froze the app for seconds, spinner
included.

**The rows report; the confirmation explains.** A row carries its colour, its name
and its figure and stops there — a consequence printed on every row is read once
and then becomes furniture, and it competes with the figure that row exists to
show. The last word before anything is deleted is the confirmation, which is where
the decision actually happens, so that is where the sentences go.

**It says what will happen** in the terms the user experiences rather than in
bytes alone: what will be removed, then what will be left, in the future tense and
in full sentences, because the second half is what makes the choice safe. It can
afford the words — it is one dialog, read once, by someone who has already decided
to look:

```
Free up 3.1 GB?
  12 videos will be removed from this device.
  Their stills will stay, so they will still appear in the grid,
  but playing them will need the network.
  Only removes offline copies from this device.
```

It is **composed from what the items are left with** rather than from which kinds
were ticked, because that is the difference the user will notice, and one pass can
take several kinds at once. `OfflineReclaimPlan` counts each item once, by the
smallest thing it keeps: removed entirely (its thumbnail goes, so everything does),
a thumbnail only, a preview only, or a still without its video. Worst first. An item
counted as removed is not counted again as having lost its full-size copy — that
adds nothing — and an item that keeps its thumbnail is not called removed, which
the old count by "lost a preview or a thumbnail" did.

The closing line states the scope of the whole dialog rather than listing what it
leaves alone. Naming the selections and the server one by one invites the reader
to wonder what else there might be; "only from this device" answers all of it.

An album's own figure takes every kind at once and skips the sheet: the scope is
already decided by the row it sits on, and a screen of check boxes there would ask
a question nobody has at that moment. The multi-select `Remove offline` is the
same shape for the same reason.

**Every album row reports what its own change left behind** — `Free up 1.2 GB` — on the album's page and on the list of all of them, because both
are places the change gets made and therefore places someone will wonder where the
space went. It is scoped to that album in both directions: the figure it quotes and
the files it removes are the same set. A note that counted one album and deleted
everything would be the mistap this design exists to prevent.

The screen pays two queries, not two per row. Nothing in the fork's database can
be scoped to an album — membership lives in upstream's — but what is reclaimable
is bounded by what is unselected rather than by the library, so it is read whole
and grouped by album from one membership lookup. Asking per row would mean a scan
of every asset in every album listed, to describe something usually empty.

**One cloud, and a progress bar under it.** Upstream's single badge answers "where are
the bytes" — `cloud_off` on the phone only, `cloud` on the server only, `cloud_done` on
both — and it cannot also answer "what would survive losing the network". That glyph is
kept **verbatim**, still behind upstream's `timeline.storageIndicator` setting, and the
mirror's axis is drawn under it as **three sections, always in the same place**: the
thumbnail, the preview and the full copy (`OfflineIndex.barOf`). Each is decided on its
own, from its own files, and only its colour ever changes:

| state | when | drawn as |
| --- | --- | --- |
| empty | not wanted, not on the device | nothing |
| waiting | wanted — by a setting or by *Save offline* — not here yet | the dark plate, bare |
| done | here, and a setting maintains it | white on the plate |
| spare | here, and nothing maintains it | amber on the plate |

```
 thumb   preview      full copy
 ██ ▕ ████ ▕ ██████
 2px 1  4px  1   6px     = 14px, the glyph inset a pixel each side
```

| item | mark |
| --- | --- |
| previews selected, all here | white, white, empty |
| previews selected, downloading | white, waiting, empty |
| full quality, the original still to come | white, white, waiting |
| previews selected, a full copy held as a spare | white, white, amber |
| thumbnails selected, a full copy held as a spare | white, amber, amber |
| nothing selected, browsed | amber, amber, empty |
| *Save offline* in progress, nothing selected | amber, waiting, waiting |

**Nothing moves, nothing is rescaled.** The sections are 2, 4 and 6 pixels with a pixel
between each, left-aligned. A bar drawn from figures on one scale — a length for what is
held against a track for what is wanted — makes the same state look different on
different tiles as soon as the track is short, centred or rescaled. Three fixed slots that
only change colour cannot do that, and when every section is filled they read as one
progress bar.
1 : 2 : 3 keeps the order the files cost in and is the smallest split in whole pixels
that leaves the thumbnail visible.

**Each section is its own file**, so a preview that lands before its thumbnail fills its
own slot rather than the first one, and the thumbnail phase of a sync — the queue fetches
every thumbnail in the library before any preview (§3.3) — moves every tile's first slot.
The full copy is a photo's original, plus a Live Photo's motion clip where the rung asks
for videos, or a video's playable file; it waits while any of the files it is fetching is
missing.

**Two rungs decide the colours, because *fetching* and *maintained* come apart.** An
errand widens what the mirror is fetching without changing what any setting maintains,
so folding the two together would draw an incoming spare as library — and then a
cleanup takes it anyway, which is the one thing the colours exist to warn about. They are
the same two rules the rest of the fork applies, which is why they live in the index and
not in the widget: *fetching* is what `filesFor` asks for, errand and camera-roll skip
included, and *maintained* is what `_unselectedOver` counts as not a spare, `on_demand`
included. A second copy of either rule is a second answer waiting to happen.

Nothing is drawn for an item that is neither wanted nor stored. Everything else shows its
waiting sections from the moment it is *decided*: a photo on its way says so, rather than
saying nothing until it arrives and then everything at once. That costs the decision
paths a revision bump — the badge redraws on that alone, so `_applyPolicy` deciding a new
photo has to announce itself even though no file has moved.

**An empty full-copy slot means the mirror will fetch nothing beyond the preview.** That
happens two ways and looks the same for both, because the consequence is: either the
rung asks for no more, or the camera roll already holds the original and fetching it
would store the photo twice (§3.2). The second is `localCopyUsable`, the same predicate
the download side uses, so the mark and the fetching cannot disagree. *Save offline*
overrides it — it asks for this app's own copy whatever the camera roll holds — so while
an errand is outstanding the slot waits, and what lands is amber.

**And that second fact cannot be read off the asset the tile is drawing.**
`BaseAsset.hasLocal` is `localId != null`, which says as much about the query that built
the tile as about the device: `_getPlaceBucketAssets`, `_getMapBucketAssets` and
`_getRemoteAssets` build their rows with a plain `toDto()`, so on those screens it reads
false for a photo the phone certainly has, and every deduplicated item wears a
full-copy slot that waits for ever.

Nor can it be used as a *hint* alongside the mirror's own answer. Taking either — the
obvious repair — holds the stale answer after a local copy is deleted, because
`localId == null` cannot be told apart from "this query does not populate it", so the
fallback never stops applying and the bar only corrects itself on the next launch. So there is one source: `localCopyOf`, which the index reads from the same `EXISTS`
against the camera roll that the download side and the reclaim bands use (§3.2). The mark
can then be wrong only in the way the downloader is wrong, which is the property it exists
to expose. A flip is the one thing that changes what a badge draws with no file arriving
or leaving, so a camera-roll write bumps the revision the badge watches — otherwise the
value is right and the tile still shows the old one.

**A spare is a different kind of thing, so it gets a different channel — two of them.**
Those items are exactly where the grid invites an action: *Save offline* is still
offered on a photo the camera roll holds, because the camera roll is the thing that can
vanish, and what arrives is a spare that nothing maintains. Drawing it in white would
claim a setting maintains it, and a *dimmer* white — the obvious way to say "extra" — is
unreadable, because brightness is already how "not downloaded yet" is drawn, and telling
0.6 alpha from 0.4 across two tiles of a scrolling grid, one pixel tall, over
photographs, is not something anyone can do. So a spare is a different **hue**, amber, in
whichever section holds it. A section is amber if anything it holds is a spare, so a
Live Photo whose motion clip outlived the videos rung reads amber in its full-copy
section even though its original is library.

**Not two marks, and not a glyph pair.** One mark per direction reads badly: a
backed-up, fully mirrored photo wears two clouds on every tile in the library, and a
downward mark that short-circuits on the presence of a camera-roll copy never changes
when the selection does. Two levels inside a single glyph is no better, whichever pair
is chosen — filled against outlined discs, a ring against a dot, one tick against two,
an arrow against a tick — because every one of them asks the eye to read *inside* nine
pixels on top of a photograph. Three slots under the glyph ask only which are lit, and in
what colour.

**A hairline cannot wear the glyph's halo, so it gets a plate.** A `BoxShadow` blurs the
shape behind it, and a one-pixel-tall shape blurred over five pixels has almost no peak
opacity left: the glyph survives a bright photograph on that shadow because it is sixteen
pixels of real strokes, and the bar simply did not — white on white, invisible. So the
bar sits on a dark rounded plate a couple of pixels taller than itself, opaque enough to
read against white, and the plate doubles as the "still to come" segment: **what is
coming is the plate showing through**. That needs no colour of its own and works on a
bright photograph and a dark one alike, where a faint *white* segment had exactly the same
problem as the bar. The amber is the icon's own accent (§4.1), so the one colour the app
introduces here is a colour it already owns.

**Two actions, because they are two promises.** Upstream's Download exports to the
photo library — visible to other apps, survives uninstalling, subject to iOS
offloading and free-up-space. "Save offline" puts a copy in app storage the OS
cannot purge. Both appear, side by side in every selection sheet that offers
Download and in the viewer's ⋮ menu; neither is renamed. The one place it is not
offered is the locked folder, whose assets are never stored (§3.2.1).

Whatever the ladder says, this fetches an item **whole** — thumbnail, preview,
and the original or the playable file. It is about these items rather than a
standing preference, so it takes the top rung even for a library kept at
previews. It does not resume a paused download: the want is recorded and arrives
when downloading is resumed, which the action says (see *A pause stays paused*).

**Free up space says what it costs.** Its premise — safe to delete, the server has it —
is true and incomplete: for an item the mirror keeps, deleting the local original
changes nothing visible; for one it does not, the photo silently stops opening
off-grid. The scan result states the counts, computed synchronously from the
availability index. Same shape `alextran1502` describes for deletion sync on #4282:
detect the divergence, show it, let the user decide.

**Counted by what each item is left with, not as one "stays available" figure**, and
that is a consequence of §3.2: the mirror skips an item's full-size copy while the
camera roll holds it, which is precisely the population this screen deletes. So
"stays available offline" was true of photos the store held only a preview of, and
the deletion was the moment the device stopped having a full-size copy of them at
all. The lines say *at full quality*, *as previews only* or *as thumbnails only*, and
only the items that stop opening are in the error colour: the others still show
something, and reserving the colour is what keeps it meaning something.
Both ways out — a higher rung, or *Save offline* — are decisions taken before the
button, which is why they belong here rather than in the confirmation.

**Words name states, not policies.** "Not selected" rather than "don't keep";
"Save offline" rather than "keep offline". A control labelled with a policy
gives no hint of what happens to what already exists, which is how a reader gets
from "don't keep" to "delete 8 GB now".

**An album's neutral option names where the decision comes from: "Use global
settings".** What it lands on depends on a setting further up the screen — with the
library selected, an album nobody has touched is kept anyway — so a label asserting
"not kept" would be false half the time, and any negative label would sit beside the
exclusion with nothing to tell two options apart that both read as no. The subtitle
says the same thing rather than guessing at the outcome: `using global settings`, or
`excluded from offline`.

**"Exclude from offline" is offered only where it overrides something.** With the
library unselected it would be identical to following the global settings, so it is
disabled — except on an album that is already excluded, so switching the library off
cannot leave a row displaying a state its own menu no longer contains.

**The same control in both places.** An album's row on its own Options page and in the
list on the offline screen render through the same helpers, so an identical-looking
control cannot come to mean two different things.

**"Not selected" cannot be a menu value.** `PopupMenuButton` treats a null result as
"dismissed" and calls `onCanceled`, so every option is a non-null enum value that maps
to a quality afterwards.

### 3.7 What the log has to say

The mirror runs unattended for hours, so a problem that leaves no line is a
problem nobody can investigate — and most of it happens where no screen is
looking. The rule is quiet on success, specific on trouble:

- **Every pass says what it did once**: how many missing files it found, how many
  the downloader is holding, how many it has given up on, whether it read the
  whole list, and whether a pause or the limit stopped it.
- **Anything with the downloader for more than fifteen minutes is named** —
  asset, variant, URL, **how far it has got and when it last said so** — with the
  Wi-Fi-only setting beside it, because a task that never reaches a final state
  calls nothing back and otherwise exists only as a number on screen. `(42%, last
  6s ago)` is a slow file; `(nothing reported)` is one the plugin is holding but
  not moving, and the two need different answers.
- **Only the big files report progress** (`Updates.statusAndProgress` for
  full-size copies), which is also what tells a slow download from a dead one. A
  preview reporting its way to 100% would be thousands of callbacks a pass for
  something already over. Every file reports *starting*, which counts as its first
  progress, at 0%. Age is the test rather than "seen twice": two passes
  seconds apart always see the same running video, and saying so each time is the
  noise this section exists to avoid.
- **A download that has not moved is cancelled, not waited on.** One the system
  deferred, or left behind by a replaced build, reports nothing and ends nothing,
  and holds one of the group's slots for good. Cancelling ends it, and since the
  pass that saw it skipped its file as in flight, its cancellation is the one that
  asks for a pass to fetch it again — every other cancellation is the mirror handing
  work back or stopping, and must not.

  What counts as "not moved" depends on whether the task has started. One that has
  is dead after fifteen minutes with nothing from it — no start, no progress — which
  for a thumbnail that started and never finished is simply fifteen minutes. One
  that has not started is, almost always, waiting for a slot: behind eight videos on
  a slow link that can be hours, and counting that against it cancelled everything
  queued behind them, over and over. So an unstarted task is called dead only once
  the whole group has been silent for fifteen minutes — nothing started, moved or
  finished — which is what a deferred or orphaned queue looks like and a busy one
  never does. The warning that names old tasks follows the same rule, so a deep
  window does not fill the log.

  While *Wi-Fi only* is on with no Wi-Fi, the group is silent, so each such pass
  hands the window back and the pass after it asks again. The churn costs nothing
  but log lines, and nothing is downloaded either way.

  **The clock is in the database.** A wedged task outlives the process; an in-memory
  first-seen time does not, so every launch declared the task new and the fifteen
  minutes could only ever elapse within one uninterrupted session. A download stuck
  across restarts therefore survived every restart, holding its slot and its place in
  the count, and the only thing that cleared it was turning downloading off and on.
  What stays in memory is the opposite question — how long *this* process has been
  watching — because the evidence that a task is alive is its progress callbacks, and
  those do not survive a launch either. A task that is old but silent gets two minutes
  to speak up before it is called dead, so relaunching mid-download does not throw the
  hardest work away.
- **Every final state is accounted for.** A cancelled task says so, and a failed
  one names the file and the reason. A **404 is recorded as a failure**, not just
  logged: it is the server's answer, so the same backoff applies and the pass
  stops asking for ever. That is safe to abandon because the thumbhash is *in*
  the name — an asset whose thumbnail the server has not generated yet has no
  thumbhash either, so once it produces one the URL is a different URL, under a
  different name, with no failures against it.
- **Only a failure about the file counts against it** (`classifyOfflineFailure`).
  No network, a 401, a timeout, 429 and the gateway errors say nothing about the
  file and are never recorded — counting them is how an afternoon off-grid used to
  give up on the selection. They hold the queue off instead, for a minute and then
  doubling to half an hour, since every file behind them would fail the same way.
  A 403 and a 500 do count: Immich sends them about one asset, and treating them as
  an outage would let one broken photo stall the queue.
- **A task carrying an old token is handed back.** The token is fixed into a task's
  headers when it is queued, and the downloader's queue outlives the process, so a
  pass cancels whatever still presents the previous sign-in and queues it again.
- **A degraded read says what it costs.** An unreadable selection means nothing is
  selected, and a file that cannot be claimed off disk will be downloaded again — each of
  those is a warning naming the consequence, not the exception alone.
- **Isolates count rather than log**, since the log listener lives in the main
  isolate: the integrity pass and the batch delete return what they could not
  read and could not remove, and the caller reports it. A deletion that did not
  take makes the figure quoted to the user wrong, which is worth a line.

What is *not* logged: anything that happens per file on the way to success. Six
figures of downloads cannot each afford a line.

## 4. Map of the change

Everything fork-specific that *can* live in a new file, does — filed by role,
in upstream's own directories (§5 rule 1). Every one of them is new, so none of
them can conflict.

**New files** (no rebase conflicts, ever):

| Path | Role |
| --- | --- |
| `mobile/FORK.md` | This document |
| `ios/Runner/Images/OfflineStore.swift` | The blob store on iOS: read, write-through, index, and reports to Dart; it deletes nothing (§3.4) |
| `android/.../images/OfflineStore.kt` | The same store on Android, and the same names (§3.4, §3.4.3) |
| `android/.../images/OfflineStoreNamingTest.kt` | That those names match the Dart ones, literal for literal (§3.4.3) |
| `tools/build_android.sh` | The Android release build, into `dist_android/` |
| `lib/providers/session_state.provider.dart` | Connectivity-aware session state (§3.5) |
| `lib/infrastructure/repositories/offline_flags.repository.dart` | What is wanted, what is held, and what was asked for by hand (§3.2, §3.3) |
| `lib/domain/utils/offline_index.dart` | The in-memory availability index (§3.4.2) |
| `lib/domain/models/offline/offline_policy.model.dart` | What happens to items that arrive later (§3.2) |
| `lib/domain/models/offline/offline.model.dart` | The rows and figures the store is described by |
| `lib/utils/offline_reclaim.dart` | The integrity pass, on its own isolate (§3.3) |
| `lib/infrastructure/repositories/offline.repository.dart` | The upstream-database queries the reconciler needs |
| `lib/utils/offline_paths.dart` | Naming, shared with Swift (§3.4) |
| `lib/domain/services/offline_sync.service.dart` | The reconciler: the three passes and the selection (§3.3) |
| `lib/domain/utils/offline_queue.dart` | What to fetch next, and how many at once (§3.3) |
| `lib/infrastructure/repositories/offline_download.repository.dart` | `background_downloader`, for the mirror's own group |
| `lib/providers/infrastructure/offline.provider.dart` | Providers |
| `lib/presentation/pages/offline_sync.page.dart` | The offline copies screen |
| `lib/presentation/pages/offline_albums.page.dart` | Which albums are kept offline, shaped after upstream's picker (§3.6) |
| `lib/presentation/widgets/offline/quality_menu.widget.dart` | The selection controls, shared by the screen and albums (§3.6) |
| `lib/presentation/widgets/offline/offline_cleanup_sheet.dart` | Where space is taken back: two bands × four kinds (§3.6) |
| `lib/presentation/widgets/offline/offline_reclaim_dialog.dart` | The confirmations behind it, and the album row note (§3.6) |
| `lib/presentation/widgets/offline/offline_album_tile.widget.dart` | "Available offline" on an album (§3.6) |
| `lib/presentation/actions/keep_offline.action.dart` | "Save offline" / "Remove offline" on a selection (§3.6) |
| `lib/presentation/widgets/offline/offline_badge.widget.dart` | The tile's cloud and its meter (§3.6) |
| `lib/presentation/widgets/offline/offline_indicator.widget.dart` | The app bar's offline button and its badge (§3.6) |
| `lib/presentation/widgets/offline/offline_cleanup_note.widget.dart` | What free-up-space costs offline (§3.6) |
| `test/utils/offline_paths_test.dart` | The names Swift has to reproduce (§3.4) |
| `test/domain/models/offline_policy_test.dart` | The ladder, and what each rung asks for (§3.2) |
| `test/domain/utils/offline_queue_test.dart` | The order a half-finished mirror fills in (§3.3) |
| `test/infrastructure/repositories/offline_download_failure_test.dart` | Which failed downloads count against their file (§3.3) |
| `test/domain/utils/offline_index_test.dart` | What the badge says, and what progress counts (§3.4.2) |
| `test/medium/repositories/offline_repository_test.dart` | What may be stored, and what the camera roll makes redundant (§3.2, §3.2.1) |
| `test/medium/repositories/offline_flags_repository_test.dart` | The derive, the reclaim bands and eviction, against a real database (§3.2, §3.4.1, §3.6) |
| `test/presentation/widgets/offline/offline_badge_test.dart` | That the tile bar's three sections keep their place and width in every state (§3.6) |
| `lib/widgets/common/sign_out_dialog.dart` | Sign-out, with the downloads spelled out (R2) |

**Modified upstream files** — each tagged with an `// immich-sync fork` comment.
Every one is a hook or an addition; none removes an upstream feature (R5).

| Path | Edit |
| --- | --- |
| `ios/Runner/Images/RemoteImagesImpl.swift` | Read the store before the network, and keep what it fetches (§3.4) |
| `android/.../images/RemoteImagesImpl.kt` | The same, in `ImageFetcherManager.fetch` (§3.4) |
| `ios/Runner/Core/URLSessionManager.swift` | URLCache down from 1 GB to 64 MB; the store holds image bytes now (§3.4) |
| `ios/Runner/AppDelegate.swift` | Prepare the store and its channel (§3.4) |
| `lib/routing/auth_guard.dart` | Report instead of redirect + wipe (R2) |
| `lib/routing/router.dart` | Wire the callbacks; register the route |
| `lib/pages/common/splash_screen.page.dart` | Report instead of logging out; reconcile after sync |
| `lib/providers/app_life_cycle.provider.dart` | Same, on resume |
| `lib/domain/utils/background_sync.dart` | One added callback, fired by every path that applies server state (§3.3) |
| `lib/providers/background_sync.provider.dart` | Wire it to a coalesced `check` |
| `lib/utils/image_url_builder.dart` | One optional cache buster on `/original` (§3.4) |
| `lib/presentation/widgets/images/image_provider.dart` | Pass `isEdited` through, which decides that buster |
| `lib/presentation/pages/edit/edit.page.dart` | A failed save reports the server's reason, like every other action |
| `lib/pages/common/settings.page.dart` | One added entry for the offline screen |
| `lib/widgets/common/app_bar_dialog/app_bar_dialog.dart` | One added entry; fork sign-out dialog (R2) |
| `lib/widgets/settings/free_up_space_settings.dart` | One added line: what the deletion costs offline (§3.6) |
| `lib/infrastructure/repositories/local_asset.repository.dart` | Cleanup candidates carry the server id the join already has |
| `lib/presentation/pages/album_options.page.dart` | One added row: available offline (§3.6) |
| `lib/utils/action_button.utils.dart` | One added action type, three small hunks (§3.6) |
| `lib/presentation/widgets/bottom_sheet/*_bottom_sheet.widget.dart` | One added action beside Download, in each sheet that offers it (§3.6) |
| `lib/widgets/common/immich_sliver_app_bar.dart` | One added button and its own `showOfflineButton` gate (§3.6) |
| `lib/presentation/widgets/images/thumbnail_tile.widget.dart` | Upstream's cloud wrapped with the mirror's meter (§3.6) |
| `lib/presentation/pages/asset_troubleshoot.page.dart` | Five rows of the mirror's own view of an asset, behind upstream's *Advanced troubleshooting* flag: what the badge and the download rules each decided, in one place |
| `lib/presentation/widgets/images/remote_image_provider.dart` | Show a stored original even with `loadOriginal` off |
| `lib/presentation/widgets/asset_viewer/video_viewer.widget.dart` | Play stored videos from disk |
| `lib/repositories/asset_media.repository.dart` | Share a stored copy instead of re-downloading |
| `lib/services/api.service.dart` | Re-seed the auth cookie from the stored token |
| `lib/data/data_controller.dart` | Attach the fork database where upstream opens its own, and create its tables before the store is read |
| `lib/main.dart` | Track downloader tasks per group, not globally; downloader concurrency `(16, 16, 8)` instead of `(6, 6, 3)` (§3.3) |
| `lib/domain/models/settings_key.dart`, `config/app_config.dart` | Four settings keys: the selection, Wi-Fi only, pause, and the storage limit |

There is no fork-flag switchboard. A single always-true `bool` reads as something
configurable, and the `// immich-sync fork` comment already says what a conflict
hunk needs to know.

### 4.1 Identity: the app is called Mirrich

Distinct branding is not vanity here — the fork is built from a codebase whose
upstream is widely installed, and telling the two apart on a home screen matters.
It also keeps the door open to App Store distribution, which using the Immich
name and mark would not.

**The name.** "Mirrich" is *mirror* and *Immich* run together — it keeps the shape
and the cadence of the name it came from, so the lineage is legible, and it says what
the fork is: a faithful local copy of an original (§1). Everything the app *shows*
reads it from `kAppName` in `constants.dart`; the store paths, the fork database, the
platform channel and `CFBundleDisplayName` spell it out, and those cannot move
without a re-download or a reinstall.

**The icon.** Five blades echo Immich's aperture mark, so the lineage stays
legible to anyone who knows both. Three things then make it unmistakably a
different app at a glance:

- a single warm amber, against Immich's five colours
- near-black ground, against Immich's white
- a **shut** iris, against Immich's open one — an image held, not streamed

The opening is a pinhole rather than nothing: a fully sealed iris reads as a
pinwheel, and anything wider loses the "closed" idea that carries the meaning.

The artwork is **generated, not drawn**, all of it from one description of the
mark. `tools/make_icon.py` is the source of truth; the geometry is three
constants at the top (`R_IN` aperture, `TWIST` spiral, `GAP` seam). It emits two
shapes: the *icon*, the mark on its near-black tile with no alpha channel because
iOS requires that, and the *mark* alone on transparency for the launch screen, the
app bar and anywhere the app draws its own logo.

```
python3 tools/make_icon.py /tmp/icons 1024 180 …   # icon tiles
python3 tools/make_icon.py --brand                 # every branded asset, in place
```

`--brand` writes the mark, the launch images at the three iOS scales, the launch
grounds (warm off-white in light mode, the icon's own near-black in dark) and the
wordmark, which is set in Overpass Bold — a face the app already bundles, so the
type on the splash screen is the type in the app. Never hand-edit any of it:
change the script and re-run, or the thirty-odd files drift out of step.

**The launch screen's generated assets are committed.** `flutter_native_splash`
regenerates them from `flutter_native_splash.yaml`, but a checkout builds
correctly without anyone running it; re-run `mise //mobile:codegen:splash` after
changing the config.

**The product's name in translated strings is substituted, not translated.**
Many of upstream's strings name the product, in forty-nine languages. Editing
them would fork the translation catalogue and conflict on every upstream string
change, so `BrandTranslationLoader` wraps upstream's generated loader and renames
the product as the strings enter the app (`kAppName` in `constants.dart`). One
hook, no i18n diff, and strings added later are covered without anyone
remembering to. The exception is a string whose "Immich" is the *server* — "still
available on the Immich server" — which keeps its name: those keys are listed in
`kServerNamingKeys`, and a test fails if one of them disappears upstream. A new
upstream string that names the server has to be added there.

| Path | Role |
| --- | --- |
| `README.md` | The fork's own front page, replacing upstream's outright — the one file outside `mobile/` this fork owns, and the one place a rebase conflict is resolved by taking ours whole |
| `mobile/BUILDING.md` | How to build, sign and install (new file) |
| `tools/build_release.sh` | Release pipeline: unsigned for AltStore, signed for TestFlight (new file) |
| `tools/make_icon.py` | Artwork generator, source of truth (new file) |
| `lib/utils/brand_translation_loader.dart` | Renames the product in every translated string except those naming the server (new file) |
| `assets/mirrich-logo{,-inline-dark,-inline-light}.svg`, `assets/mirrich-logo.png` | The mark, in-app and in the app bar (new files) |
| `assets/mirrich-splash.png`, `assets/mirrich-splash-android12.png` | Launch-screen sources (new files) |
| `assets/mirrich-text-{dark,light}.png` | Wordmark, tinted by the theme (new files) |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/` | 34 regenerated PNGs |
| `ios/Runner/Assets.xcassets/LaunchImage.imageset/` | 3 regenerated PNGs |
| `ios/Runner/Assets.xcassets/LaunchBackground.imageset/` | 2 regenerated 1×1 grounds |
| `ios/Runner/Info.plist` | `CFBundleDisplayName` → literal `Mirrich`; the two version keys → `$(FLUTTER_BUILD_NAME)`/`$(FLUTTER_BUILD_NUMBER)`; the background-task ids → `$(PRODUCT_BUNDLE_IDENTIFIER)` |
| `flutter_native_splash.yaml` | Launch-screen sources and grounds |
| `android/app/build.gradle` | The launcher label, the `app_name` resource upstream's manifest reads |
| `android/app/src/main/AndroidManifest.xml` | Share-sheet and open-with labels |
| `lib/constants/constants.dart` | `kAppName`, `kUpstreamName` |
| `lib/main.dart` | `MaterialApp.router(title:)`, the translation loader |
| `lib/pages/common/splash_screen.page.dart` | Title, logo asset, the translation loader |
| `lib/services/localization.service.dart` | The translation loader, for the background worker's isolate |
| `lib/widgets/common/immich_logo.dart` | Mark asset |
| `lib/widgets/common/immich_title_text.dart` | Wordmark asset |
| `lib/widgets/common/immich_sliver_app_bar.dart` | App-bar mark asset |
| `lib/widgets/common/app_bar_dialog/app_bar_dialog.dart` | Wordmark asset |
| `lib/widgets/common/app_bar_dialog/app_bar_profile_info.dart` | Mark asset |
| `ios/Runner.xcodeproj/project.pbxproj` | Registers `OfflineStore.swift` in the Runner target |

The bundle ID lives in `ios/Signing.local.xcconfig`, which is gitignored and so
is not part of the fork at all. See `BUILDING.md` §3 — and note that the choice
is effectively permanent, since changing it makes iOS treat the build as a
different app and re-download everything.

## 5. Rules for future changes

These keep rebases tidy, which matters more here than usual: the aim is to track
upstream indefinitely and to stay close enough that this could still be offered
(§1.1).

1. **New behaviour goes in a new file, placed where upstream would have placed
   it** — a model under `domain/models/`, a service under `domain/services/`, a
   repository under `infrastructure/repositories/`, a widget under
   `presentation/widgets/<feature>/` — or in a new Swift file. Upstream files get
   a hook, never fork logic and never a deletion.

   A new file never conflicts on a rebase whatever directory it sits in, so
   there is nothing to buy by quarantining this work in a folder of its own, and
   plenty to lose: a reviewer, and a future rebase, meet code that does not look
   like the code around it. `grep -rn "immich-sync fork"` is what finds the
   hooks; the layering is upstream's.
2. **Tag every upstream edit** `// immich-sync fork`, with the requirement number
   when one applies. When a rebase conflicts, the intent is then legible from the
   conflict hunk alone.
3. **Never add a drift table or bump `schemaVersion`.** Upstream changes the
   schema often; a fork-owned migration would conflict on nearly every rebase.
   Policy is a settings value, and everything per-asset — what is wanted and what
   is held — lives in a database of the fork's own (§3.2.1), for exactly this
   reason.
4. **Never modify anything under `mobile/pigeon/`.** Pigeon regenerates into
   upstream-owned files.
5. **Do not touch `server/`, `web/`, `machine-learning/`, `e2e/`.** Keeping them
   pristine means a rebase only ever conflicts in `mobile/` and in `README.md`,
   which is the fork's front page and is always resolved by taking ours whole.
6. **Never remove or repoint an upstream feature** (R5). Add beside it. There is no
   exception, the tile badge included: its glyph and all three of its states are kept
   verbatim, behind upstream's own setting, and the mirror's axis is drawn under them
   rather than in place of them (§3.6).
7. **Always keep our branding on a rebase conflict.** Upstream periodically
   refreshes its own icons and `Info.plist`. Take ours every time; regenerate
   rather than resolve the PNGs by hand. The version keys in `Info.plist` are
   ours for the same reason: upstream bumps literals there with fastlane, and the
   fork asks Xcode for whatever number the build was given, which is what lets one
   timestamp serve both distribution routes with nothing to edit by hand.

### Rebasing onto upstream

```bash
git fetch upstream
git rebase upstream/main
```

`upstream` is `immich-app/immich`; `origin` is this fork.

Conflicts should be confined to the files tabled in §4 and §4.1. After a rebase,
re-verify by hand:

- `grep -rn "immich-sync fork" mobile/` finds every hook.
- No `clearLocalData` or `LoginRoute` on an automatic path (R2).
- Upstream's own features still work: backup, free up space, "On this device",
  the camera-roll Download action, the app-bar backup button (R5). A rebase that
  drops one of the *additions* beside them is easy to miss — the offline entry in
  Settings and the profile dialog, the album row, the `keepOffline` action type,
  the offline line in the cleanup summary.
- `lib/main.dart` is **CRLF** upstream. Writing it back as LF turns a 20-line diff
  into a whole-file rewrite and guarantees a conflict there forever.
- **The fork's tables are still attached, on every connection.** `ImmichSqliteOpenFactory`
  carries the attachment through its pragma list (`data/db/main/database.dart`), and a read
  connection that missed it fails every statement naming the other schema. The startup
  guard in `ensureSchema` covers the other half: if upstream has grown a table called
  `wanted`, `held`, `failures` or `meta`, unqualified names in the fork's SQL would
  silently start reading it, so the app refuses to start instead (§3.2.1).
- **The fork's file is in WAL mode.** An ATTACH does not inherit upstream's `journal_mode`, so
  `OfflineFlagsRepository.ensureSchema` sets it on the `offline` schema once per launch, outside its
  transaction. Without it, readers of `wanted`/`held` and the writer block each other (§3.2.1).
- **Nothing upstream knows has been copied onto a `wanted` row.** What an item is, whether
  it is a Live Photo, whether it has been edited, and whether the camera roll holds it are
  all joined. A rebase that reintroduces one of those as a column reintroduces the fault
  that made the mirror fetch full-size copies of photos already on the phone (§3.2.1).
- `getThumbnailUrlForRemoteId` still builds the URLs the reconciler stores, and
  `video_viewer.widget.dart` still builds the URL the reconciler stores for
  videos (§3.4).
- `offlineBlobName` in Dart and `fileName(for:)` in Swift still agree, down to
  which accessors are decoded, how each collapses a repeated query key, and that
  both order the query by UTF-8 bytes rather than by their language's own string
  comparison (§3.4). `test/utils/offline_paths_test.dart` pins the Dart half to
  literal names; when one of those has to change, the Swift half changes in the
  same commit — and every user re-downloads their library under the new names.
- The **background-task ids** in `Info.plist` still read `$(PRODUCT_BUNDLE_IDENTIFIER).background.*`.
  Upstream reads them out of the plist and matches by suffix
  (`BackgroundWorkerApiImpl.swift`), so leaving upstream's literals there
  registers the fork's background work under *their* identifier prefix and
  nothing complains. The variable keeps it correct for whatever bundle id the
  build carries, without putting anyone's own id in a public fork.
- `main.dart` still configures the holding queue as `(16, 16, 8)`. A conflict there
  resolved by taking upstream's `(6, 6, 3)` compiles, runs, and quietly makes a large
  mirror several times slower (§3.3).
- `main.dart` still tracks every downloader group the app uses. Upstream's
  `trackTasks()` is replaced by a list of groups (the mirror enqueues six figures
  of tasks and reads none of their records back, so tracking them globally meant
  a database write and a delete per blob). A group upstream *adds* is not in that
  list, and nothing fails loudly — its records simply stop being kept.
- Eviction still asks `_unselectedOver` for its candidates and still skips items
  with an outstanding errand, and the integrity pass still refuses an oversized
  sweep. All three fail silently: the first two as a library or a save evicted
  without anyone tapping anything, the last as a library deleted by a pass that was
  asked the wrong question (§3.4.1, §3.3).
- The native store still deletes nothing. A trimmer on that side would have to
  answer "is this a spare?" without the database (§3.1.2).
- The tile's bar still reads from the availability index synchronously, and `barOf`
  still decides each section from two rungs, *fetching* and *maintained*, against what
  is held. Folding fetching into maintained draws an incoming spare as library, and
  deciding from what is held alone loses "not fetched yet". A spare is still amber:
  re-drawing it as a dimmer white puts it back into the one channel "not downloaded
  yet" already uses (§3.6).
- The image path still reports only to the channel whose Dart side called `listen`.
  `registerPlugins` runs for the background worker's engine too, and reporting to the
  last registration loses every report after a background run (§3.1.2).
- Every decision path still bumps the badge's revision. The badge redraws on that alone,
  so a path that records a decision without it leaves a tile blank until the first file
  lands — which reads as the app noticing nothing until it is suddenly finished (§3.6).
- A pass is still asked for by a **write**, and every path that asks for one still marks
  the flag as well. Both halves are load-bearing: gating on what the data looks like
  cannot see a row change in place, and a pass that is asked for but then decides nothing
  changed is the same as no pass at all (§3.2).
- Re-deriving is still **total**, and `derive` is still checked against
  `OfflinePolicy.resolve` case by case. The moment one of them is narrowed to "only what
  changed", the mechanisms that decide what changed come back — and each of those was a
  way for a change to be missed (§3.2).
- The mirror still gives way to the backup's **activity** and never to its backlog,
  and still only for `_maxYield`. Either half of that, removed, turns one photo that
  cannot upload into a mirror that never downloads again — and the pass line still
  prints `stoppedBecause`, which is the only thing that made that visible (§3.3).
- A full-size copy of an item the camera roll holds is still a **spare** at every rung,
  and the answer is still **asked** rather than stored. A column caching it is how the
  mirror came to fetch full-size copies of photos already on the phone and then draw them
  as library; nothing about the camera roll, the asset's type or its edited state may be
  copied onto a `wanted` row again (§3.2, §3.2.1).
- The integrity pass still refuses to delete on the strength of the selection, and
  `freeUpSpace` is still the only path that removes a file a selection stopped
  covering. Collapsing those two back together is how one mistap comes to cost hours
  of re-downloading (§3.2, §3.3).
- The recorded video form still reaches the pass, so a flipped `loadOriginalVideo`
  beats the weekly interval instead of leaving two generations of every video on the
  device (§3.3).
- `filesFor` still asks for a playable file only at the top rung, and the queue is
  still ordered by `touched_at` and then `OfflineVariant.fetchOrder`. Both fail
  quietly: the first as a phone that fills with videos nobody asked for, the second
  as a week of downloading before the grid is browsable (§3.2, §3.3).
- The app is still called Mirrich and still carries the amber icon (§4.1).
- **The blob name still matches on all three sides.** `offline_paths.dart`,
  `OfflineStore.swift` and `OfflineStore.kt` derive it independently, and a
  divergence is invisible — the mirror simply stops being read from. Run
  `./gradlew :app:testDebugUnitTest --tests '*OfflineStoreNamingTest*'` beside the
  Dart test whenever any of the three moves (§3.4.3).
- `OfflineStore.swift` is still in the Runner target's *Compile Sources*. A
  rebase that takes upstream's `project.pbxproj` silently drops it, and the
  offline library stops existing — see `BUILDING.md` §3.4.

## 6. Known limitations

- **The store is large by design.** Thumbnail + preview + original is roughly 10×
  preview-only, and adding videos can multiply it again. Choose "previews" per
  album or as the default to fall back to previews, which still look correct
  full-screen on a phone, or set a ceiling under Storage (§3.4.1) — it evicts
  spares and then stops downloading, and never deletes the library.
- **Free space is read, not reserved.** The floor is checked before each eviction
  and each pass, so another app filling the disk between two of them is noticed
  at the next one, not the moment it happens.
- **A video is stored whole or not at all.** There is no middle rung for one,
  because the server has no smaller flavour to offer: below "full quality +
  videos" a video keeps its still and plays only with a network. If a smaller
  flavour ever exists it slots in as an `OfflineVideoTier` and a rung (§3.2), and
  nothing else in the model changes.
- **Space is reclaimed automatically only under pressure.** Deselecting keeps the
  bytes as spares, so toggling around accumulates until the store reaches its
  ceiling or "free up space" is pressed. The figure sits on the screen
  whenever it is non-zero, and an album's page reports its own. Making it automatic
  would put a mistap back in the business of costing hours of re-downloading, so if it
  is ever added it has to be opt-in.
- **A camera-roll copy that iOS has offloaded is trusted anyway.** The mirror skips
  an item's expensive half while the phone holds it (§3.2), and `hasLocal` does not
  say whether the bytes are resident: with *Optimise iPhone Storage* on, iOS can
  replace the original with a placeholder that itself needs the network. Upstream's
  own image path prefers that local asset in exactly the same way, so nothing is
  more wrong than the render is — but the mirror is what promised the photo would
  open off-grid. Telling them apart needs a `PHAsset` residency check. Until then,
  *Save offline* on those items fetches the app's own copy regardless, which is the
  way out that exists today.
- **Flipping "load original videos" takes every video offline until it is
  re-fetched.** It changes which file the player asks for, so every stored video
  is superseded at once: the old one is deleted on the next pass and the new one
  queued behind whatever else is waiting. The setting reads as a playback
  preference and costs a re-download of every video, which is not obvious from the
  switch.
- **Endpoint subpaths matter.** Names ignore scheme and host but include the
  path, so serving the same library from `https://a/api` and `https://b/immich/api`
  would store it twice.
- **The bytes of a server-side deletion linger until the next integrity pass**,
  which is weekly — see §3.3. The photo stops being listed as soon as the metadata
  sync learns of it, and the decision that asked for it is forgotten by the next
  `sync` that reads the whole list, so the progress figures settle within minutes.
  Only the files wait: telling a photo the server has forgotten from one sitting in
  the trash is safe to decide against `wanted`, but deleting on the strength of it
  is not (§3.3).
- **A trashed photo holds the progress figures short of complete** until the
  trash empties. Its files are swept as soon as it stops being storable, but the
  decision stays — restoring it has to bring the offline copy back — so the
  mirror reads as a few files behind for as long as the photo is in there.
- **Eight downloads at a time, and the setting is shared with uploads.** `main.dart`
  configures the downloader's holding queue globally as `(16, 16, 8)`, up from
  upstream's `(6, 6, 3)`. The plugin has one per-group number for every group, so
  raising it for the mirror raises upstream's backup to eight concurrent uploads as
  well. Mirroring a large library still takes hours, and the per-file cost of a
  `background_downloader` task, not bandwidth, is what sets the pace for small files.
- **Only the queued batch survives the app being killed.** `background_downloader`
  keeps its own tasks running in the background, but the remainder of a pass is
  held in memory; it resumes on the next reconcile (app resume, cold start, or
  the button), not by itself.
- **A permanently failing download leaves the mirror one file short.** An asset
  the server cannot produce a preview for (a 404 or a 500 about that file — not a
  network or session failure, which never count) is tried three times and then left
  alone, so it never converges to "complete". It is counted on the summary line
  with a button to try again, since the alternative — retrying forever — is worse.
- **Fork UI strings are English-only.** The offline screen does not go through
  upstream's i18n pipeline — adding keys would touch `i18n/en.json` and the
  generated translations, growing the rebase surface for one fork-only screen.
- **A session problem is stated in two places and neither is loud.** A rejected
  token badges the app bar's offline button and explains itself on the offline copies
  screen (§3.5), and that is all: the timeline and everything stored keep working,
  which is the point (R2), so a user who reads neither is not told. A banner would be
  a standing interruption for a condition that costs nothing until the next download,
  which is why the mark sits on the entry point instead.
- **A photo's `/original` is named `.mp4`.** The naming rule marks a URL playable
  when its last path segment is `original`, which is how a video stored at the top
  of the `loadOriginalVideo` switch gets the extension AVFoundation needs — and it
  catches an image's `/original` as well. Harmless: the two never collide (different
  ids, and different query tokens), nothing reads the extension on the image path,
  and Swift agrees with Dart exactly. Not corrected, because the name *is* the
  identity: narrowing the rule would rename every full-size photo in every store
  and re-download the lot (§3.4).
