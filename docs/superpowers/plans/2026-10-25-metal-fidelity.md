# Metal Fidelity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans for inline execution. The user delegated execution choices and requested continuous work without check-ins.

**Goal:** Repair confirmed NVN/Metal correctness gaps and leave runnable GPU regressions.

**Architecture:** Test existing renderer implementations with a real offscreen Metal device; repair the responsible texture-view, clear and direct-draw code. Keep shader-surface work independent.

**Tech Stack:** Objective-C/C, Metal, existing Makefile/runtime objects.

**Spec:** `docs/superpowers/specs/2026-10-25-metal-fidelity-design.md`

## Global Constraints

- Preserve macOS compatibility, original saves/settings, unrelated edits and existing interfaces.
- No game assets, generated game code, mocks or new dependencies in commits.
- Leave SUST/SURED/SULD and visibility-query protocol to their separate workstreams.
- Prove native results before claiming a fix; record findings in Hindsight.

## Review Focus

- Clamped mip/layer starts must not create empty/overflowed Metal ranges.
- Cube arrays use face slices; partial views must have a compatible Metal type.
- A clear must restore its own raster state and allow later guest bias to be restored.
- Clear pipeline descriptors must match all attachments and multisampling.
- Zero-instance direct draws must not suppress valid GPU-controlled indirect draws.

### Task 1: Asset-free GPU harness

**Files:** `tools/test_metal_backend.m`, `tools/test_metal_renderer.m`, `Makefile`.

**Interfaces:** `metal_test_bootstrap(void)` initializes the real Metal backend; `metal_renderer_test_main(int,char **)` runs selected cases. Link real runtime objects excluding the two production objects included by the test TUs.

- [x] Add a clear/report smoke test using actual CmdRec execution, pixel readback and GPU-error checks.
- [x] Build/run `make B=build/za202 test-metal-renderer CASE=smoke`.
  Expected: all 16 pixels red, positive sample count, nonzero timestamp, exit 0.
- [x] Commit the harness and design/plan.

### Task 2: Texture view correctness

**Files:** `runtime/nvn/renderer.m`, `tools/test_metal_renderer.m`.

**Interfaces:** existing `view_texture` and `apply_swizzle`; no production API changes.

- [x] Write cases for mip/layer starts at and beyond the end, explicit layer `0+1`, cube face 5, cube-array face 11, mip-restricted cube and explicit zero swizzle.
- [x] Run each case before editing production code. Expected: current implementation fails the corresponding property or Metal range check.
- [x] Fix starts/counts/type/identity checks and explicit zero swizzle handling.
- [x] Run `make B=build/za202 test-metal-renderer CASE=views` and the smoke case. Expected: exit 0.
- [x] Commit the fix and tests.

### Task 3: Clear state and pipeline compatibility

**Files:** `runtime/nvn/renderer.m`, `tools/test_metal_renderer.m`.

**Interfaces:** existing `clear`, `attachment_formats`, `draw`; shared synthetic fullscreen-triangle fixture in the test TU.

- [x] Reproduce inherited wireframe and depth bias on clear; verify exact depth 0.5 and full color coverage.
- [x] Reproduce bias restoration after clear with the same guest bias and encoder.
- [x] Exercise color attachment format changes and depth-only sample counts 1 and 4, failing on GPU errors.
- [x] Fix clear state, bias-cache invalidation, full pipeline-key attachment formats and depth sample-count derivation.
- [x] Run `make B=build/za202 test-metal-renderer CASE=clears` and the full suite. Expected: exit 0.
- [x] Commit the fix and tests.

### Task 4: Zero-instance direct draws

**Files:** `runtime/nvn/renderer.m`, `tools/test_metal_renderer.m`.

- [x] Reproduce both array and indexed instance counts 0/1 with unchanged/green pixel expectations.
- [x] Verify GPU indirect replay supplies its nonzero proxy count before introducing an early zero-instance return.
- [x] Run `make B=build/za202 test-metal-renderer CASE=draws` and the full suite. Expected: exit 0.
- [x] Commit the fix and tests.

### Task 5: Native sampler semantics

