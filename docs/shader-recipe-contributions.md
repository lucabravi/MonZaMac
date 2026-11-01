# Local shader recipes and voluntary contributions

**Video > Collect new shader recipes** is on by default and can be switched off.
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

**Video > Export shader recipes** opens a native Save dialog and shows the local
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
review and inclusion in a later build. There is no server, automatic submission,
or silent download of someone else's contribution.

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
