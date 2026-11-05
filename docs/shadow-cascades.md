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
