# Local shader preparation: station prototype

This is an opt-in developer prototype, not a production first-install feature.
It prepares previously learned graphics/transform-feedback variants from an
index built locally from the user's own game files. No manifest, shader input,
translated source or compiled pipeline is distributed.

## Behavior

`tools/za/shader_inputs.py` indexes BNSH containers in the user's NSO images
and, with an external developer decoder, shader-named Trinity packs. It writes
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

Preparation is serialized with translation/drawing. It uses the current
translator and compiler options, rather than loading translated code from a
previous build. It does not move guest pointers onto a background worker.
Shader overrides/debug probes disable the preparation path. In-place reboot
drops prepared objects and allows preparation on the next boot. Existing
pipeline-archive save/crash safeguards remain in force; an unavailable archive
does not prevent retaining prepared pipeline objects in memory.

Limits: 16 MiB each for manifest/index files, 1,024 recipe lines prepared,
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
It requires locally learned recipes, has no launcher progress/skip UI yet,
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
