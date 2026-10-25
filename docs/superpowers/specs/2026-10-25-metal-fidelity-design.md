# Metal renderer fidelity

The user authorized autonomous investigation, fixes and game testing while away. This work repairs observed Metal/NVN incompatibilities; it does not claim that one tested scene proves the entire game artifact-free.

## Approach

Extend the existing renderer at the point that owns each invariant. Use real, asset-free Metal execution for focused regressions, followed by the game with scratch saves/settings. This is preferable to game-specific shader overrides or changing game animation/culling logic. Existing Vulkan behavior and native Metal contracts provide references, not automatic proof that a change fixes a game artifact.

The concurrent bindless surface-image initiative owns SUST/SURED/SULD. Keep that work independent. Preserve the verified conservative visibility-counter fallback until a complete native query protocol is implemented and verified.

## First verified gaps

- Clear draws inherit depth bias and wireframe state; a clear must be independent of those guest draw settings and must leave subsequent guest draws able to restore their state.
- Texture views must clamp starts before deriving default counts, count cube faces rather than cubes, and honor explicit layer counts and zero swizzles.
- Clear pipelines must match every attachment format and sample count, including depth-only multisampling.
- Direct instanced draws with zero instances must have no rasterization or shader side effects; GPU indirect draws remain GPU-controlled.
- Samplers must preserve standard border colors. On macOS 26, native MIN/MAX reduction and sampler LOD bias must match the requested values without changing the game's filters. Older SDKs and OS versions retain the existing reduction/bias fallback.
- Partial cube face ranges need a compatible 2D/array intermediate view for both sampling and rendering. Draw pipeline cache keys must include depth samples and depth-view fields.
- Pass layer counts and physical bounds come from the minimum ranges of actual native attachment views, including depth-only passes, mip selection and allocation rounding. Layered clears cover every active layer.
- Texture shader scalar types follow the bound effective view formats; integer reads retain their register bits. Graphics and compute program caches distinguish those type variants.

## Test architecture

Two test-only Objective-C translation units include the production Metal plumbing and renderer respectively. They expose private renderer helpers only inside the test executable, initialize a small real device/queue/buffer, and link existing runtime definitions through an alternate test entry. No production test hooks, mocked renderer, game assets or downloaded dependencies are required.

## Constraints and proof

Keep macOS compatibility, existing public interfaces, original saves/settings and unrelated work intact. No Nintendo files or generated game code enter commits. GPU errors and wrong pixels fail tests. Record RED/GREEN evidence and game observations in Hindsight. Sampler constraints have been probed on M5; verify production mapping through the same GPU harness and explicitly skip unavailable native APIs on older systems.
