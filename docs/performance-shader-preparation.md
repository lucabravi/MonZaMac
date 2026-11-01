# Local shader preparation: station prototype

This is an opt-in developer prototype, not a production first-install feature.
It prepares previously learned graphics/transform-feedback variants from an
index built locally from the user's own game files. No manifest, shader input,
translated source or compiled pipeline is distributed.

## Behavior

`tools/za/shader_inputs.py` indexes BNSH containers in the user's NSO images
and, with an external developer decoder, shader-named Trinity packs and UI
`.arc` packs and particle `.ptcl` packs. It writes
SHA-256-addressed `.bin` inputs plus `index.json` to the requested PRIVATE cache.
The index keeps source fingerprints and executable/archive-entry offsets for
provenance. The decoder is not linked into or bundled with the runtime.

`LARECOMP_SHADER_RECORD=<absolute JSONL path>` records complete observed
specializations and the actual render-pipeline descriptor on cache misses.
The records contain hashes and numeric state, with no code bytes or addresses.
Start a tour with a new output file; this prototype appends records and
only deduplicates within the process. It records graphics and vertex-only
transform feedback, not compute. Recording does file I/O at first use and is
for development, not performance measurements.

With both `LARECOMP_SHADER_PREP=<absolute JSONL path>` and
`LARECOMP_SHADER_INPUTS=<absolute input-cache directory>`, the renderer prepares
known variants at the first graphics use, before title/world rendering. It
validates input lengths and SHA-256 hashes, uses the existing `get_program`
translation/compile path, and retains prepared programs/pipelines. Live reuse
requires matching shader content, specialization and descriptor state. The
selected guest-memory window is included in in-process program identity.
Unknown or changed variants retain normal first-use compilation.

Preparation is serialized with drawing. Translation/cache access stays on the render thread; native Metal compilation uses an active-CPU-sized worker pool, bounded by program groups. It uses the current
translator and compiler options, rather than loading translated code from a
previous build. It does not move guest pointers onto a background worker.
Shader overrides/debug probes disable the preparation path. In-place reboot
drops prepared objects and allows preparation on the next boot. Existing
pipeline-archive save/crash safeguards remain in force; an unavailable archive
does not prevent retaining prepared pipeline objects in memory.

Limits: 16 MiB each for manifest/index files, no recipe count limit,
16 MiB per shader input and 128 MiB retained input bytes during preparation.
Malformed records or hash/span mismatches are skipped. The private files are
not a supported interchange format; schema version 1 is for this prototype.
The decoder API accepts bounded numeric descriptor fields; Metal can still
reject a device-unsupported valid format or configuration, causing fallback.

## Developer use

From the source checkout, build a private input index:

```sh
tools/venv/bin/python tools/za/shader_inputs.py extracted build/shader-inputs
# To include Trinity packs, also pass --ooz /path/to/external/libooz.dylib.
# --ooz-exe /path/to/oozdec accepts an external developer executable whose input
# is an 8-byte little-endian output size followed by the compressed payload.
```

The default command indexes executable containers only. The existing external
Oodle interface in `tools/za/trinity.py` is reused. The commonly used external
ooz implementation is GPLv3-or-later; this change does not copy or bundle it.
The prototype requires a developer to supply that tool if archive coverage
is needed. No new runtime dependency is installed.

Record a scene normally, then prepare those observed variants on another run:

```sh
LARECOMP_SHADER_RECORD="$PWD/build/station-recipes.jsonl" \
    tools/hang_sample.sh

LARECOMP_SHADER_PREP="$PWD/build/station-recipes.jsonl" \
LARECOMP_SHADER_INPUTS="$PWD/build/shader-inputs" \
    tools/hang_sample.sh
```

`[shader-prep] prepared ...` reports startup cost and unresolved records.
`[shader-prep] live reuse ...` reports content-variant hits and pipeline lookup
hits, not unique pipeline counts. Preparation cost is logged separately from
normal first-use compilation statistics. With no preparation/recording
variables, normal rendering and first-use compilation remain the default.

