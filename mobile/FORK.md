# immich-sync — fork requirements and design

This repository is a fork of [Immich](https://github.com/immich-app/immich). Only
the **iOS mobile app** (`mobile/`) is modified; the server, web and ML components
are untouched and track upstream exactly.

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
and trims the opportunistic region in insertion order precisely so that reading a
blob never writes one.

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

Bytes leave the device for exactly two reasons, both of them decisions:

1. the user said this photo is no longer wanted — by a button, or by a bulk
   action that included it;
2. the user pressed "Remove all downloads".

Nothing opportunistic, automatic or defensive may remove anything. Specifically
**not** acceptable as a store: anything the OS may purge under storage pressure
(`Caches/`, `tmp/`), or anything with a size cap and an eviction policy.

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

There are four, and each is an absent session or an explicit choice. A rejected
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
| People / faces browsing | `DriftPeopleRepository` | works |
| Places | drift, from synced EXIF | works |
| Memories | `driftMemoryFutureProvider` | works |
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

### 3.1.2 Two regions, one index

`pinned/` is the library and nothing evicts it; `cache/` is whatever was looked at
and the native side trims it to a byte budget. The reconciler renames out of the
second into the first rather than downloading bytes the app already fetched.

The native lookup index covers **both** regions, which makes two rules
load-bearing:

- **Trimming the cache may not drop a name the pinned region still holds.** Both
  copies exist whenever a download lands in `pinned/` after the name was cached —
  the reconciler writes there directly, without passing through the native
  `store()` and its existence check. Dropping the hash tells `mightHold` that a
  mirrored photo is absent, and the image path goes to the network for a file that
  is on disk: invisible until the user is offline.
- **Removing a photo removes both copies.** Otherwise freeing up space leaves it
  rendering from `cache/` until something happens to evict it.

Bytes Dart moves between regions are reported over the channel (`notePromoted`),
since a rename it performs itself is invisible natively. Trimming only deducts
bytes a delete actually returned; deducting on a failure lets the loop decide it is
under budget with the files still there.

**A count of files is filtered to what is wanted; a total of bytes is not.**
Progress is measured against what the decisions imply, so a file nothing wants is
not progress towards anything. Storage is what the device gave up, so that same
file counts against it. `heldTotals()` and `OfflineIndex` split it the same way, or
the figures move every time the index reloads.

### 3.2 Selecting and storing are separate

The design turns on one distinction: **selecting decides what the app maintains;
storage is what is on the phone.** Selecting more downloads. Selecting less only
stops maintaining. Bytes leave the device for exactly one reason — an explicit
"free up space" — and that is what makes every row on the screen safe to mistap.

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
   **included** album. Quality is a ladder, none ⊂ previews ⊂ full quality ⊂ full
   quality + videos, so combining is a maximum;
3. **items fetched on demand** are not a selection at all — see below.

#### One ladder, four rungs, and videos on top

Quality is deliberately **one dimension**. "Videos as well" as a second axis — a
checkbox beside the rung — would be a setting whose meaning depends on the setting
next to it, and it would have to be carried, explained and stored twice on every
row, every album, every figure and every predicate. So it is a rung instead:

| Rung | Thumbnail + preview | Photo's original | Video's playable file |
| --- | --- | --- | --- |
| Not selected | — | — | — |
| Previews | ✓ | — | — |
| Full quality | ✓ | ✓ | — |
| Full quality + videos | ✓ | ✓ | ✓ |

Videos sit at the top because a video is stored whole or not at all. There is no
preview tier for one — the server produces a playback file and nothing smaller —
so it is the only thing on the screen that can multiply the size of the store,
often a hundred times its own preview. Wanting a library of previews is almost
never wanting a library of videos, and the phone that mirrors a library is
usually the device with the least room.

Below the top rung a video keeps its thumbnail and preview like everything else,
which is its **still**: it appears in the grid, it opens off-grid, and it plays
when there is a network — exactly what the previews rung promises for a photo.
That is why `OfflineAvailability` has three values and none of them names a media
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
lists them, nothing re-downloads them if they go, and a cleanup can take them
like any other spare. Saying so at the moment of saving is what stops the storage
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
errand's place in the queue is a mark of its own (`errands`, §3.3) rather than a
reading of `on_demand`. That column is false whenever a selection also covers the
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
a marked item, and `barOf` draws a track to it. One constant, three readers, no column
doing two jobs.

#### `wanted` is a projection

`wanted` holds one row per selected asset and is *derived*: `applyPolicy` re-computes
it and drops rows the selection no longer covers, cheaply and without touching a
file. On-demand rows survive that, being a cache rather than a stale projection.
Nothing about a policy change reaches the filesystem.

Only what moved is re-derived. Changing one album's setting can only change the
outcome inside that album, so the walk is restricted to it; the whole library is
walked only when the library row itself moves. And a selection a later tap has
already replaced does not walk at all, because flicking a menu back and forth
otherwise queues one pass per tap and the screen waits for all of them.

What such a pass **must not** drop is its *scope*. The albums it was going to
re-derive are merged into the pass that replaces it, and the last pass takes the
union; a pass that fails hands its scope back the same way, and `check` retries
it. Losing a scope loses the change outright — two quick taps on different albums
would record both selections and re-derive only the second, leaving the first
showing a quality nothing was ever marked wanted at — and nothing would ever
notice, since policy only looks at assets that are *new*.

#### A watermark cannot be the only way new photos are found

Applying policy to "anything new" means walking assets by upstream's `updatedAt`, past
a watermark. That is cheap and it is not sufficient, for a reason that is easy to miss
and produces the worst symptom the mirror has: **`updatedAt` is the server's clock, and
upstream syncs by a cursor of its own.** Rows therefore do not arrive in `updatedAt`
order, and one that lands *below* the high-water mark is past the walk for ever. A photo
taken and uploaded a moment ago is simply never kept — no bar on its tile, no line in the
log, and the only cure is switching the whole library off and on again, because that runs
a derivation, which has no watermark to be wrong.

So the newest `_recentWindow` assets by `updatedAt` are re-examined whatever the watermark
says (`recentlyChanged`), and `undecided` makes the *writing* free: in the steady state
every id comes back already decided and nothing is written.

**The reading is not free, which is why it runs on a timer.** Upstream indexes
`remote_asset_entity` on checksum, stack, uploaded date and
`(owner, visibility, deleted, created)` — not on `updated_at` — so ordering by it scans
and sorts the whole table. `assetsChangedSince` gets away with the same ordering because
its `WHERE` leaves almost nothing to sort; a window with no `WHERE` does not. Running it
on every wake-up put a library-proportional sort in front of the lock `applyPolicy`
needs, and toggling a setting then waited behind a queue of them — which is the whole
cost of this being a *repair* rather than a detector. `_recentScanEvery` is a minute, and
a minute is as good as instant for a fault that otherwise persists until something
notices. It logs when it catches something, because it firing at all is evidence the sync
delivered out of order.

**And the watermark itself has to be taken from the same question it answers.** It is
consumed by a query that filters to what can be *stored*, so setting it from the
unfiltered maximum — `signature().latestUpdate`, the obvious thing to reach for — parks
it above storable assets that were never decided. Those two maxima
differ routinely rather than rarely: trashing a photo bumps its `updatedAt`, and so does
the hidden motion half of every Live Photo. `latestStorableUpdate()` is the matching
query.

#### Album membership needs a signal of its own

On its own the watermark also sees only half of what the selection depends on:
nothing in an asset row moves when a photo joins or leaves an album. A photo
uploaded from a computer reaches the phone before it reaches the album, gets
decided while it is still in no album, the watermark moves past it — and being
added to a kept album a second later is a change nothing would ever look at again.
The photo sits in the album on screen, and the app refuses to keep it, for good.

So `check` also remembers **how many assets each album the selection names held**,
and re-derives an album whose size moved. Sizes rather than the memberships
themselves: that is one grouped query against a table which changes whenever
anyone touches any album, where the alternative is a row per photo per album kept
in the fork's own database and refreshed on every resume.

A derivation walks the albums, so it finds what arrived and by construction cannot
see what left. An album that *shrank* therefore also triggers the walk in reverse —
every decision the selection made, checked back against what the selection now
says — which lets go of an item that left a kept album instead of maintaining it
for good. It is the expensive direction, and it runs only when a size went down.

**An album that is deleted outright is neither of those cases.** The selection names
albums by id, so a deleted one lingers in it — invisible, since the screen lists
albums upstream has, and load-bearing, since an *excluded* album goes on suppressing
its photos. `check` therefore asks which named albums upstream still has
(`existingAlbumIds` — album existence, not membership, or an empty album would look
deleted), drops the rest from the selection, and re-derives.

That re-derivation is **unscoped on purpose**, and the reason is the trap: the
assets a vanished album affected cannot be enumerated from it, because its rows in
the link table went with it, and the reverse walk cannot find them either — it walks
*decisions*, and an excluded photo has none. Only a pass over the library sees that
those photos now resolve to the library's own rung. A scoped derive there looks
right and does nothing at all, leaving a deleted *excluded* album with no effect
until the library setting is toggled by hand.

**Which is affordable because a derivation writes only what changed.** Each page
reads the decisions it is about to overwrite (`decisionsFor`) and skips the rows
whose rung and motion flag already agree. So the library-wide walk — the answer to
any mismatch the incremental paths cannot express — costs the rows that actually
move rather than one write per asset, and `touched_at` keeps meaning "when the
change that selected this was made" rather than "when a walk last passed over it".
Rebuilding by *wiping* `wanted` was rejected for three reasons: it would discard the
on-demand rows, which are not derivable from the selection; it would re-stamp the
whole library and reorder the queue for work nobody changed; and it is not atomic,
so a crash halfway would leave the mirror believing nothing is wanted and the
integrity pass treating every stored file as unaccounted for.

#### Deselecting has to be free to undo

The promise that deselecting is safe only holds if re-selecting is cheap, and two
things have to be true for that. The in-memory index keeps entries for assets that
are stored but no longer selected — one per asset that is wanted **or** held — so the
app does not forget bytes it already has. And before enqueueing anything, the
downloader claims a file already sitting in `pinned/`, not just one in the
opportunistic region. Miss either and the bytes stay on disk while the badge calls
them missing and the next pass fetches them all over again — the exact cost the design
promises deselection does not have.

It follows that availability describes the *files*, not the decision: an asset nobody
selects any more still reports what it can show off-grid, because that is what the
viewer will get. It also follows that a claimed file is not a *new* one: its bytes
are already in the store's total, and counting them again made "used" climb on
every deselect-and-select round trip. Only a file that moves out of the
opportunistic region is new to the mirror, and only that one is counted — or
reported to the native side, which sizes the region it left.

Progress moves with the decision in both directions, for the same reason: it counts
files of assets something selects, so files already on disk when a selection arrives
are progress the moment it does. Nothing else would ever count them — the reconciler
finds nothing missing and so never reports them.

### 3.2.1 Why the flags need their own database

Per-asset state wants to live next to the assets, and cannot: adding a table to
upstream's drift schema means owning a migration in a schema upstream revises
constantly, which conflicts on nearly every rebase (§5 rule 3). A second SQLite
file — `mirrich_offline.sqlite`, opened in `main.dart` before anything reads it —
has no rebase surface at all.

The cost is no cross-database join, so each row carries the *stable* facts needed
to size and order the work: whether the asset is an image, when it was created,
and when the selection covering it last moved (§3.3). Everything volatile — the
thumbhash, whether it has been trashed — is read from upstream's database at the
point of use, so nothing here can go stale.
An id that comes back missing from upstream is an asset that was deleted, trashed,
locked or hidden, and its files are reclaimed on that basis.

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

That predicate is SQL in the fork's own database, which cannot see the camera roll
(§3.2.1), so `wanted.local_copy` carries the answer and every pass corrects it against
upstream. It is the most volatile input the mirror has — Free Up Space exists to delete
those local originals, and the moment one goes the mirror owes that item a full copy
again — which is exactly why the fingerprint counts local assets, and why a re-derivation
writes the row with an upsert that leaves this column alone rather than replacing it.
`test/medium/repositories/offline_flags_repository_test.dart` pins the whole round trip.

Two consequences that are easy to get wrong, and both are load-bearing:

1. **The fingerprint has to watch the camera roll.** Every other component of
   `OfflineSignature` describes the *server*, so deleting local originals — the
   whole point of upstream's Free Up Space — moved nothing, `check` concluded that
   nothing had happened, and those photos were never fetched. It now carries a count
   of local assets.
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
- `wanted.has_motion` records it, because two SQL predicates need to know and
  cannot ask upstream: the reclaim band — without it a Live Photo's video is
  "maintained by nothing" and the integrity pass deletes it the moment it lands —
  and the file count behind the progress line, which is 4 rather than 3 for these
  items at the top rung.

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
| `check` | three SQL aggregates, and nothing else if they match | every resume, and every remote change |
| `sync` | pages the wanted list, all in SQL and memory | when the aggregates move, and after every decision |
| `reclaim` | one isolate, one walk of the whole store | weekly, or on demand |

**`check`** takes a fingerprint of upstream — asset count, latest `updatedAt`,
album-link count — applies policy to anything new, re-derives any selected album
whose size changed (§3.2), and stops if nothing moved.
That is the case almost every time, which is the difference between a background
app that costs battery and one that does not.

**What starts a pass.** Cold start, app resume, **any change upstream applies to the
remote side of the database**, and **any change to the camera roll**. Every path that
touches the server side fires `onRemoteChanged` (`background_sync.dart`: the sync stream
and each websocket batch); the device side is watched directly, with a drift stream over
the local asset table (`watchLocalAssetCount`) that re-runs only when that table is
written. Both are coalesced into one `check` a few seconds later, because these events
arrive in bursts and `check` is three aggregates when nothing moved.

The camera roll is the easier one to forget, because it is not a *sync* at all: deleting
a local original — by *remove from device*, by upstream's Free Up Space, or in Photos —
is a plain write to `local_asset_entity`. It changes what the mirror owes that photo, and
nothing about the server, so without watching it the mirror learns only at the next cold
start and the tile keeps drawing the old answer until then. The stream is `distinct`,
because a *write* is not a change: hashing stamps a checksum onto every local asset it
processes, so a backup run re-runs that query continuously with the same answer, and each
of those would wake a pass that holds the lock a setting change is waiting for.

The third one is easy to leave out, and three separate symptoms all reduce to it:
without it a photo taken while the app stays open is mirrored only after a resume, an
album deleted on the server appears to do nothing, and a preview that 404s before its
thumbhash exists is never retried. The mirror decides what to fetch from a database
somebody else writes, so it has to be told when that happens.

**`sync`** pages the wanted list and asks the **in-memory index** (§3.4.2) which
files are missing. It does not touch the filesystem: a `stat` per file is three
syscalls per asset, on the isolate rendering the grid, every time a single photo
arrives on the server. A missing file the device turns out to already hold is
adopted rather than fetched — from the opportunistic region, or from `pinned/`
where an earlier selection left it — and only what is genuinely absent is queued.
The pass stops after 3000 missing files so one call's cost is bounded however far
behind the device is; the next call resumes.

#### What gets downloaded first

Mirroring a library takes hours, so the order decides what the phone can do for
those hours. One tier above three keys:

0. **an errand, before everything.** "Save offline" on a selection is a claim on
   the next few minutes of bandwidth rather than a preference. It is a tier and not
   a key because it needs no comparison with the rest: whatever is asked for by
   hand comes first. The mark is its own table (`errands`, one row per asset until
   its files are here) because the row in `wanted` cannot express it — `on_demand`
   there answers whether the copies are reclaimable as a cache, which is false
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

**The hand-over is where an order stops being one.** Upstream configures the
downloader with a holding queue — `(Config.holdingQueue, (6, 6, 3))` in `main.dart`
— so **at most three tasks of one group run at once**, the rest wait inside the
plugin in priority order, and nothing already handed over is ever re-ordered. A
priority is a small integer, so it cannot carry key 1 at all. It carries what fits
(`offlineTaskPriority`: an errand at 6, then 7 to 10 down the ladder), and the
window carries the rest: `_maxOutstanding` is a couple of dozen
tasks, not hundreds, so a decision made a moment ago is never queued far behind an
older one. Two dozen is still far more than three concurrent downloads drain
between completion callbacks. A pass that finds the downloader holding more than
that — an older pass's doing, or the build before an update, since the plugin's
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
   ones marked failed, which is the only figure in `DriftBackupState` that means bytes
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
   shared holding queue, and its group concurrency caps it at three of the six
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
costs one `EXISTS` in the fork's own database (`hasMissingBase`), where `wanted` and
`held` sit side by side, rather than a walk to find out. Its one blind spot is a
*superseded* preview, whose token lives in `held` but whose comparison needs
upstream's thumbhash: it reads as present, so a later pass picks it up once the
full-size half is no longer filling the budget.

The errand bucket never stops the walk. It is small by construction — the size of
what the user tapped — and it outranks whatever the budget would have dropped
anyway. A pass that reads an errand's row and finds nothing missing clears the
mark, so a finished errand stops outranking a selection made after it; a pass that
stopped at its budget concludes nothing about rows it never read.

Two consequences worth knowing. Nothing counts as *available* during the
thumbnail phase, since availability needs the preview too, so the item counter
sits still while the file counter climbs. And tasks already handed to the
downloader keep their place: a re-order cancels nothing that is already spending
data, so a change takes effect at the next batch, not mid-flight.

A pass that is **not allowed to download** — opening the offline screen, a cold
start with no server — looks but does not act, so it does not record the
fingerprint either. Recording it would let a pass that merely looked silence the
next one, leaving what it found parked in the queue until some unrelated change
shook it loose.

**`reclaim`** is the integrity pass, and it is *not* how storage normally comes
back. "Free up space" is, and it works from the same rows — one query and one
`unlink` per file it quoted. `reclaim` exists for what that cannot see: files left
by an interrupted pass, a thumbnail superseded by an edit, a row describing a file
that is gone. It runs on its own isolate, and does its set difference in SQL
against a temp table, so a six-figure store never becomes a six-figure Dart
collection. The wanted set crosses to the isolate as 64-bit name hashes — two
megabytes of integers rather than ten megabytes of strings. A hash collision keeps
a file that could have gone; it can never delete one that was wanted.

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

`lib/utils/offline_paths.dart` and `ios/Runner/Images/OfflineStore.swift`

One store under `Application Support/mirrich_blobs/`, in two regions:

| Region | Written by | Evicted |
| --- | --- | --- |
| `pinned/` | the reconciler, through `background_downloader` | never |
| `cache/` | the native image path, on every successful fetch | oldest-first, past 256 MB |

**The split is what makes viewing a photo count towards mirroring it.** When the
reconciler wants a file that is already sitting in `cache/`, it renames it into
`pinned/` instead of downloading it again. Upstream puts bytes fetched for the screen
into a `URLCache` no reconciler can see, so a photo the user has just looked at would
be downloaded a second time and stored a second time to end up offline — and that
`URLCache` is a gigabyte, under `Caches/`, where iOS purges it. Here it is cut to
64 MB and holds API traffic only.

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

Three parties must agree on that naming, and they are named in each other's
comments: the downloader that writes it, the reconciler that lists it, and the
Swift reader. **If the Swift naming diverges from the Dart one, every read misses
silently.** Change both together, and mind the three places Dart and Swift
differ by default. Each agrees on every URL Immich emits today and need not agree
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

Upstream's "clear cache" setting empties the `URLCache` **and** the `cache/`
region, and reports both — they are the same kind of thing. It does not touch
`pinned/`, and must not be changed to: that is the offline library, and it has its
own control on the offline copies screen.

A fourth party is the share sheet, which asks for `edited=<asset.isEdited>` and
no thumbhash. Same bytes, different key, so it looks the file up under the
canonical form instead of its own (`asset_media.repository.dart`). A video's
stored URL is its playback file, never `/original` — `offlineVideoUrl()` is the
single definition, shared by the reconciler, the player and the share sheet.

Two traps in `offlineBlobPath`:

- `getApplicationSupportDirectory()` is a **platform channel round trip on every
  call** — path_provider does not cache it. Called per lookup that is several
  channel hops per thumbnail while scrolling, so the path is resolved once and
  kept.
- It is `async`, so every caller has an await gap. `video_viewer.widget.dart`
  checks `mounted` after every other await for a reason: returning a video source
  after the viewer is gone creates a native player nothing owns, which then sits
  above the entire app swallowing gestures.

#### 3.4.1 The opportunistic region is managed, not hidden

`cache/` is the only part of the store the user cannot see in `held`, and it is
still their disk, so the offline screen owns it too — in a sub-section of its
own, under the library's: a **Cache limit** slider (Off / 128 MB … 8 GB, default
256 MB) and **Clear cache now**, which carries the figure. It is not a row in the
table above, because nothing selected it and nothing maintains it; under the same
pair of column headings as the library's own kinds it read as one more of them. The headline total counts it — a figure
that excluded it would under-report the disk the app has taken, and
`offlineDeleteStore` takes the whole root when the store is deleted outright.

