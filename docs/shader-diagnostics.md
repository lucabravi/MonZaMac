# Shader diagnostics (macOS, opt-in)

This instrumentation is retained for future investigations of first-use hitches,
shader origin, archive misses and registration/first-use timing. It is off by
default. It never uploads anything. The default output contains metadata only;
shader input dumps require a separate explicit opt-in.

## Start a collection

Run from the source checkout, using a **new absolute output directory**:

```sh
LARECOMP_SHADER_TRACE="$PWD/build/shader-trace-new" \
    tools/hang_sample.sh
```

The renderer and filesystem collect bounded evidence under that directory.
Use `EXE=/absolute/path/to/monzamac` with the existing launcher to select a
worktree build. Keep `LARECOMP_DATA_ROOT` on a private save copy for automated
investigations. The game remains visible; do not use a heavy Metal capture.
For autonomous runs, use an external process-group deadline. For interactive
collection the user controls when to stop.

For broad registration-to-use measurements, set
`LARECOMP_SHADER_TRACE_TIMING_ONLY=1`. This omits read history and caller stacks,
forces input dumping off, and raises the bounded budgets to 16,384 distinct
input/address pairs and 32,768 total events; the 16 MiB output limit still applies. This
avoids exhausting the normal origin-investigation budget on shaders registered
before the first presented frame. It still hashes inputs and is diagnostic,
not an uninstrumented performance benchmark.

Optional filters:

- `LARECOMP_SHADER_TRACE_TARGETS=/absolute/targets.json`: JSON array of complete,
  lowercase SHA-256 hashes of shader code **including compiler constants**.
  Only matching registrations are recorded. Without it, the first distinct
  registered inputs are recorded, subject to the limit below. An invalid target
  file disables tracing rather than silently broadening the collection.
- `LARECOMP_SHADER_TRACE_FRAMES=750:1110`: compilation/archive events with
  `first <= frame < last`. Registrations and read history are deliberately not
  filtered, because a shader can be registered long before its first draw.
- `LARECOMP_SHADER_TRACE_DUMP=1`: also save matched shader inputs as private
  `<sha256>.bin` files. **These are game-derived bytes, not distributable files.**
  Keep them outside Git/releases/issues. Leave this off for metadata-only work.

The tracer refuses to overwrite an existing `events.jsonl`; choose another
output directory for a new session. Output directories/files are created with
owner-only permissions. Keep raw traces private too: they can contain local
file paths, memory addresses and game-internal names.

## Output and interpretation

`events.jsonl` contains one JSON record per event:

- `session`: schema version and whether input dumping was explicitly enabled.
- `shader`: full input hash; stage; code/control addresses and constant span;
  registering program; best-effort guest frame-pointer call chain; read-history
  sequence; matching destination-range candidates; last 32 preceding reads.
- `compile`: operation, host wall latency, code addresses, translated-source FNV
  hashes, source-file presence and render-archive eligibility where applicable.
- `reset`: new epoch after reboot, with stale address/read history cleared.

Every event has a monotonic timestamp, presented-frame count, host thread and
epoch. `program` means library/function construction for a graphics program.
`pipeline` means synchronous render PSO construction; `pipeline-async` includes
callback scheduling latency. `archive-hit` means the actual archive lookup
succeeded. Compute library and pipeline events are separate; render archive
eligibility does not apply to them. None of these latencies is GPU busy time.

A source file being present does not itself prove its contents are valid or
that the native pipeline was archived. `archivable=1` means eligible, not
successfully persisted. Compare a restart's `archive-hit` events and the
existing `[shader] pipeline archive saved/loaded` messages to establish reuse.
Translated source hashes correspond to `cache/shaders/{v,f}_<hash>.metal` for
the graphics path; compute programs use the same cache (`f_` files) and the pipeline archive.