**This does not give a fresh installation coverage for unobserved scenes.**
The developer recording path requires locally learned recipes. A local first-install catalog flow is now implemented (see [first-install shader preparation](shader-first-install.md)); no catalog is distributed yet. It has no skip UI,
and does not index every possible archive, mod or DLC source. Do not ship a
maintainer-generated recipe/input cache as part of this prototype. Expanding
coverage and a user-facing preparation flow are follow-up work.

## Apple M5 station result, 2026-10-31

Base: `develop` `36615f9`. Runtime rebuilt with this prototype; original game
library reused. Private copies of the station save/settings, 1.5x, dynamic
60 fps, shader waiting on, overlap/XFB barrier on, visible 1800x1130 window.
A at frame 300 for five frames, then forward at frame 750 for 360 frames;
window screenshots at frame 1250. External 100-second process-group deadline
and `tools/hang_sample.sh` for every game run. User saves/caches untouched.

One acquisition run recorded 149 pipeline recipes referencing 150 distinct
shader inputs. The private index contained 8,461 unique inputs (40 executable,
8,421 archive), about 79 MiB including metadata. It resolved 112 of the 150
shader references and all inputs for 123 of the 149 pipeline recipes.

For the comparison, both runs started with empty application compile caches,
`LARECOMP_NO_SHADER_WARM=1` and `LARECOMP_NO_PIPELINE_ARCHIVE=1`. Different unique
`LARECOMP_SHADER_SALT` values changed the Metal entry-point names in each run,
reducing source/function-cache reuse between runs. This is stronger than the
previous comment-only salt but is not a flush of all OS/driver caches.

| Measurement | Preparation off | Preparation on |
| --- | ---: | ---: |
| Scene-entry reported compile time | 6,412 ms | 392 ms |
| Largest scene-entry present gap | 6,379 ms | 336 ms |
| Scene-entry compile operations | 159 | 26 |
| Walk reported compile time | 41 ms | 41 ms |
| Largest walk present gap | 60 ms | 60 ms |
| Walk compile operations | 13 | 13 |
| Normal startup reported compile time | 9,377 ms | 1,382 ms |
| Largest normal startup present gap | 6,379 ms | 525 ms |
| Compile-skipped draws, entire run | 0 | 0 |
| Last logged frame time since app start | 31.3 s | 31.2 s |

Preparation itself took **8,078 ms**, creating 91 program variants and 123
pipelines; 26 records could not be prepared. Live execution reported 92 program
variant reuse events and 161 pipeline lookup hits. Counts can exceed the
number of prepared objects when the same content is uploaded/bound again.
A brief renderer-suite run overlapped early startup of the on run; it finished
before the measured scene-entry/walk windows, but preparation duration is
indicative rather than an isolated compiler benchmark.

The compilation cost moved before gameplay; this is not a faster-startup or
steady-state FPS claim. Scene entry is substantially less disruptive, but the
walk's compilation-associated hitch remains unchanged. No new compute program
was logged during that walk, so compute preparation alone is not established
as the fix for the remaining hitch. Next work should resolve the uncovered
shader references/variants before adding broad prediction or UI.

Stats were logged every 0.25 s and grouped by each window's ending frame:
scene-entry 430–499, walk 750–1109, startup <750. Boundary windows can straddle
phase transitions. `stat_compile_ms` is aggregate construction time, not GPU
busy time; values are integer milliseconds. Zero skipped draws is expected
with shader waiting enabled. Screenshots confirm the same station route with
no obvious new defect; NPC animation/weather differences prevent a strict
pixel-equivalence claim. Battles, long sessions and other Macs remain untested.

An initial on run exposed a missed vertex-only XFB preparation path during
review. It was discarded, the regression fixed, and only on was repeated.
The off behavior was unchanged by that fix; the original off measurement is
retained. No unchanged all-scale or gameplay sweep was performed.

## Validation

- Three synthetic Python tests: bounded BNSH parsing, reference/hash accuracy,
  embedded containers and deduplication; no game fixtures.