Dart owns both values; the native side persists neither and holds the 256 MB
default only until the service pushes the real one at construction. Clearing goes
through upstream's own `remoteImageApi.clearCache()` rather than a second door of
our own, so Settings ▸ Advanced ▸ Clear cache keeps working exactly as before and
both empty the same bytes.

**A bigger budget makes mirroring cheaper**, which is the argument for making it
a setting at all: the reconciler claims browsed bytes by renaming them out of
`cache/` instead of downloading them again.

**The ceiling pauses; it never evicts.** When the store — library plus
opportunistic region — reaches the limit, the queue stops handing work over and
the screen says so, as its own state rather than as the user's pause: nobody
asked for it, and it clears itself when space is freed or the limit is raised.
Evicting pinned bytes to stay under a number would be the automatic deletion R1
rules out, and silently downgrading new items to previews would apply a rule the
user never set. Zero is the default, and means no limit.

**The two regions stay two directories.** Merging them into one pool with a
"pinned" flag looks simpler and is not: the invariant that nothing automatic
deletes the library is enforced by a path — the trimmer only ever walks `cache/`
— which is a proof one function long. As a flag it becomes a predicate the native
side has to evaluate against the fork's database, on a path that today needs no
database at all, and getting it wrong deletes the library. Eviction order stays
insertion-order for the same reason it always was: true LRU means writing on every
read.