A matching guest destination range is **only a candidate origin**. Guest
buffers are reused and copied, and compressed reads do not map byte-for-byte
to decompressed output. This tool does not propagate memory taint or observe
every guest write/decompression. Confirm an origin by reconstructing the input
from its source and verifying its full hash. Recent reads indicate temporal
proximity, not causation. A read crossing a RomFS-file boundary is labelled
`<romfs-image>` with an image-relative offset; add-on storage is labelled
`<add-on-storage>`. The logical RomFS path can also refer to a virtual overlay.

The guest call chain is best-effort and bounded. Reads of frame records use
Mach's checked memory-read API and stop on invalid pointers. The `symbol`
field is the **nearest exported symbol**, not necessarily the function containing
the PC; large offsets commonly indicate stripped internal code. Use the raw
PCs and module image when doing deeper caller analysis. Do not infer a file
origin from a nearby exported function's name alone.

## Summarize a trace

```sh
python3 tools/za/shader_trace_report.py build/shader-trace-new
python3 tools/za/shader_trace_report.py build/shader-trace-new --game extracted
```

The report summarizes compilation/archive counts and latencies, shader callers
and address candidates. Where a matching program-construction event exists,
it reports the registration-to-completion interval within the same epoch. This
is not a guaranteed first-draw deadline, especially for asynchronous compilation.
With `--game`, it maps recent `arc/data.trpfs` read
ranges onto Trinity payload intervals and lists candidate pack names. It reads
archive metadata, not shader code, and needs no Oodle decoder. Overlap counts
are deduplicated per pack per read. Shared binaries can occur in many packs;
a candidate name is not proof of the exact copy the game loaded.

The reader tolerates an incomplete last JSON line after a killed process.
It does not read `.bin` input dumps and does not send the report anywhere.

With tracing enabled, up to 1,024 `[shader-variant]` lines in the ordinary game
log record the full input hashes and specialization alongside the translated
vertex/fragment source-hash pair. These are bounded metadata, not shader bytes.
They allow an expensive compilation to be matched exactly to catalog recipes
and to registration events even if the game uploads identical code at several
addresses. Diagnostic hashing is enabled for program identity in this mode.

## Bounds and overhead

- 512 file-read records retained in memory; only the latest 32 are included in
  each shader event, plus address-range candidates from the retained history.
- At most 256 shader-registration records and 4,096 total output events per
  process; at most 16 MiB JSONL output.
- At most 16 MiB per shader input; optional input dumps limited to 32 MiB total.
  Only addresses inside the reserved guest window can be copied; unrelated
  host memory is rejected. Failed partial dump files are removed.
- At most 12 guest caller frames. Inputs are deduplicated by hash within an
  epoch. A reboot clears address history/deduplication, not the session budget.

With tracing off there are no trace files or read-history allocations. With
it on, hashing, safe memory reads, stack lookup and file writes add overhead;
use targeted hashes and do not treat a diagnostic run as a clean benchmark.
Only the active trace output is flushed; no full-game capture is created.

## Validation and current investigation

`gmake test-shader-trace` builds synthetic native checks without game files or
a GPU: disabled/no output, enabled metadata/deduplication, compile-frame filter,
bounded read history/reset, invalid frame pointer, rejection of host-memory
capture, valid/invalid target filters, optional input dumps, asynchronous frame
stamps, overlapping archive intervals and the JSON report. The isolated `IFile` tests
stub the disabled interface to retain their existing scope.

A bounded station boot captured all four previously unresolved inputs at
registration (frame 370), before their first rendering use seen in the earlier
probe (around frame 461 in a different run). In this same collection, matching
program-construction events completed at frame 455, approximately 1,873 ms
after registration. They share a guest caller chain. There were no direct
read-destination matches, consistent with an intermediate copy/decompression or
other transformation, but that observation alone establishes none of those
causes. Recent-read archive names are leads; their exact origins remain open.
The collection was metadata-only, not a shader dump or Metal frame capture.

## Bulk registration timing experiment, 2026-11-01