- Real Metal regression: specialization serialization, exact synthetic green
  pixels, record/prepare/live reuse with zero first-draw compilations,
  vertex-only preparation with live XFB off, malformed recipe rejection and
  truncated input fallback without shader dumps. The XFB regression was seen
  failing before the fix and passing afterward.
- 87/87 renderer tests passed with Metal Validation on Apple M5.
- Full runtime build, independent code review and final station screenshots.
- Only source, synthetic tests and this numeric report belong in Git. Private
  input blobs, manifests, logs, saves and screenshots stay outside the diff.

## Follow-up: residual first-walk hitch

A focused persistence investigation identified the 13 late construction
operations: six graphics program builds and seven render pipeline builds.
All nine distinct translated VS/FS source files were present and their FNV
hashes matched their filenames. All seven pipelines were eligible for the
archive. The same-cache second run recovered all seven from the archive.
This workload therefore did not demonstrate unsavable shaders or a failed
archive save.

| Same 1.5x station walk | Reported compile time | Maximum gap |
| --- | ---: | ---: |
| Original index, fresh private cache | 42 ms | 63 ms |
| Original index, same cache on restart | 1 ms | 19 ms |
| Expanded index, fresh private cache | 0 ms | 19 ms |

The first run's six program builds took 37.431 ms in total; one alone took
36.897 ms. Seven pipeline builds took 4.535 ms. On restart, the six program
lookups/constructions took 0.590 ms and seven archive hits took 0.516 ms.

The indexer had filtered Trinity packs by `shader` in their names, excluding
UI `.arc` archives. An offline scan found exact full-code/constant hash matches
for all nine missing inputs in UI archives. These are valid source references,
not proof that the game loaded those particular copies: shared shader binaries
can appear in multiple archives. Including `.arc` packs adds 153 unique inputs,
for 8,614 total. Source coverage becomes 137/150 observed references and
141/149 complete pipeline recipes.

One further cold run with the expanded index, a new entry-point salt and an
empty private application cache prepared 108 programs and 141 pipelines in
8,825 ms. The walk had **zero** program/pipeline compilation events and a
19 ms maximum gap. Live reuse totals were 116 program-variant events and
178 pipeline lookups. No new visible defect was observed in the station shot.
Eight recipes remain unresolved elsewhere in this workload; this is not
complete game-wide or fresh-install coverage.

Only two persistence runs and this one targeted cold verification were made.
The temporary metadata-only compile probe and raw logs remain private, and the
probe was removed from runtime source afterward. The three synthetic input
index tests passed. No renderer behavior was changed by the archive filter.
The upstream typed-texture preparation fix supplied for comparison addresses
stencil/integer sampler identity; this prototype already records those fields,
so no corresponding key change was needed here.

## Particle-effect input coverage

Following the UI fix, an offline scan of the 260 particle `.ptcl` packs
resolved nine more of the thirteen still-missing shader inputs. Those exact
hash matches complete six additional observed pipeline recipes. Including
particle packs yields 12,949 unique indexed inputs, an approximately 8 MB
index, 146/150 observed input references and 147/149 complete recipes.

A short startup-only native validation successfully prepared 113 program
variants and 147 pipelines, with two recipes unresolved. This used warmed
Metal caches and is a correctness/coverage check, not a cold timing result.

The two remaining recipes reference four inputs. A short, visible startup
probe captured only those four inputs locally at frame 461. They did not
match whole spans in the decoded NSO images or complete instruction spans
in the examined shader/UI/particle archive entries. This does not prove
runtime generation: unindexed file types or load-time modifications remain
possible. Similar-looking shader code is not substituted for an exact match.
The origin probe was removed from runtime source and all captures stay private.

This extends source coverage, not game-wide recipe coverage. A previously
unrecorded particle effect can still compile at its first use; avoiding that
requires its exact variant to be known and prepared before it appears.

## Preparation progress page (local follow-up)

When preparation is enabled with the two environment variables above, a native
page replaces the black game window. It shows the number of recipes checked
and a percentage; skipped/missing recipes count as checked, not successfully
compiled. The main UI thread owns the page, so synchronous Metal compilation
cannot block its redraws or window-close handling. Gameplay input is modal
while the page is shown. The page is removed when preparation finishes, and
ordinary first-use compilation remains the fallback. No Metal drawable or
shared ImGui context is used to render the page.

