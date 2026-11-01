# Local shader recipes and voluntary contributions

**Shaders > Collect new shader recipes** is on by default and can be switched off.
It records successful graphics/transform-feedback pipelines missing from the
prepared catalog, including pipelines recovered from the native cache. Compute
pipelines are not covered. Enabling collection after programs are already loaded
needs a game restart for full coverage; disabling stops new submissions immediately.

The renderer captures only shader content hashes, specialization and canonical
numeric pipeline state. It queues a metadata snapshot; file reads, JSON encoding,
cross-session deduplication and persistence run on a serial utility-priority queue.
There are no game code pointers or Metal objects in queued records. Prepared and
failed/pending pipelines do not produce automatic contribution rows.

The private journal is `cache/shader-recipes/recipes.jsonl`. Writes are batched
(up to one scheduled write per second) and atomically replace an owner-only file.
Shutdown/reset flush accepted records. The journal has no recipe count limit, only
a 100 MiB size limit (the same for an exported contribution); the 128-record queue
only holds records waiting for the next write. Past a limit new records are
skipped and reported, never allowed to block rendering. One process owns a journal at a time with a nonblocking file
lock. Corrupt files and symlinks/FIFOs are rejected without overwriting them.
Remove a damaged journal only after stopping the app; game saves are separate.
Export alone does not clear the journal; catalog updates make previously
contributed recipes known and remove them from the in-memory pending set.

## Export and sharing

**Shaders > Export shader recipes** opens a native Save dialog and shows the local
recipe count. It creates a JSON contribution with only:

- `type: "shader-recipes"`, format version;
- shared numeric vertex/fragment/pipeline profiles;
- shader hashes and references into those profiles.

The background export snapshots the journal, calls the bundled helper for strict
schema/profile validation, and atomically publishes the chosen file. Unknown
fields, oversized data, invalid IDs and symlink destinations are rejected. The
helper has a 30-second deadline and is cancelled during shutdown/restart. An
export failure retains its private snapshot/log for diagnosis; success removes it.
**Nothing is uploaded.** Sharing the resulting file remains a separate user action.
The contribution is not a ready-to-run catalog: it deliberately contains no game
bytes, native caches, saves, user names/paths, or unverified source locators.

A maintainer can feed an exported contribution to the existing catalog exporter
with a private source index. Exact matches are required; unresolved hashes remain
pending. Multiple sets can be combined as JSONL and deduplicated by the exporter.
Generated catalogs/contributions remain ignored local artifacts until publication
is explicitly reviewed and authorized.

```sh
# Standalone helper; no Python installation needed by players.
lasgen shader-catalog contribute cache/shader-recipes/recipes.jsonl recipes.json
lasgen shader-catalog export recipes.json private-inputs/index.json catalog.json --allow-partial
```

## Local preparation becomes incremental

When preparation is enabled, the helper also reads the local journal. It merges
new variants only if both shader hashes have exact input references in the
installed catalog. Unknown inputs remain in the contribution file, while the
normal native cache serves repeat visits. Base recipes come first in the
preparation order. A malformed local journal is ignored for
preparation so it cannot disable the valid installed catalog. The packaged base
catalog is never rewritten automatically.

This makes local discovery/preparation dynamic; the shared catalog still needs
review and inclusion in a later build. There is no server or automatic submission. Official metadata catalog downloads
require an explicit action; individual contributions are reviewed first.

## Validation on Apple M5, 2026-11-01

- 88 Metal Validation cases passed. Focused coverage additionally checks successful
  unprepared capture, prepared exclusion, prior-session deduplication, owner-only
  files, corrupt files, symlinks, FIFO rejection, bounded nonblocking enqueue and
  background native snapshot/helper export.
- 15 Python catalog/contribution cases passed, including profile round-trip,
  unknown payload rejection, preserving an existing destination on invalid input,
  local-variant merge and fallback from invalid local UTF-8.
- One gameplay pair at fixed 1.5x, the player's 30-fps profile, identical copied
  save/cache and camera inputs: collection off/on throughput was 29.60/29.80 fps,
  median 30.0/30.0. No sustained drop was observed at that cap. First-use compile
  cost differed (1,769/798 ms in the sampled interval), so this is not an uncapped
  overhead measurement, speedup claim, or proof of zero cost.
- The active run produced 145 unique rows. The standalone helper exported and
  validated them as a 74,335-byte contribution. Of those, 38 could be merged with
  the existing catalog references immediately; 107 needed additional references.
- The developer's full private index resolved all 145 observed shader inputs.
  Combining the contribution with prior recordings produced a private 292-pipeline
  catalog with 255 input references; the original two unresolved recipes remain
  omitted. A short native startup prepared all 192 program variants and 292 PSOs
  with no misses among included recipes (138 ms using warm Metal caches; not a
  cold-performance result). No generated catalog or contribution was published.