**Files:** `runtime/nvn/renderer.m`, `tools/test_metal_renderer.m`.

**Evidence:** the game uses MIN reduction with nearest-mip filtering and opaque-white borders. Native M5 probes confirm MIN/MAX at nearest or linear mip filtering and sampler bias on explicit LOD; do not change the requested filters or also add bias in shaders.

- [x] Add real GPU sampling cases through `sampler_for` for average/MIN/MAX, three standard border colors, and positive/negative bias on colored mips; observe the failures first.
- [x] Map standard border colors, and map reduction/bias with SDK and runtime macOS 26 guards. Preserve the older-OS fallback and report unsupported tests as skipped.
- [x] Run the sampler cases, the full GPU suite with Metal validation, and the normal runtime build.
- [x] Commit the tested change and record platform limits in Hindsight.

### Task 6: Corrections from review and game validation

- [x] Reproduce sampled and partial cube-face views; choose a compatible 2D/array type for face ranges that cannot be cube views.
- [x] Reproduce depth-only draw cache reuse across sample counts; include depth sample/view fields in the fast key.
- [x] Reproduce the game's Metal validation error for layer-writing vertices; derive active pass layers from all attachment views, including depth-only passes. Clear every active layer.
- [x] Reproduce the next live-game validation error in scissor bounds with mip and unequal attachment extents; use the minimum native view dimensions for the pass.
- [x] Run the complete GPU suite and normal build; obtain follow-up review of these corrections.

### Task 7: Typed sampled textures

**Evidence:** validated game startup binds R8Uint to a translated `texture<float>` fragment argument and aborts. Extend the existing stencil/type specialization at the renderer/translator boundary; preserve integer result bits and specialize both graphics and compute caches when bound formats change.

- [x] Add real graphics and compute GPU regressions for integer texel reads, sampled reads, gathers, typed fallbacks, signed/unsigned/float rebinding and view format overrides; observe failures before implementation.
- [x] Derive texture scalar kinds from bound effective formats, emit compatible native texture types and preserve result bits. Include kinds in program cache keys.
- [x] Reproduce and fix the larger vertex key's abbreviated-string collision and effective view format loss through feedback snapshots.
- [x] Run the full GPU suite, runtime build and targeted review. Include feedback-view lifetime, empty-descriptor cleanup and a 1,000-program floating-path comparison.

### Task 8: Depth/stencil attachment state

**Evidence:** the validated game now passes the integer-texture blocker and fails after frame357 because a depth/stencil state enables stencil faces without a stencil attachment. Enabled guest tests must be ignored when their attachment aspect is absent, and both state cache paths must distinguish those aspects.

- [x] Reproduce missing-stencil and depth/stencil attachment transitions in real GPU draws.
- [x] Gate native tests on available attachment aspects and include those aspects in fast and slow depth/stencil keys.
- [x] Run the full GPU suite and normal build; review the change.

### Task 9: Game validation and review

- [x] Run the rebuilt runtime using local game files and scratch save/settings; capture idle, movement, turns and dialogue; attempt available scene transitions and record unexercised paths.
- [x] Inspect screenshots and runtime/GPU errors; distinguish surface-image flicker from these fixes.
- [x] Review the branch independently; integrate only verified changes without replacing unrelated work.
- [x] Record tests, limitations and next confirmed gaps in Hindsight and continue the authorized porting work.

### Task 10: Identify the remaining indirect-count variation

- [x] Extend the existing opt-in indirect log with vertex/fragment program addresses; preserve the existing record prefix and renderer behavior.
- [x] Run a bounded idle capture with scratch files, correlate changing argument groups with their programs, and inspect the relevant shader producers before selecting a fix.
- [x] Record evidence and limits in Hindsight. Keep hypotheses separate from confirmed artifacts and leave SUST/SURED/SULD unchanged until their effect is established.

The correlated 14/0 batch uses 576 indices and an alpha-discard material; the three compute programs observed in the station use global buffers without sampled-texture arguments. A temporary MRT0 material highlight did not visibly identify the object, so this probe is inconclusive about whether those count changes cause an on-screen artifact. The diagnostic addresses are run-specific; no culling/shader semantic change was selected from these counts.