#### 3.4.2 Two indexes, and why neither is optional

Nothing on a hot path is allowed to ask the filesystem.

**Native — `OfflineStore.present`.** A set of 64-bit name hashes, built once at
launch on a background queue. `requestImage` runs on the platform *main* thread,
so all it does there is derive the name and ask this set whether a syscall is
worth it; the read itself happens on the store's own queue, never on the queue
decoding is already saturating. A false positive costs one failed `open`, never
a wrong image. Dart keeps it in step through a two-method channel
(`mirrich/offline_store`) — the reconciler writes into `pinned/` behind the native
side's back, and a blob it has not been told about would stay invisible until the
next launch.

**Dart — `offline_index.dart`.** One entry per asset that is wanted *or* stored:
the quality asked for, a bitmask of the variants on disk, and three tokens saying
which files those bits refer to. One covers the thumbnail and preview, which share
upstream's cache buster; one the original, which carries that buster once the
asset has been edited (§3.4); one the video, whose URL depends on
`loadOriginalVideo`. A bitmask alone cannot tell that a file was superseded, and
all of those inputs change under the app's feet. Loaded once with a single
aggregating query, then maintained by the events that change the store.

The badge reads it synchronously behind a revision counter. Anything else — a
provider per tile, a query per tile, a `stat` per tile — puts I/O in the frame that
is trying to draw the grid.

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
| Album ▸ Options | **Available offline** — follow the library / previews / full quality / full quality + videos / never keep, with progress |
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