Validation on Apple M5: runtime build, both focused `CASE=preparation` tests,
and one bounded visible launch using private inputs passed. The native page
was observed at 35/149 recipes, and disappeared before the station rendered;
113 programs/147 pipelines were prepared, with two recipes unresolved. The
19.5-second preparation used a new compiler entry-point salt; this UI check is
not a controlled performance comparison. The test instance was stopped.

## Responsive progress and bounded parallel compilation (local follow-up)

Preparation now shows a native main-thread page with a progress bar, percentage
and checked-recipe count. Missing/invalid recipes count as checked; queued
compilations do not. The page uses no shared ImGui context or Metal drawable,
so long native compiles cannot block its redraws. Gameplay input is modal,
while window close and gamepad connect/disconnect handling remain available.
Keyboard state is cleared when the page gains/loses focus.

Programs are translated and grouped by exact identity on the renderer thread.
At most two workers compile independent programs and their pipeline variants;
each program has one owner. Completed pipeline results and progress are
published under a lock, and every worker joins before temporary inputs/cache
entries are released, draw statistics restored, or rendering resumes. Duplicate
recipes reuse a group's pipeline instead of compiling it again. Failures still
fall back to normal first-use compilation. `LARECOMP_SHADER_PREP_WORKERS=1`
selects serial native compilation for developer comparisons/rollback; otherwise
the fixed limit is two, to bound CPU/compiler memory pressure.

One controlled Apple M5 pair (fresh private application caches and distinct
entry-point salts) prepared the same 113 programs and 147 pipelines, with the
same two unresolved recipes:

| Native preparation workers | Total preparation time | Observed peak workers |
| --- | ---: | ---: |
| 1 | 19,194 ms | 1 |
| 2 | 9,628 ms | 2 |

This single pair shows a 49.8% reduction for the recorded station workload,
not a universal speedup. Both bounded runs entered the station; the parallel
page was visibly advancing and disappeared before gameplay. The runtime and
focused preparation tests passed; 88 native renderer tests passed with Metal
Validation on Apple M5. Other Macs, prolonged sessions and game-wide recipe
coverage were not tested. All test instances were stopped. Inputs, recipes,
raw logs and screenshots remain private; no push/PR update was performed.

## CPU-sized preparation workers, 2026-11-01

The default native compilation concurrency now follows
`NSProcessInfo.activeProcessorCount`, bounded by the number of distinct program
groups. A missing CPU count or empty batch safely selects one slot. Translation
and cache ownership, result locking and the final worker join are unchanged.
`LARECOMP_SHADER_PREP_WORKERS=<positive integer>` can lower the concurrency for
comparison or rollback; it is bounded by CPU/job capacity. Malformed, zero,
negative and overflowing values fall back to automatic selection.

One cold pair on Apple M5 (10 active logical CPUs, 32 GiB RAM) used the same
147-recipe catalog, empty separate application caches and distinct compiler
entry-point salts:

| Selection | Preparation | Peak active jobs | App peak RSS | Metal compiler services peak RSS |
| --- | ---: | ---: | ---: | ---: |
| Explicit 2 | 9,608 ms | 2 | 993 MiB | 146 MiB |
| Automatic | 2,985 ms | 10 | 995 MiB | 300 MiB |

Both prepared 113 program variants and 147 pipelines with no misses among the
included recipes, then reached the station. The two originally uncovered
recipes remain excluded from this catalog. This one pair shows a 68.9%
reduction on this Mac, not a cross-device performance guarantee. RSS was
sampled about every 200 ms during startup/preparation; compiler figures sum
all visible MTLCompilerService processes on the machine and are not exclusive
attribution to this app or a measurement of total system memory. Other Macs
and memory-pressure conditions were not tested.

The runtime build and two focused preparation tests passed, including active
CPU/job bounds, serial/two-worker overrides and malformed override handling.
No unchanged repeated gameplay sweeps were run. Test instances were stopped;
all source changes and numeric results remain local, without push/PR updates.
