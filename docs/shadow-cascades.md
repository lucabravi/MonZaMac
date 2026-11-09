# Shadow cascade filtering

Z-A uses a fixed texel radius for shadow maps covering different amounts of world space. Switching to a wider
cascade therefore increases the filter's world-space blur abruptly. The material shaders and the separate
half-resolution deferred shadow mask must use the same correction; changing only materials leaves the visible step.

The Metal translator recognises the cascade matrix loads, radius load and texture-size reciprocal products.
For each axis it multiplies the PCF radius by the selected cascade's world-to-UV scale divided by the nearest
cascade's scale, capped at one. Width and height are tracked from their texture dimension queries. The nearest
cascade, sample count, depth comparisons, map projections and cascade split distances are unchanged.

The override only applies to the recognised fragment-shader pattern. Incomplete patterns, ambiguous control flow,
perspective projections and invalid scales keep the original filter. GLSL is unchanged. Shadow map resolution and
sharpness remain controlled by the existing Video settings. Matching filter widths does not recover the distant
cascade's missing spatial detail; lower resolutions can still look more pixelated.

Enabled automatically. For an original-filter comparison, restart with `LARECOMP_SHADOW_CASCADE_FILTER=0`.
This changes translated shader source; the precompile stamp version is incremented so prepared shaders are refreshed.
No game shader files are distributed.

Run `python3 tools/test_shadow_cascade.py` for asset-free instruction-recognition tests and, on macOS, native Metal
compilation and GPU math checks. In-game validation used the station at render scale 1.5x, with shadow quality 1x
and 4x. The user confirmed the abrupt boundary was gone while a difference in distant detail remains. Other locations
and game versions have not been visually verified.

## Smooth shadow edges

Each of the game's 16 shadow taps is one hard test against one map texel (lit = reference >= the map's depth), so a
shadow's edge follows the texels. In close-ups (cutscenes: a Pokémon is about 25 texels tall in the game's 1024 map)
the edge is a staircase, and a larger map only makes the steps smaller.

In the same recognised fragment-shader pattern, the translator keeps where each tap of the depth map was taken and
replaces the tap's own test with `shadow_tap_lit`: the same test on the four texels around the tap, blended by the
tap's position between them. Each texel is compared with the depth the receiver would have there (the receiver's
slope in the map, from the screen derivatives of the tap's coordinates and of the reference): without that, a surface
tilted to the light fails the test in the neighbouring texels and darkens everywhere. A tap the game's self-shadow
guard zeroed stays lit, as in the game's own test. The game's tolerance for that guard is too wide to stand in for
the slope: used alone it lights everything.

Tap count, radius, cascade choice and the self-shadow guard are unchanged. Enabled with the cascade filter; for the
game's hard test, restart with `LARECOMP_SHADOW_SMOOTH=0`. It needs the cascade pattern: where that is not recognised
(or `LARECOMP_SHADOW_CASCADE_FILTER=0`) the taps stay as they are.

Seen in game in one cutscene (three Pokémon on the plaza, shadow resolution 2x, render scale 1.5x): steps gone, same
light and shadow darkness as before. Not checked: other places and times of day, characters' self-shadowing, the cost.
The screen derivatives are taken inside the shader's control flow: at a triangle or cascade border they can be wrong
for a pixel.