**A stop the user did not ask for says so in three places.** Reaching the
persistent library limit is the one state where downloading stops on its own, so
it is not left to be discovered from a progress line that has stopped moving: the
app-bar badge turns to a storage icon on the error colour — told apart from the
failure badge by its icon, since a full store is not a broken one — the summary
line carries `· persistent limit reached`, and the screen states it in full with
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

**The screen is three sections, in the order the questions get asked.**
*Downloading* — how it is going, Wi-Fi only, pause — comes first: it is what the
screen is opened to check, and a pause that has to be found past a hundred album
rows is not a pause. It is status with its own two controls attached, not a second
place to configure what gets downloaded; that is *What to keep offline*, which
comes next, followed by *Storage*, which reports what those selections cost. The
three things that govern downloading sit together for the same reason a switch
that changes what the app spends does not belong beside buttons that remove bytes.

**Storage reports; nothing on it deletes.** Every held file sits on two axes —
maintained by a selection or not, and which of the three kinds of file it is —
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

The section is two sub-sections, each headed with what it holds and each reading
the same way — figures, then its limit, then the one control that empties it.
**Persistent library**: the bar, the three kinds, the `Persistent library limit`
and `Free up space`. **Cache**: the `Cache limit` and `Clear cache now`.

**The bar is the library and its spares, and nothing else.** The cache is not a
seventh segment in it: that would make every other share look smaller than it is and
put bytes nobody chose inside a picture of what the selections cost. It has a heading
and a figure of its own, which keeps the legend down to the two words the columns
underneath are headed with.

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
Left by a change to your settings, or saved by hand. Nothing
re-downloads these.
  ☑ Videos                                          1.3 GB
  ☐ Full-size photos                                400 MB
  ☑ Previews & thumbnails                     4 MB of 22 MB
      Select "Videos" for the other 18 MB.

