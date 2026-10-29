# Guest compare/branch fusion: Apple Silicon experiment

P1 adapts Hexveil404/PokeZ-ARecomp's MIT `tools/flagfuse.py` at `cff8364`. When a compare's flags have no later reader, the generator emits a direct C condition instead of packing and reading `Cpu.nzcv`. It does not promote registers or change the renderer.

The pass skips functions with instruction patches or jump-table fallback entries. Native assembly conservatively reads flags. External jumps, unresolved indirect branches and function-end fallthrough keep flags live: generated function boundaries can split guest control flow and are not necessarily ABI call boundaries. `--no-flag-fusion` retains the original emission for diagnostics; keep diagnostic libraries separate because generator options are not part of the library identity.

## Verification

- `tools/venv/bin/python tools/test_flagfuse.py`: 208 compiled condition cases, zero mismatches; liveness checks pass.
- `tools/venv/bin/python tools/test_flagfuse_codegen.py`: nine integration tests, including an executed synthetic loop, patch/table exclusions, diagnostic disable and four outgoing-edge regressions.
- The outgoing-edge tests failed against the initial upstream assumptions, then passed after the conservative correction. Independent review found no remaining blocker.
- Regenerated both v2.0.2 modules and built the full game library and runtime with the normal `-O1` generated-code settings and `-j8`.
- Inspected in-game captures at the station. No obvious new rendering defect was observed; this is not full-game correctness verification.

## In-game A/B

One original/fused pair at each resolution on the same Apple Silicon Mac, same station save and input replay, 60 fps dynamic timing, SMAA, higher-quality texture/shadow settings and CPU/GPU overlap enabled. Both variants retain PR #86's NPC budgets. Runs use a private data root, a warm shader/pipeline cache and an external deadline around `hang_sample.sh`; no full Xcode capture. Compilation had finished before measurement.

Input is frame-based, so dynamic timing and small frame-rate differences can slightly change the final position/animation. The scenes are comparable, not pixel-identical. Capture readbacks were requested after the measurement window. The initial 1.5x capture destination was missing; separate bounded smoke captures verified the generated build and the FPS-settings runtime. The 2x A/B captures were saved normally.

Samples cover approximately frames 500–1050. CPU is **total process CPU work across all threads per presented frame**, from `proc_pid_rusage`, converted from Mach ticks using the host timebase (125/3 ns per tick, independently checked against `getrusage`). It can exceed wall time because threads run in parallel; it is not main-thread latency or the F3 renderer-submit counter. GPU values use valid per-present GPU-window samples rather than the old sum of command-buffer durations.

| Scale | Variant | Wall ms/frame | FPS over sample | Process CPU ms/frame | Mean GPU busy ms |
|---|---|---:|---:|---:|---:|
| 1.5x | Original | 16.81 | 59.48 | 25.45 | 16.47 |
| 1.5x | Fused | 16.84 | 59.37 | 25.02 | 16.75 |
| 2x | Original | 22.56 | 44.32 | 22.22 | 22.43 |
| 2x | Fused | 22.57 | 44.30 | 22.63 | 22.72 |

No compilation-skipped draws were recorded in any sample. At 1.5x the largest gap reported in the sampled log windows was 20 ms original / 58 ms fused; at 2x it was 33 / 29 ms. These are isolated maxima, not percentile estimates or established regressions. Valid GPU-sample coverage also differs (483/564 samples at 1.5x, 546/543 at 2x).

**These runs do not demonstrate an in-game speedup.** The small process-CPU decrease at 1.5x reverses at 2x. One sequential pair per resolution, coarse log sampling, cache/thermal variation and the 60-fps/GPU limits do not support attributing changes of this size to P1. Resource-lookup/battle-loading benefits cited upstream have not been measured here. Keep the PR experimental until a relevant CPU-bound benefit is established; do not claim a gain from the reduced generated code alone.

## Static result and deployment cost

Explicit `subs/adds/logic` flag-helper sites in generated C decrease from 706,930 to 504,187 (202,743 fewer). The local game library decreases from 257,706,416 to 247,747,504 bytes: about 9.50 MiB / 3.86%. These are code-size measurements, not frame-time improvements.

`flagfuse.py` is included in `GAMELIB_SRCS`, so changes invalidate installed game libraries as intended. Shipping this generator change requires rebuilding the user's generated game library; it is not a runtime-only update. Game files, generated code, binaries, logs and captures remain private and are not included in the PR.

## Follow-up: uncapped stationary station world

The Developer uncapped-FPS runtime removes presentation pacing and Metal display sync, leaves the VI timer unchanged, and intentionally does not preserve simulation speed. A separate **world** smoke capture at 1x confirms 85–87 fps, so this is not merely a high title-screen frame rate.

Using the same instrumented runtime source with matching library identities, a single original/P1 pair at 1.5x measured a stationary starting-station scene. This differs from the earlier walking route; compare within this pair, not against the capped table above. A later A press avoids the faster startup outrunning the old input script. The world was visually verified at frame 750, before measurement at approximately frames 800–1350. Initial title-screen samples are discarded and are not used below.

| Uncapped stationary world, 1.5x | Original | P1 |
|---|---:|---:|
| FPS over sample | 49.73 | 59.54 |
| Wall ms/frame | 20.11 | 16.79 |
| Total process CPU ms/frame | 33.05 | 29.17 |
| Mean GPU-window busy ms | 20.07 | 16.82 |
| Compile-skipped draws | 0 | 0 |

This pair shows **+19.7% throughput and -11.7% process CPU work per frame**. It is promising evidence in this particular scene, not a replicated or full-game gain. It supersedes the earlier broad recommendation to infer no useful benefit from the capped runs alone. GPU-window intervals can include scheduling/dependency effects; their reduction is not proof that the GPU's shader workload was optimized. The pass changes CPU code only.

The 1x world screenshot smoke exits at its requested frame before the general benchmark harness's later sample endpoint; the resulting wrapper early-exit message is not a native game crash. Captures, logs and measurement scripts remain private. Keep the P1 PR in draft pending review of this new evidence rather than extrapolating 19.7% to normal play or other hardware.


### Repeat: uncapped stationary 1.5x pair

The uncapped setting and interval were checked in each run's log (`present interval 0`, Metal display sync off). Same private save, stationary A-press boot/replay and benchmark settings. A second pair was run once; no more repetitions are planned.

| Pair | Variant | FPS | Total process CPU ms/frame | GPU-window mean ms |
|---|---|---:|---:|---:|
| First | Original | 49.73 | 33.05 | 20.07 |
| First | P1 | 59.54 | 29.17 | 16.82 |
| Repeat | Original | 60.20 | 28.34 | 16.60 |
| Repeat | P1 | 58.90 | 29.56 | 16.94 |

The first apparent improvement did not repeat; the second pair was slightly slower with P1, and the original run varied substantially. Therefore no repeatable performance gain is established. GPU clock/thermal state, asynchronous scene work, and whole-process CPU sampling were not isolated. Treat P1 as an experiment, not a proven optimization. Do not extrapolate the first pair's gain.