The current local preview was combined with the opt-in diagnostics and tested
on Apple M5 at fixed 1.5x / 30 fps. A private station-save copy and an empty
application cache were used; catalog preparation, source warming and recipe
collection were disabled for this acquisition. A unique function-name salt
reduced Metal source-cache reuse, without claiming to flush the OS cache.
The visible run pressed A at frame 300, walked forward for 210 presented
frames from frame 750, captured frame 1100 and exited under a 90-second
process-group deadline. The final screenshot confirmed the station route.
Original saves, settings and caches were untouched.

An initial origin-mode acquisition exhausted its registration budget before
world entry. Timing-only mode therefore suppresses provenance/call-stack work
and raises the bounded metadata budget. It recorded 8,603 distinct inputs,
including 8,450 before the first presented frame, without hitting either its
registration or output-byte limit (about 3.5 MB). This is a reason to select
useful variants rather than compile every registered shader indiscriminately.

There were 129 graphics-program construction events and 171 graphics-pipeline
events. Exact recorded-address matches covered both stages of 42 constructions;
all 42 had registration lead exceeding their observed native program compile
cost. Twenty-three occurred during scene entry, costing 1,551 ms in aggregate.
This is a lower bound on opportunities, not a measured amount of stutter saved.
Content-deduplicated registrations omit later upload aliases, so unmatched
constructions are unclassified rather than evidence of zero lead.

Most importantly, the four previously unresolved input hashes were registered
at frame 352, with their two programs compiled at frame 413. Neither pair is
referenced by the current 292-recipe private catalog. Native program costs
were 44.61 and 46.49 ms. Raw registration-to-compile-start lead was about 8.7 s;
subtracting the union of other recorded compilation intervals left about
2.21 s. This adjusted interval still includes ordinary game/host work and is
not a promise that all of it is available to a compiler worker. Compile start
is estimated from the completion timestamp minus measured compile latency;
it is not an instrumented first-draw deadline and excludes translation.

The forward walk still encountered a 39.66 ms program build plus a 4.27 ms PSO
build at frame 828, alongside inexpensive constructions. Their code addresses
were not matched by the content-deduplicated registration records, so this
capture does not establish how much early compilation can hide that hitch.
No early worker was implemented or benchmarked here. Draw-specific variants,
safe input snapshots and renderer/translator ownership remain prerequisites.
The timing-only synthetic checks, including registration beyond the normal
256-input limit, passed; the current runtime built and completed the station
run. No additional all-scale or GPU-suite sweep was performed.

## Residual station walk compilation: resolved classification

A follow-up on November 1 matched the previously observed ~40 ms program at
walk frame 828 by both translated-source hashes. Its full input hashes and
specialization match exactly one recipe in the current private 292-recipe
catalog. Both inputs resolve to previously indexed UI `.arc` Trinity packs.
The source registration was not missing: content-only deduplication had hidden
later upload addresses. Timing mode now retains those aliases; the synthetic
regression failed before that change and passed afterward.

One new cold private-cache run used the same 1.5x / 30 fps station route,
shader waiting enabled and all 292 current catalog recipes prepared against
verified locally indexed inputs. All 255 catalog input references were present.
Preparation built 192 programs and 292 pipelines with zero missing/invalid in
3,284 ms. The target program compiled at frame 0 (58.49 ms in this salted run),
before gameplay; its input registrations were observed from frame 7 and again
at frames 326, 327 and 433 at different upload addresses. During the forward
walk at frames 750–959 there were **zero program or pipeline compile events**.
The maximum sampled present gap was 43 ms, versus 59–63 ms in recent runs with
preparation deliberately disabled. This single comparison establishes removal
of this compilation, not elimination of all possible frame-time spikes.

The final screenshot was inspected and confirmed the station route. Primary
saves, settings and caches were preserved, and the bounded game run exited.
The standalone trace regressions passed and the runtime built. There was no
additional gameplay sweep. Earlier reports that this ~40 ms compilation was
still unresolved described cold-cache experiments with catalog preparation
turned off; they did not establish a missing recipe or a broken cache. No new
rendering fix or extra early-worker feature is required for this covered case.

The follow-up opt-in [early compilation experiment](shader-early-experiment.md)
records the implementation limits and the single off/on station comparison.