🔒 KEPT BY YOUR SETTINGS                                    5.1 GB
Available once everything above is selected.
  ☐ Videos                                          4.1 GB
  ☐ Full-size photos                                900 MB
  ☐ Previews & thumbnails                           100 MB

                     [ Free 1.30 GB ]
```

**The bands partition the store**, so the six figures add up to the one on the
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
copies are spares too (a rule that keeps an original keeps its preview), so the
one case where an item's files straddle two bands is a photo dropped to preview
quality, whose original is a spare — and this rule has already taken it before the
maintained band can be reached. Untick anything above and the band closes again,
dropping what was ticked in it.

Every band explains itself in one sentence under its heading rather than leaving
each cell to imply it, and the second — the only one that costs a re-download to
undo — is the only one in red, with the pause stated on it rather than discovered
at the confirmation. It pauses because those files are ones a selection asks for and
the next pass would fetch them straight back. Nothing is ever deselected; Resume
downloads them again.

A cell holding nothing stays visible and inert. A grid whose cells come and go
cannot be learned, and `0 B` is an answer.

**The previews guard is derived, not declared.** A preview may only go once its
item has no full-size copy left; otherwise an original is stranded with no
thumbnail, which cannot be drawn in the grid and gives the viewer no rung to
start on — worse than keeping or dropping both. Enforcing that with a rule of its
own strands the bytes instead: they can then never be freed by any sequence of taps,
because removing the originals does not revisit the previews. So the predicate asks
which full-size files *survive this pass* — ticking previews together with the copies
holding them up frees them, ticking previews alone does not, and there is no special
case anywhere. An item's files can sit in
two bands at once (a photo dropped to preview quality keeps its previews in the
maintained band while its original is in the dropped one), which is why the
question is asked per file and not per band.

**And the row says so itself.** A ticked previews row reads `4 MB of 12 MB` and
says what the rest needs — `Select "Videos" for the other 18 MB.`, quoting
whichever full-size rows that band is leaving behind — because the
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

**Clearing the cache sits under the cache's own limit**, not among these choices.
Those bytes are not part of the library, nothing chose them, and they come back on
their own the next time a photo is opened; grouping them with removals that cost a
re-download would overstate what they are. It still confirms, being the one other
control that deletes.

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
  Their thumbnails will stay, so they will still appear in the grid,
  but playing them will need the network.
  Only removes offline copies from this device.
```

It is **composed from what the items lose** rather than from which kinds were
ticked (`OfflineReclaimPlan` counts assets losing a preview, an original, a
playable file), because that is the difference the user will notice, and one pass
can now take several kinds at once. Worst first, and the softer lines drop away
once anything is losing its preview: such an item is off the grid whatever else
went with it, and "it also lost its full-size copy" adds nothing to that.

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
mirror's axis is drawn under it from **three figures on one scale**, where 1 is
everything the photo needs to open at full quality and ½ is the preview pair alone
(`OfflineIndex.barOf`): what a setting **maintains**, what the mirror is **fetching**,
and what the store **holds**.

- the **track** — a dark plate — runs to the longest of the three, so a copy no setting
  asked for still has room to be seen;
- **solid white** runs to where a setting maintains what is here;
- **amber, after a gap**, on to what is here: a spare;
- **bare plate**, on to what is coming: still to arrive.

| maintains | fetching | holds | bar |
| --- | --- | --- | --- |
| ½ | ½ | 0 | half plate, bare — nothing here yet |
| ½ | ½ | ¼ | half plate, half white — the thumbnail landed, the preview is next |
| ½ | ½ | ½ | half plate, white — as complete as this one gets |
| ½ | 1 | ½ | full plate: white half then bare — a spare is on its way |
| ½ | ½ or 1 | 1 | full plate: white half, gap, amber half — the rest is a spare |
| 1 | 1 | ½ | full plate: white half then bare — the full-size file is still to come |
| 0 | 1 | ½ | full plate: amber half then bare — none of it is maintained |
| 0 | 0 | ½ or 1 | plate to what is held, all amber — nothing maintains any of it |

**What is held is counted per file**, so the preview pair's ½ is a quarter for the
thumbnail and a quarter for the preview. Finer than `availabilityOf`, which is coarse
deliberately — it answers "what can this show with no network", and a thumbnail alone
shows nothing — and it has to be finer, because the queue fetches every thumbnail in the
library before any preview (§3.3). A bar that only moved when an item became *openable*
would stand still for the whole of that phase while the offline screen's own file counter
climbed, which is the one thing a progress bar must not do.

**Three figures and not two, because *fetching* and *maintained* come apart.** An errand widens
what the mirror is fetching without changing what any setting maintains, so folding the
two together draws an incoming spare as library — and then a cleanup takes it anyway,
which is the one thing the colours exist to warn about. They are the same two rules the
rest of the fork applies, which is why they live in the index and not in the widget:
*fetching* is what `filesFor` asks for, and *maintained* is what `_unselectedOver` counts
as not a spare, `on_demand` included. A second copy of either rule is a second answer
waiting to happen.

Nothing is drawn for an item that is neither wanted nor stored. Everything else has a
track from the moment it is *decided*, which is the point of drawing an empty one: a
photo on its way says so, rather than saying nothing until it arrives and then
everything at once. That costs the decision paths a revision bump — the badge redraws on
that alone, so `_applyPolicy` deciding a new photo has to announce itself even though no
file has moved.