### Task 11: Native vertex stream slots

- [x] Reproduce stream 4 overlapping the transform-feedback table and high logical streams exceeding Metal's buffer index range.
- [x] Map logical vertex streams to native slots while reserving shader constants, global memory, transform feedback, debug output and default attributes. Use the same mapping for descriptors and bindings.
- [x] Exercise all logical streams and cache changes in remapped layouts; key every native layout field.
- [x] Run the GPU suite, build, independent review and a normal game check before local integration.

### Task 12: Station NPC disappearance

- [x] Capture a deterministic walk with frame-paired images and identify the NPC supplied by the user.
- [x] Trace every attachment slot and distinguish direct character meshes from indirect batches. Add a bounded live `trace <1..120>` command without texture dumps.
- [x] Identify the example NPC by model/view matrices; compare its main and shadow submissions before and after disappearance.
- [x] Probe guest actor-query consumers and repeat the same position after a stop and a second approach.
- [ ] Locate and reproduce the shared cause of missing NPC draw records; verify a fix across multiple NPCs before integration.

The woman's matching main draw records are absent in frames778–779 and present in813–814, with seven meshes in the latter. A stop at the same position reproduces absence at780 and presence at810. In a bounded CPU probe all180 sampled query results reported visible. A visibility/query graph node was invalidated and its storage reused, but this does not establish persistent render-model replacement. Draw logging occurs after program-readiness checks; its absence alone does not prove a missing guest command. Later probes joined an actual indexed NVN emission to the render input and found matching entries missing in frames750–780, while their local frustum gate passes when they exist. The input arrays are rebuilt and their storage capacity differs from their active count. A same-run producer/owner join subsequently captured destruction of the graphics component that emitted the matched meshes. Its parent model cleanup resolves to the same owning data through the weak-reference control block. This proves component removal upstream of Metal, but does not identify the requester or prove destruction of the logical NPC. No active CLOD cleanup was recorded in the sampled transition window; the parent model readiness value alone is not an unload request. A longer ordinary stop also recovers all seven main meshes and their shadows before moving again. These observations narrow the search; they do not establish a culling, LOD or streaming root cause. Game files and generated code remain unchanged.

### Task 13: Hi-Z mip-chain feedback

- [x] Verify upstream `pokemon-za` commit `7995e46` and the matching Metal mip-zero-only snapshot.
- [x] Reproduce wrong intermediate color and depth mip values with native GPU draws before editing production code.
- [x] Sample higher-mip attachment draws in place; retain snapshots when another attachment writes effective mip zero, a mip view is unset, or a single-level view clamps to zero.
- [x] Verify both mip chains across two base values and all pixels, the base-alias controls, all 51 GPU cases with validation, normal build and focused review.
- [x] Complete the same-input game A/B and distinguish the confirmed GPU repair from the station NPC lifecycle investigation.

The original resolver yields mip2=0.375 instead of0.5 in both color and depth chains. The corrected resolver produces every expected intermediate level. This establishes the Metal defect. The before/after game runs both exited0 and reproduce the example NPC absent at780 and present afterward, so this repair does not resolve Task12. A separate run with Metal validation exercised the station and scripted walk for150 seconds through about941 presents without a native validation failure; the bounded runner ended it before the requested1002 screenshot. Upstream `ca6c21e` changes a Vulkan-only XFB mirror lookup; Metal has no matching mirror. `5a9fb4a` is a separate translator optimization and has not been applied.

### Task 14: Project executable name

**Goal/design:** The app already uses the project name MonZaMac. Build and launch its executable as `monzamac` (`monzamac.exe` on Windows), with matching bundle and package entries. Retain the existing save/data directories, bundle identifier, environment variables, guest-library names and upstream attribution so existing user data remains usable.

