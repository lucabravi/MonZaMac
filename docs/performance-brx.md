# Structured BRX control flow

## Implementation

The translator normally emits a `switch (pc)` loop for shaders with branches. The
structured path (on by default; `LARECOMP_STRUCTURED_FLOW=0` turns it off) emits proven acyclic control flow as native conditional blocks and small
direct switches. Incoming edge predicates merge before a block executes; accepted shaders no longer need the
PC loop or SSY/PBK arrays. Genuinely never-executed instructions (`@!PT`) are skipped. Unsupported unpredicated
PCNT/PRET instructions keep the dispatcher regardless of the value of their unused predicate bits.

Computed targets come from compiler-owned c1 tables. The recognizer requires consecutive unsigned immediate
MIN, shift-left-by-two, 32-bit c1 load and BRX instructions, validates their register chain and predicates,
checks table bounds and forward destinations, and rejects incoming edges that bypass the bound. Token-stack
states must agree at every reachable merge. Backedges, unbounded tables, ambiguous stacks and unsupported flow
retain the original dispatcher. The existing entry point without compiler constants and GLSL also retain it.

The renderer supplies embedded program constants for fragment and compute translation. Successful fragment
specialization logs `[shader] structured FS ...`; the switch is read at translation time and requires a restart.

## Programs without a jump table

The same path also takes fragment programs whose only flow is forward SSY/SYNC/BRA/BRK/EXIT (no BRX), except:

- the `BRA` to itself the compiler pads after the last `EXIT` is skipped (it is never reached; a reachable one keeps the
  dispatcher). Its offset is -16, not -8, when the slot before it is a scheduling word: the target is compared after
  normalising, like every other target.
- programs that read the facing flag (attribute `0x3FC`) keep the dispatcher: with the structured flow Metal's GPU
  compiler aborts on `cannot select ...` for the flag converted to float (found from the compiler service's crash report,
  see "When Metal's compiler rejects a translated shader" in `docs/development.md`).

Starting scene, 1.5x, 4K shadows, uncapped frame rate, four alternating off/on pairs (develop vs this change): 63.2 ->
64.7 fps (+2.4%), GPU 15.79 -> 15.40 ms (-2.5%), CPU 15.07 -> 14.72 ms (-2.3%). With the 60 fps cap the same pairs gave
GPU 16.26 -> 15.90 ms and CPU 10.84 -> 10.21 ms. The half-resolution pass that prompted it did not get faster (0.97 -> 0.98 ms by `gpupass`),
so the gain comes from the other programs that stopped using the loop. A first pair that looked like -6.5% GPU was a
mistake: one program failed to compile and its draws were skipped.

## One A/B comparison on Apple M5

Base: `develop` at `3ea2ae0`, Apple M5, macOS 26.5.1. Same copied plaza save and initial-confirmation replay,
1.5x rendering (2880×1620), 3600×2016 drawable, steady 60 fps, CPU/GPU overlap and XFB barrier enabled. Sharper
textures and 4K shadows were enabled, matching the current local settings. User saves/settings were untouched.

Each run measured 300 warm frames, 1000–1299. Frame-900 screenshots were collected outside the timing window.
Metal HUD/capture and background shader warm-up were disabled. The private pipeline archive was invalidated
before compiling the changed MSL. GPU time is the existing interval-union measurement between presents.

| Mode | FPS | Median frame ms | Median GPU-union ms |
| --- | ---: | ---: | ---: |
| Disabled | 47.68 | 20.8045 | 20.8035 |
| Enabled | 60.00 | 16.7120 | 16.7115 |

The measured GPU-window value fell by 19.7%; FPS reached the configured 60 fps limit. This is one off/on pair
in one scene, not a general performance guarantee or an exclusive per-shader hardware timing.

The dominant fragment program was confirmed to use the new path. Its generated shape changed from one PC
switch with 49 case labels to two direct switches with eight case labels, without SSY/PBK arrays. Only numeric
metadata is recorded here; game code, shaders, dumps and screenshots remain local.

## Verification and pending checks

- A synthetic 32-lane GPU case covers a bounded computed switch nested in SSY/PBK, conditional SYNC,
  reconvergence before SHFL, exact outputs, and fallback for incomplete tables or backward destinations.
  The activation assertion failed before implementation and passed afterward.
- Metal API Validation: **86/86 renderer tests passed** with the path enabled.
- The runtime built successfully using the existing complete game library.
- Manual visual/gameplay verification and independent code review are pending. No claim of visual equivalence
  is made yet. Battles, other scenes/Macs and long play sessions have not been tested.

To compare against the original path, run with `LARECOMP_STRUCTURED_FLOW=0`. Further performance
work starts with one 1.5x off/on pair per actual modification; expand only when there is a useful signal.