**An outstanding errand widens the target.** *Save offline* asks for this app's own copy
however much of the item the camera roll holds (§3.2), so while one is outstanding the
want is the whole thing — the same override `filesFor` applies, from the same three
inputs: the rung, `local_copy`, and the errand. Reading only the first two made the bar
report a target the downloader was already exceeding, so tapping the action on a
camera-roll photo changed nothing on screen and then a spare appeared from nowhere when
it landed. All three live in the index for the same reason: the badge needs them
synchronously, and it must not be able to disagree with the fetching.

**Two figures because there are two questions**, and one length could only ever answer
one of them. A single length conflates "the mirror is not going to fetch more" with
"the mirror has not fetched it yet" — the difference between a working library and a
stalled one. It also makes the empty state expressible at last: a photo that has been
decided and has arrived at nothing now shows an empty track, where before it showed no
mark at all and was indistinguishable from a photo nobody selected.

**A half-length *want* means the mirror will fetch nothing beyond the preview.** That
happens two ways and looks the same for both, because the consequence is: either the
rung asks for no more, or the camera roll already holds the original and fetching it
would store the photo twice (§3.2). The second is `localCopyUsable`, the same predicate
the download side uses, so the mark and the fetching cannot disagree; the skip rule is
otherwise invisible from the outside and this is where it becomes checkable. A short
track is centred, because it is a state and not a bar that stopped part way.

**And that second fact cannot be read off the asset the tile is drawing.**
`BaseAsset.hasLocal` is `localId != null`, which says as much about the query that built
the tile as about the device: `_getPlaceBucketAssets`, `_getMapBucketAssets` and
`_getRemoteAssets` build their rows with a plain `toDto()`, so on those screens it reads
false for a photo the phone certainly has, and every deduplicated item wears a
full-length track that can never fill.

Nor can it be used as a *hint* alongside the mirror's own answer. Taking either — the
obvious repair — holds the stale answer after a local copy is deleted, because
`localId == null` cannot be told apart from "this query does not populate it", so the
fallback never stops applying and the bar only corrects itself on the next launch. So
there is one source: `localCopyOf`, from `wanted.local_copy`, kept current by the pass
that also decides what to fetch. The mark can then be wrong only in the way the
downloader is wrong, which is the property it exists to expose. A flip is the one thing
that changes what a badge draws with no file arriving or leaving, so the pass bumps the
revision the badge watches when it happens — otherwise the value is right and the tile
still shows the old one.

**A spare is a different kind of thing, so it gets a different channel — two of them.**
Those items are exactly where the grid invites an action: *Save offline* is still
offered on a photo the camera roll holds, because the camera roll is the thing that can
vanish, and what arrives is a spare that nothing maintains. Reporting it as more of the
same bar was wrong twice over. A half-length bar called a full copy on the device "as
complete as this gets" while the store held twice that; and a *dimmer* segment — the
obvious way to say "extra" — is unreadable, because brightness is already how "not
downloaded yet" is drawn, and telling 0.6 alpha from 0.4 across two tiles of a scrolling
grid, one pixel tall, over photographs, is not something anyone can do. So the spare
carries hue **and** a gap: amber, detached. Either signal alone would do; the pair
survives a bad background.

Bare plate and amber can share a bar, but only with the amber between the white and the
plate, so the order still reads: filled, then extra, then empty. The comparisons the eye
is asked to make are white against amber and white against plate, never amber against
plate.

**Not two marks, and not a glyph pair.** One mark per direction reads badly: a
backed-up, fully mirrored photo wears two clouds on every tile in the library, and a
downward mark that short-circuits on the presence of a camera-roll copy never changes
when the selection does. Two levels inside a single glyph is no better, whichever pair
is chosen — filled against outlined discs, a ring against a dot, one tick against two,
an arrow against a tick — because every one of them asks the eye to read *inside* nine
pixels on top of a photograph. A length against a track asks nothing.

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
previews, and it un-pauses downloading, because asking for a photo is asking for
it to arrive.

**Free up space says what it costs.** Its premise — safe to delete, the server has it —
is true and incomplete: for an item the mirror keeps, deleting the local original
changes nothing visible; for one it does not, the photo silently stops opening
off-grid. The scan result states the counts, computed synchronously from the
availability index. Same shape `alextran1502` describes for deletion sync on #4282:
detect the divergence, show it, let the user decide.

**Three counts, not two**, and the third is a consequence of §3.2: the mirror skips
an item's full-size copy while the camera roll holds it, which is precisely the
population this screen deletes. So "stays available offline" was true of photos the
store held only a preview of, and the deletion was the moment the device stopped
having a full-size copy of them at all. The line now says *at full quality* or *as
previews only*, and only the items that stop opening are in the error colour: the
first two still open, and reserving the colour is what keeps it meaning something.
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

## 4. Map of the change

Everything fork-specific that *can* live in a new file, does — filed by role,
in upstream's own directories (§5 rule 1). Every one of them is new, so none of
them can conflict.

**New files** (no rebase conflicts, ever):

| Path | Role |
| --- | --- |
| `mobile/FORK.md` | This document |
| `ios/Runner/Images/OfflineStore.swift` | The blob store: read, write-through, trim, index (§3.4) |
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
| `lib/presentation/widgets/offline/quality_menu.widget.dart` | The selection controls, shared by the screen and albums (§3.6) |
| `lib/presentation/widgets/offline/offline_cleanup_sheet.dart` | Where space is taken back: two bands × three kinds (§3.6) |
| `lib/presentation/widgets/offline/offline_reclaim_dialog.dart` | The confirmations behind it, and the album row note (§3.6) |
| `lib/presentation/widgets/offline/offline_album_tile.widget.dart` | "Available offline" on an album (§3.6) |
| `lib/presentation/actions/keep_offline.action.dart` | "Save offline" / "Remove offline" on a selection (§3.6) |
| `lib/presentation/widgets/offline/offline_badge.widget.dart` | The tile's cloud and its meter (§3.6) |
| `lib/presentation/widgets/offline/offline_indicator.widget.dart` | The app bar's offline button and its badge (§3.6) |
| `lib/presentation/widgets/offline/offline_cleanup_note.widget.dart` | What free-up-space costs offline (§3.6) |
| `test/utils/offline_paths_test.dart` | The names Swift has to reproduce (§3.4) |
| `test/domain/models/offline_policy_test.dart` | The ladder, and what each rung asks for (§3.2) |
| `test/domain/utils/offline_queue_test.dart` | The order a half-finished mirror fills in (§3.3) |
| `test/domain/utils/offline_index_test.dart` | What the badge says, and what progress counts (§3.4.2) |
| `test/medium/repositories/offline_repository_test.dart` | What may be stored, and what the camera roll makes redundant (§3.2, §3.2.1) |
| `test/medium/repositories/offline_flags_repository_test.dart` | Which band a held file falls into, against a real database (§3.2, §3.6) |
| `lib/widgets/common/sign_out_dialog.dart` | Sign-out, with the downloads spelled out (R2) |