- [x] Update Makefile executable/import-library paths, Windows runtime lookup and current launch/package scripts; preserve historical upstream documentation.
- [x] Include the Windows host executable name in the guest-library identity so cached DLLs importing the old host are rebuilt. Make identity consumers rebuild when the Makefile changes.
- [x] Update active build/run documentation and Linux desktop/AppRun entries.
- [x] Verify native build and GPU suite, shell/Python syntax, all platform Makefile expansions, unchanged macOS guest identity and a scratch game launch under the new executable name.
- [x] Check bundle entrypoint metadata and focused review, then commit and integrate the verified changes.

## Validation checkpoint

- Published renderer checkpoint: primary `main`, `codex/metal-fidelity` and `monzamac/main` are at `11b1fa9`; push to the MonZaMac remote succeeded. The reviewed live trace diagnostics also pass 48/48 GPU cases with validation. NPC Task12 remains open, and its diagnostic changes are distinct from a production fix.

- Task11 adds physical vertex-buffer slot allocation around active shader bindings and keys every native layout. All 48 GPU cases pass with validation after rebuilding; an independent review found no actionable issues. The exact rebuilt binary (SHA-256 `626bcfa886ba1fed5a6f4a8eec2eb77bf15fdddb99c2883354d8fc0a49e0538b`, PID11550) reached the station with Metal validation, exercised walking, turns, camera and NPC dialogue through t=109.5/frame1903 without errors, and exited0. A separate normal run of the same binary (PID12509) reached30fps and exercised movement. Original saves/settings remain untouched.

- Apple M5, macOS 26.5.1: **45/45** real GPU cases pass with `MTL_DEBUG_LAYER=1` in both the isolated branch and the merged primary checkout. Normal runtime builds and minimum-macOS-15 availability checks pass. Existing warnings remain.
- A 1,000-program comparison with the preceding translator produced 634 matching translations and 366 matching failures, with zero differences for the pre-existing floating/default-key path.
- The exact rebuilt binary, checked by SHA-256 and PID, ran with Metal validation for 441.9 seconds / 9,162 presented frames. Idle, walking, turns, camera changes and an NPC dialogue were exercised with zero validation, shader or pipeline errors. A separate normal run reached the same starting scene at about 30 fps and exited normally.
- Local `main` was fast-forwarded through `08c9beb`; the merged checkout also passed all 45 cases and rebuilt. Original saves/settings and the pre-existing untracked `save.newgame/` were preserved. Nothing was pushed. The worktree is retained for the continuing investigation and ignored evidence.
- Coverage at this October 25 checkpoint was the station and its platform, not the full game. Attempts to reach the city did not exercise an exterior transition; battles and later areas remained untested. This checkpoint predates the CPU-ordering fix; see the October 27 follow-up below.
- A subsequent idle audit collected 30,000 indirect records through frame 784 and a screenshot at frame 900. The historical 137-instance group was absent, so a direct flip-rate comparison is invalid. Some main-view groups still vary between zero and positive counts (one 14/0 group changed in 131/284 adjacent pairs); their identity and whether that variation is legitimate remain unverified. SUST/SURED/SULD are unchanged.

Evidence stays in ignored `build/fidelity-play`, `build/culling-native/current-20261025` and build test logs. Reproduce the asset-free cases with the Makefile target above; game checks require the user's own extracted files and scratch saves.

## Follow-up — October 27, 2026

- The intermittent startup freeze was traced to guest RCsc load ordering being weakened by Apple Clang: guest `LDAR`/`LDAXR` could become RCpc `LDAPR` in the CPU helpers used by the work-stealing queue. Changing `ldaN` and `ldxN` to sequentially consistent loads restores `LDAR`. The baseline store-buffering test observed forbidden outcomes; the corrected helper test and the 77-case Metal renderer suite passed.
- A complete develop build and monitored live run loaded the updated game library and reached frame 26,118 / t=556.8 at about 60 FPS with no skipped draws, beyond the previously observed freeze point. The user reports the startup stall resolved. This is evidence for the startup fix on this machine, not proof that every freeze on every scene or device is fixed.
- The user also reports animated-model shading glitches resolved; the README now removes that item from Known issues. NPC pop-in while walking remains listed as open.
- The freeze fix is in `develop` through PR #23. The develop-to-main promotion PR is tracked separately.