The existing renderer diagnostic/trace tools remain separate. This collection
feature does not turn on shader dumps or GPU captures.

The native export API was also exercised on a utility queue with the packaged
helper (the optional `LARECOMP_TEST_RECIPE_EXPORT=1` preparation fixture). It
snapshotted the journal and produced the validated JSON contribution. The new
Video settings and 145-row count were observed in the launcher. Automated
interaction with the Save panel was inconclusive; the native export/backend
path and helper were verified separately. No file was sent anywhere.

## Community contributions and explicit catalog updates

**Shaders > Contribute recipes on GitHub** opens the project's contribution form.
First use Export, then attach that JSON yourself. The app never uploads the
journal or attaches anything automatically. Maintainers validate contributions,
resolve input references against their own private index, deduplicate recipes,
and leave unknown origins pending. The issue form explicitly excludes game
files, keys, saves, shader dumps, translated source and native caches.

**Shaders > Update shader catalog** explicitly checks the latest 20 official
MonZaMac GitHub releases for a stable `shader-catalog.json` asset. It downloads
only metadata from the fixed official repository, checks the GitHub asset's
SHA-256 and byte count, rejects unsupported schema/extra code fields, and
reconstructs the inputs from the user's own files before installing the new
base. The request and verification run off the render thread; shutdown or a
120-second deadline cancels the helper. Offline errors, absent catalogs and
verification failures retain the previous catalog. No periodic catalog polling
or automatic upload is added.

The official downloaded base lives at `cache/shader-preparation/catalog.json`
and takes priority over the bundled base on the next game start. **Local
recipes are merged, not replaced:** the independent journal is preserved, known
compatible variants join the effective preparation catalog, and unknown input
origins remain pending. Invalid local journals cannot disable a valid official
update. Old official releases are not blindly unioned, so corrections can
replace outdated base entries. Downloaded catalogs trust the official GitHub
release publisher and HTTPS; the asset digest is an integrity check, not an
independent publisher signature or a legal clearance.

Maintainer flow (manual and separately authorized): validate a reviewed v2
catalog with `lasgen shader-catalog check --for-distribution`, then attach it as
`shader-catalog.json` to an official stable release. The release asset must
expose its GitHub SHA-256 digest. The updater accepts no arbitrary download URL.
The normal app version check ignores non-semver catalog-only release tags.
No catalog is published by this implementation. Until one is released, the
button reports that no published shader catalog is available.

Synthetic tests cover verified updates, merging/preserving local discoveries,
unknown input origins, malformed local journals, absent assets, draft/prerelease
exclusion, hostile asset IDs, digest/schema/game incompatibility, byte limits,
symlink destinations and preservation of the previous catalog.

Local validation for this change: 10 synthetic updater tests, 15 catalog tests
and three input-index tests passed. The runtime and standalone PyInstaller
helper built. The focused Metal Validation preparation test passed with the
native background-export/helper round trip enabled. A real official GitHub
check through the packaged helper returned the expected no-catalog exit code
and preserved a pre-existing destination byte for byte. Launcher settings
rendered and exited in a bounded smoke test; the two new actions were not
clicked end to end through the graphical UI. A read-only review reported no
P1/P2 findings. A successful real public-catalog download remains untested
because no catalog has been published. All generated artifacts remain local.

After a catalog update, the pending contribution view is refreshed immediately
on its serial writer queue. Recipes now covered by the official base leave the
pending journal, while still-unknown recipes remain. Export refreshes that view
as well. The downloaded catalog has the same priority for collection and
preparation, so a stale bundled base cannot cause redundant contributions.
A focused native regression verifies catalog refresh, pending-file pruning and
not recording a now-covered row again. Manual export still does not mark rows
as delivered: only a reviewed official catalog proves they have been adopted.

## Homepage catalog status

The home screen shows **Shader catalog** directly beneath Legal notice. Once
per app launch it checks official GitHub release metadata in the background;
it does not download the catalog asset, reconstruct game inputs or compile
anything during this check. A digest match with the installed downloaded or
bundled base displays **Up to date**. A different or missing base displays
**Update available** and **Update now**, using the same explicit safe update
as Settings → Shaders. Checking/updating, unpublished catalog, failed check and
failed update have separate states; errors never claim the catalog is current.
`LARECOMP_NO_UPDATE_CHECK=1` also disables this automatic metadata check.

Validation: 12 updater/status synthetic tests pass; current/available checks
fetch only release metadata and leave preparation files untouched. The runtime
and packaged helper build, both homepage states were rendered and inspected
using screenshot-only state fixtures, and a real packaged-helper metadata
request returned the expected unpublished-catalog result. Read-only review
reported no P1/P2 findings. A public catalog still has to be released separately.