**Modified upstream files** — each tagged with an `// immich-sync fork` comment.
Every one is a hook or an addition; none removes an upstream feature (R5).

| Path | Edit |
| --- | --- |
| `ios/Runner/Images/RemoteImagesImpl.swift` | Read the store before the network, and keep what it fetches (§3.4) |
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
| `lib/presentation/pages/edit/drift_edit.page.dart` | A failed save reports the server's reason, like every other action |
| `lib/pages/common/settings.page.dart` | One added entry for the offline screen |
| `lib/widgets/common/app_bar_dialog/app_bar_dialog.dart` | One added entry; fork sign-out dialog (R2) |
| `lib/widgets/settings/free_up_space_settings.dart` | One added line: what the deletion costs offline (§3.6) |
| `lib/infrastructure/repositories/local_asset.repository.dart` | Cleanup candidates carry the server id the join already has |
| `lib/presentation/pages/drift_album_options.page.dart` | One added row: available offline (§3.6) |
| `lib/utils/action_button.utils.dart` | One added action type, three small hunks (§3.6) |
| `lib/presentation/widgets/bottom_sheet/*_bottom_sheet.widget.dart` | One added action beside Download, in each sheet that offers it (§3.6) |
| `lib/widgets/common/immich_sliver_app_bar.dart` | One added button and its own `showOfflineButton` gate (§3.6) |
| `lib/presentation/widgets/images/thumbnail_tile.widget.dart` | Upstream's cloud wrapped with the mirror's meter (§3.6) |
| `lib/presentation/pages/drift_asset_troubleshoot.page.dart` | Five rows of the mirror's own view of an asset, behind upstream's *Advanced troubleshooting* flag: what the badge and the download rules each decided, in one place |
| `lib/presentation/widgets/images/remote_image_provider.dart` | Show a stored original even with `loadOriginal` off |
| `lib/presentation/widgets/asset_viewer/video_viewer.widget.dart` | Play stored videos from disk |
| `lib/repositories/asset_media.repository.dart` | Share a stored copy instead of re-downloading |
| `lib/services/api.service.dart` | Re-seed the auth cookie from the stored token |
| `lib/main.dart` | Open the fork database; track downloader tasks per group, not globally |
| `lib/domain/models/settings_key.dart`, `config/app_config.dart` | Four settings keys: the selection, Wi-Fi only, pause, and the two storage budgets |

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
Fifteen of upstream's strings name the product, in forty-nine languages. Editing
them would fork the translation catalogue and conflict on every upstream string
change, so `BrandTranslationLoader` wraps upstream's generated loader and renames
the product as the strings enter the app (`kAppName` in `constants.dart`). One
hook, no i18n diff, and strings added later are covered without anyone
remembering to.

| Path | Role |
| --- | --- |
| `README.md` | The fork's own front page, replacing upstream's outright — the one file outside `mobile/` this fork owns, and the one place a rebase conflict is resolved by taking ours whole |
| `mobile/BUILDING.md` | How to build, sign and install (new file) |
| `tools/build_release.sh` | Release pipeline: unsigned for AltStore, signed for TestFlight (new file) |
| `tools/make_icon.py` | Artwork generator, source of truth (new file) |
| `lib/utils/brand_translation_loader.dart` | Renames the product in every translated string (new file) |
| `assets/mirrich-logo{,-inline-dark,-inline-light}.svg`, `assets/mirrich-logo.png` | The mark, in-app and in the app bar (new files) |
| `assets/mirrich-splash.png`, `assets/mirrich-splash-android12.png` | Launch-screen sources (new files) |
| `assets/mirrich-text-{dark,light}.png` | Wordmark, tinted by the theme (new files) |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/` | 34 regenerated PNGs |
| `ios/Runner/Assets.xcassets/LaunchImage.imageset/` | 3 regenerated PNGs |
| `ios/Runner/Assets.xcassets/LaunchBackground.imageset/` | 2 regenerated 1×1 grounds |
| `ios/Runner/Info.plist` | `CFBundleDisplayName` → literal `Mirrich`; the two version keys → `$(FLUTTER_BUILD_NAME)`/`$(FLUTTER_BUILD_NUMBER)`; the background-task ids → `$(PRODUCT_BUNDLE_IDENTIFIER)` |
| `flutter_native_splash.yaml` | Launch-screen sources and grounds |
| `android/app/src/main/AndroidManifest.xml` | Launcher and share-sheet labels |
| `lib/constants/constants.dart` | `kAppName`, `kUpstreamName` |
| `lib/main.dart` | `MaterialApp.router(title:)`, the translation loader |
| `lib/pages/common/splash_screen.page.dart` | Title, logo asset, the translation loader |
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
  something already over. Age is the test rather than "seen twice": two passes
  seconds apart always see the same running video, and saying so each time is the
  noise this section exists to avoid.
- **A download that has not moved is cancelled, not waited on.** Past the same
  fifteen minutes with no progress in them, the task is dropped: one the system
  deferred, or left behind by a replaced build, reports nothing and ends nothing,
  and holds one of the group's three slots for good. Cancelling ends it, and the
  next pass finds the file missing and asks again.

  Note what "no progress" means for a cheap file, which never reports any: every
  thumbnail and preview the plugin has held for a quarter of an hour is cancelled.
  That is the intent — three at a time drains two dozen in about a minute, so
  fifteen is not a slow link — but it also means that while *Wi-Fi only* is on with
  no Wi-Fi, each pass hands the window back and the pass after it asks again. The
  churn costs nothing but log lines, and nothing is downloaded either way. Narrowing
  the rule to the files that do report progress would bring back the stuck slot this
  exists to clear.
- **Every final state is accounted for.** A cancelled task says so, and a failed
  one names the file and the reason. A **404 is recorded as a failure**, not just
  logged: it is the server's answer, so the same backoff applies and the pass
  stops asking for ever. That is safe to abandon because the thumbhash is *in*
  the name — an asset whose thumbnail the server has not generated yet has no
  thumbhash either, so once it produces one the URL is a different URL, under a
  different name, with no failures against it.
- **A degraded read says what it costs.** An unreadable selection means nothing
  is selected, unreadable album sizes mean every named album is re-derived, and a
  file that cannot be claimed off disk will be downloaded again — each of those
  is a warning naming the consequence, not the exception alone.
- **Isolates count rather than log**, since the log listener lives in the main
  isolate: the integrity pass and the batch delete return what they could not
  read and could not remove, and the caller reports it. A deletion that did not
  take makes the figure quoted to the user wrong, which is worth a line.

What is *not* logged: anything that happens per file on the way to success. Six
figures of downloads cannot each afford a line.

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
git fetch origin
git rebase origin/main
```

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
- `main.dart` still tracks every downloader group the app uses. Upstream's
  `trackTasks()` is replaced by a list of groups (the mirror enqueues six figures
  of tasks and reads none of their records back, so tracking them globally meant
  a database write and a delete per blob). A group upstream *adds* is not in that
  list, and nothing fails loudly — its records simply stop being kept.
