# P11: cold shader compilation in the station

Measured on Apple M5, macOS, 2026-10-29, at `develop` commit `54c9f41`.
P11 has a measurable first-use target, predominantly at scene entry. The
existing cache already removes the measured compilation hitch on a repeat
visit. These results do not establish a steady-state FPS optimization.

## One cold/warm pair

The runtime was rebuilt from the stated commit and loaded the existing P1
game library. Both runs used a private copy of the same station save, 1.5x,
dynamic 60 fps, shader waiting enabled, CPU/GPU overlap and the XFB barrier
enabled. Uncapped mode was explicitly off. The user's save and cache were
untouched.

The first run had an empty application cache. A unique `LARECOMP_SHADER_SALT`
was used to perturb Metal source-cache keys; the same salt was retained for
the warm run. This is not a guarantee that every OS/driver cache was cold.
The second run reused the first run's shader cache and pipeline archive.

Both runs were visible, launched through `tools/hang_sample.sh`, and bounded
externally to 100 seconds. Scripted input pressed A at frame 300 for five
frames, then held the left stick forward at frame 750 for 360 frames. A
window screenshot at frame 1250 confirmed the station and ended each run.
The screenshots show slightly different final positions/NPC animation;
this is a same-route comparison, not a pixel-identical replay.

Existing renderer statistics were logged every 0.25 seconds. Windows were
grouped by their ending frame: startup <750, walk 750–1109, settling
1110–1249. Boundary windows can straddle the input transitions.

| Measurement | Empty application cache | Reused cache |
| --- | ---: | ---: |
| Startup compile operations | 300 | 155 |
| Startup reported compile time | 7,567 ms | 8 ms |
| Largest startup present gap | 5,219 ms | 194 ms |
| Walk compile operations | 13 | 6 |
| Walk reported compile time | 38 ms | 0 ms (rounded) |
| Largest walk present gap | 59 ms | 21 ms |
| Walk reporting windows with a gap >33 ms | 1 | 0 |
| Draws skipped for compilation, whole run | 0 | 0 |

The largest cold gap was reported at frame 455: 145 compilation operations,
5,024 ms compile time and a 5,219 ms present gap. The largest warm gap was
at frame 457: 65 compilation operations, 4 ms compile time and a 194 ms
gap. The remaining warm gap is not explained by shader compilation alone.

`stat_compile_ms` sums timed shader/pipeline construction; it is not a GPU
duration or a general measure of blocking time. Counts are operations, not
unique shaders. Reported times are integer milliseconds, so zero does not
mean no work. Archive-hit construction and background warm-up are not
included in that counter. The warm run separately reported 150 cached
shaders warmed in 5,703 ms and 150 pipeline archive hits. The archive saved
successfully. Zero skipped draws is expected with shader waiting enabled;
it does not imply there were no stalls.

## Feasibility: the upstream implementation is not drop-in

LASRecomp's `shader_prep` combines variant records containing shader hashes
and pipeline state with an index into the user's own game files. Its RomFS
scanner handles loose `.bfsha`, `.ptcl` and `.arc` files, plus embedded BNSH
containers in the executable's data segments.

This Z-A installation contains **zero loose files with those extensions**.
Its Trinity directory has 13,181 pack names, 14 containing `shader`, of
which three also contain `bnsh`. This is a metadata count, not proof that
all shaders are in those 14 packs. Executable-embedded shaders were not
enumerated in this experiment. Copying the upstream directory scanner
would therefore miss the RomFS shader packs.

The repository already has read-only Trinity parsing in
`tools/za/trinity.py`; its Oodle decompressor is an external library used by
development tools, not a proven bundled runtime dependency. An offline
Z-A shader index must account for that archive/decompression boundary.

Upstream `ShaderRec` also does not encode all the current Z-A specialization
inputs: transform-feedback layout/void vertex shaders, sampled signed and
unsigned texture slots, stencil slots, storage-image scalar types and
varying masks. Omitting those from prepared-object identity could reuse an
incompatible program. Preparation must share the live translator and
pipeline-descriptor construction, retaining ordinary compilation on a miss.

## Decision and next bounded step

Keep P11 open: the cold scene-entry stall is significant and the walk has
one smaller compilation-associated hitch. Do not implement another cache
just to improve repeat visits; the present implementation already works
for this measured route. Do not start P14 under the assumption that P11's
measurement was negative.

Before a full P11 implementation, validate a Z-A-specific shader index
against the shaders actually encountered in this station route, and define
complete variant identity from the existing `ShaderKey` and pipeline state.
Only hashes, metadata and code may be distributed; shader bytes, MSL,
compiled pipelines and game assets remain local. Preparation should move
work before gameplay, not promise to eliminate compilation cost. Scope the
first implementation to this measured scene with fallback for uncovered
variants, then use one cold baseline/changed pair to assess it.

P14 remains a separate setup optimization. Code inspection confirms that
`gamebuild_run` deletes `.gamebuild` on entry and exit, so completed objects
cannot currently survive interruption. Its follow-up needs content-based
invalidation (source, compiler, flags, headers, generator/ABI), locking,
atomic publication and explicit cleanup. No P14 code or build conversion
was run during this investigation.

No renderer behavior was changed. No heavy Metal capture or additional
gameplay sweep was performed. Private logs and screenshots are excluded
from this document and from Git.