- The cache budget still reaches the native side at launch — it persists nothing,
  so a lost push silently reinstates the 256 MB default (§3.4.1).
- Cache trimming still checks `pinned/` before dropping a name from the native
  index, and the integrity pass still refuses an oversized sweep. Both fail
  silently: the first as photos that will not open offline, the second as a
  library deleted by a pass that was asked the wrong question (§3.1.2, §3.3).
- The tile's bar still reads from the availability index synchronously, and it still
  keeps *maintained*, *fetching* and *holds* as three separate figures. Collapsing any
  pair reads as a simplification and loses something: fetching into maintained draws an
  incoming spare as library, and holds into either loses "not fetched yet". A spare is
  still amber **and** still detached by a gap: re-drawing it as a dimmer white puts it
  back into the one channel "not downloaded yet" already uses (§3.6).
- Every decision path still bumps the badge's revision. The badge redraws on that alone,
  so a path that records a decision without it leaves a tile blank until the first file
  lands — which reads as the app noticing nothing until it is suddenly finished (§3.6).
- `_applyPolicy` still re-examines the newest assets on every pass, and the watermark
  is still taken from `latestStorableUpdate()`. Both fail the same silent way: a photo
  uploaded a moment ago is never kept, and only toggling the library off and on finds
  it (§3.2).
- The mirror still gives way to the backup's **activity** and never to its backlog,
  and still only for `_maxYield`. Either half of that, removed, turns one photo that
  cannot upload into a mirror that never downloads again — and the pass line still
  prints `stoppedBecause`, which is the only thing that made that visible (§3.3).
- A full-size copy of an item the camera roll holds is still a **spare** at every
  rung — `wanted.local_copy` still reaches `_unselectedOver`, and `set()` still
  upserts rather than replacing, or a re-derivation resets the column and files every
  hand-saved original as library (§3.2).
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
- `OfflineStore.swift` is still in the Runner target's *Compile Sources*. A
  rebase that takes upstream's `project.pbxproj` silently drops it, and the
  offline library stops existing — see `BUILDING.md` §3.4.

## 6. Known limitations

- **The store is large by design.** Thumbnail + preview + original is roughly 10×
  preview-only, and adding videos can multiply it again. Choose "previews" per
  album or as the default to fall back to previews, which still look correct
  full-screen on a phone, or set a ceiling under Storage (§3.4.1) — it stops
  downloading rather than deleting anything.
- **The ceiling counts what the app holds, not what the phone has left.** Another
  app filling the disk is invisible to it. "Always leave N GB free" is the more
  useful guard on a phone filling up for other reasons, and needs a free-space
  query on the native side; deliberately not built yet.
- **A video is stored whole or not at all.** There is no middle rung for one,
  because the server has no smaller flavour to offer: below "full quality +
  videos" a video keeps its still and plays only with a network. If a smaller
  flavour ever exists it slots in as an `OfflineVideoTier` and a rung (§3.2), and
  nothing else in the model changes.
- **Space is not reclaimed automatically.** Deselecting keeps the bytes, so toggling
  around accumulates until "free up space" is pressed. The figure sits on the screen
  whenever it is non-zero, and an album's page reports its own. Making it automatic
  would put a mistap back in the business of costing hours of re-downloading, so if it
  is ever added it has to be opt-in.
- **A swap inside one album is invisible until that album next changes.** Album
  membership is watched by size, so a photo leaving and another arriving between
  two passes leaves the count where it was and neither is noticed. Any later
  change to that album re-derives both.
- **A camera-roll copy that iOS has offloaded is trusted anyway.** The mirror skips
  an item's expensive half while the phone holds it (§3.2), and `hasLocal` does not
  say whether the bytes are resident: with *Optimise iPhone Storage* on, iOS can
  replace the original with a placeholder that itself needs the network. Upstream's
  own image path prefers that local asset in exactly the same way, so nothing is
  more wrong than the render is — but the mirror is what promised the photo would
  open off-grid. Telling them apart needs a `PHAsset` residency check. Until then,
  *Save offline* on those items fetches the app's own copy regardless, which is the
  way out that exists today.
- **Android is not implemented.** The read path is Swift; on Android images would
  still stream from the server. The equivalent hook is in
  `android/app/src/main/kotlin/app/alextran/immich/images/`.
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
- **Three downloads at a time.** `main.dart` configures the downloader's holding
  queue globally as `(6, 6, 3)` — the last number is per-group concurrency, and
  the offline store is one group. Mirroring a large library therefore takes
  hours. Raising it is a one-line change to an upstream file, weighed against
  what it does to the server.
- **Only the queued batch survives the app being killed.** `background_downloader`
  keeps its own tasks running in the background, but the remainder of a pass is
  held in memory; it resumes on the next reconcile (app resume, cold start, or
  the button), not by itself.
- **A permanently failing download leaves the mirror one file short.** An asset
  the server cannot produce a preview for is tried three times and then left
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
