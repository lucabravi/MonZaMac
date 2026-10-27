# Maxwell shader translator audit

`runtime/nvn/maxwell/translate.c` compared, instruction by instruction, with Ryujinx's shader decoder
(`Ryujinx.Graphics.Shader` 1.1.477: `Decoders/InstDecoders.cs`, `Instructions/InstEmitTexture.cs`,
`InstEmitSurface.cs`, `InstEmitMemory.cs`, `InstEmitConversion.cs`, `InstEmitWarp.cs`, the GLSL backend's
`InstGenMemory.cs` for the meaning of the texture source lists) and, where the two disagree or Ryujinx is vague,
yuzu's `shader_recompiler/frontend/maxwell/translate/impl/*.cpp`. Both the MSL and the GLSL paths were read.

The initial audit was a reference-code comparison. The local follow-up adds native Metal GPU regressions in
`tools/test_metal_renderer.m` (group `audit`) and compiler validation; no physical Maxwell or Vulkan GPU execution
is claimed. The operand-layout checks remain `tools/test_translate.c`'s `cases` mode.

Status: **ok** matches; **fixed** wrong before this audit (commit in the branch history); **unsure** a
difference or a gap worth an in-game check; **n/a** not translated (the shader fails to translate, loudly).

## Textures

| Instruction / target | Checked | Status |
|---|---|---|
| TEXS fields | Rd 0, Ra 8, Rb 20, Rd2 28, handle 36, WMask 50-52 (+ Rd2 == RZ mask LUT), target 53-56, .F16 = bit 59 clear | ok |
| TEXS 0 1D.LZ | x = Ra, LOD 0 | **fixed** (GLSL used an implicit LOD; MSL 1D has no mips) |
| TEXS 1 2D / 2 2D.LZ | x Ra, y Rb | ok |
| TEXS 3 2D.LL / 4 2D.DC / 6 2D.LZ.DC | x Ra, y Ra+1, lod or dref Rb | ok |
| TEXS 5 2D.LL.DC | x Ra, y Ra+1, lod Rb, dref Rb+1 | ok per yuzu (`ImageSampleDrefExplicitLod(.., F(reg_b+1), F(reg_b))`) and TEX's own Rb order (lod before dref). Ryujinx's EmitTexs reads dref = Rb, lod = Rb+1. **unsure** which one hardware does; case `texs 2d ll dc` pins the current choice |
| TEXS 7 / 8 ARRAY_2D(.LZ) | layer Ra (clamped), x Ra+1, y Rb | ok |
| TEXS 9 ARRAY_2D.LZ.DC | layer Ra, x Ra+1, y Rb, dref Rb+1 | layout ok; **fixed** the layer was not clamped (MSL, GLSL) |
| TEXS 10 / 11 3D, 12 CUBE | x Ra, y Ra+1, z Rb | ok |
| TEXS 13 CUBE.LL | x Ra, y Ra+1, z Rb, lod Rb+1 | ok |
| TLDS fields | as TEXS, .F16 = bit 59 clear | ok |
| TLDS 0 1D.LZ / 1 1D.LL | x Ra; LOD 0 for .LZ, Rb for .LL | ok |
| TLDS 2 2D.LZ | x Ra, y Rb | ok |
| TLDS 4 2D.LZ.AOFFI | x Ra, y Ra+1, offsets Rb bits 0-3 / 4-7 | ok |
| TLDS 5 2D.LL | x Ra, y Ra+1, lod Rb | ok |
| TLDS 6 2D.LZ.MS | x Ra, y Ra+1, sample Rb | n/a |
| TLDS 7 3D.LZ | x Ra, y Ra+1, z Rb | ok |
| TLDS 8 ARRAY_2D.LZ | x Rb, y Rb+1, layer Ra | **fixed** in 862e49e (before this audit; case `tlds 2d array`). yuzu masks the layer to Ra's low 16 bits, Ryujinx does not, nor do we: **unsure** |
| TLDS 12 2D.LL.AOFFI | x Ra, y Ra+1, lod Rb, offsets Rb+1 | ok |
| TLD4S fields | component 52-53, .AOFFI 51, .DC 50, .F16 = bit 55 (0xdf8) | ok |
| TLD4S coordinates | x Ra, y Rb; with .DC or .AOFFI y Ra+1 | ok |
| TLD4S .AOFFI + .DC | offsets Rb (6-bit at 0 / 8), dref Rb+1 | ok per yuzu; Ryujinx reads dref first (Rb) and the offsets from Rb+1. **unsure** |
| TLD4 | Dim 28-30, WMask 31-34, .DC 50, toff 54-55, component 56-57; Ra: layer, coords; Rb: offsets (1, or 2 for .PTP), dref; .PTP texel k from register k/2, bits (k&1)*16 / +8; component k = texel i0j0 (gather .w) at offset k (ARB_gpu_shader5, yuzu textureGatherOffsets) | fixed: was component k of gather k |
| TEX | Dim 28-30, WMask 31-34, .DC 50, .AOFFI 54, LOD mode 55-57; Ra: layer, coords; Rb: lod / bias, offsets, dref | ok |
| TEX 3D + .AOFFI | z offset (bits 8-11) | **unsure**: only x / y offsets are emitted |
| TEX array index | yuzu masks it to 16 bits | **unsure** (as TLDS 8) |
| TEX.B, TLD, TLD.B, TXD, TMML.B, TXQ.B | | n/a |
| TMML | Ra: layer (skipped), coords; Rd components swapped (comp ^ 1), 8.8 fixed point, z / w = 0 | ok (1D in MSL n/a) |
| TXQ | query 22-27, WMask 31-34, lod Ra; dimension query | ok for width / height / levels. z is always 1: Ryujinx / yuzu return the depth or layer count for 3D / array textures. **unsure** (the slot's type may only be known after the TXQ) |

### Scaled screen-space integer reads (Metal)

Render-target allocations can be larger than their guest dimensions. Converting fragment position to guest
pixels, truncating it, and then fetching the centre of that guest texel repeated pixels in deferred lighting:
raising internal resolution to 1.5x or 2x produced more jagged edges instead of preserving the extra samples.

The Metal translator now carries the fractional position through ALD/IPA position.x/y, register MOV, and unmodified
F32-to-I32 floor/truncate conversions into the individual TLDS coordinate. Metadata follows runtime predicates
and branches and resets on other register writes, so a fixed lookup in the same shader stays fixed. Array layers
and explicit LOD values are separate. Other coordinate arithmetic, vertex/compute stages,
and GLSL retain their previous behaviour.

The asset-free `scaled-fragment-fetch` Metal test (`CASE=scaling`) checks physical pixel IDs at 1x, 1.5x, 2x,
1.5x-by-2x and 0.75x, including fixed lookups, mixed screen/fixed reads, MOV, a skipped predicated write, and
explicit-LOD-zero TLDS, and IPA position loads. The original code lost 2,880 of 5,184 pixel IDs at 1.5x; the repaired
path preserves all.

## Surfaces

| Instruction | Checked | Status |
|---|---|---|
| SUST.B | RGBA mask 20-23, dim 33-35, handle register Rc 39; coords Ra, Ra+1 (+ layer Ra+2); data from Rd up | ok (2D / 2D array only, MSL only) |
| SURED.B | op 24-26, size 20-22, value Rd, coords as SUST | ok |
| SURED.B .BA (bit 23) | x is a byte offset (>> 2 for 32-bit) | **fixed** (case `sured ba`) |
| SULD, SUST.D, SUATOM, SURED.P | | n/a |

## Memory

| Instruction | Checked | Status |
|---|---|---|
| LDG / STG | .E 45, size 48-50 (U8 S8 U16 S16 B32 B64 B128 UB128), signed 24-bit offset at 20, Rd... | ok |
| ATOM | Rd 0, Ra 8, Rb 20, signed 20-bit offset at 28, .E 48, size 49-51, op 52-55 (INC / DEC wrap) | ok (U32 / S32 only) |
| RED | value at 0, Ra 8, offset 28, .E 48, size 20-22, op 23-25 | ok. Ryujinx takes RED's offset unsigned; yuzu signed (unsigned only with an RZ base): we follow yuzu |
| LDL / STL | size 48-50, signed 24-bit offset | ok |
| ATOMS | | n/a |

## Warp

| Instruction | Checked | Status |
|---|---|---|
| SHFL fields | mode 30-31, b imm (bit 28) 20-24, c imm (bit 29) 34-46 or Rc 39, predicate 48-50 | ok |
| SHFL MSL / GLSL | B uses low five bits; UP tests maxLane; clamp / segment and valid predicate | **fixed**: GLSL now shares these rules; the local review also corrected unmasked register B and the UP bound in the shared path |
| SHFL participation | shuffle executes before selecting the local-value fallback | **fixed**: conditional subgroup calls could exclude a lane still needed as another lane's source |
| VOTE | source predicate 39-41 (+ invert 42), dest predicate 45-47, mode 48-49, ballot to Rd | ok |
| FSWZADD | swizzle 28-35, per quad lane: a+b, b-a, a-b, b | ok in fragment shaders; other stages emit a + b (Ryujinx uses the lane everywhere): **unsure** |

## Conversions

| Instruction | Checked | Status |
|---|---|---|
| I2F | source format bits 10-11 + sign bit 13, byte select 41-42, dest format 8-9, .NEG 45 / .ABS 49 (float negate after the conversion, as yuzu) | ok. Rounding mode 39-40 ignored (round to nearest); 64-bit sources read as 32-bit: **unsure** |
| F2I | dest size 8-9 + sign bit 12, source format 10-11 (+ half select 41), rounding 39-40, .NEG / .ABS | ok (64-bit destinations written as 32-bit) |
| F2F | formats 8-9 / 10-11, half select 41, .SAT 50, rounding 39-40 + 42 | **fixed**: integer rounding only when the formats are equal. Directed conversion rounding and 64-bit formats remain unimplemented / unverified |

## Local verification notes

NVIDIA's [PTX shfl.sync definition](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#data-movement-and-conversion-instructions-shfl-sync)
specifies `bval = b[4:0]` and the UP predicate `j >= maxLane`. This agrees with yuzu; Ryujinx 1.1.477 instead
uses minLane for UP. The follow-up deliberately follows NVIDIA's specified boundary, and records this reference
disagreement rather than treating the emulator implementations as unanimous. The native vectors include nonzero
UP clamp, register B=32, and segmented quads, checking both the value and predicate for every lane.

All active lanes execute the shuffle before fallback selection. GLSL evaluates only the selected ternary operand,
and a shuffle from an inactive invocation is undefined; placing the intrinsic inside `ok ? shuffle(...) : own`
can therefore remove a source needed by another invocation. The same unconditional structure is used for Metal.

Native F2F vectors use exactly representable +/-1.5 so they isolate unwanted integer rounding without claiming
support for directed half conversion. SURED has byte-address and ordinary-address controls checking every texel.
The depth-array test includes layers 0,1,7 against two distinct depths; both the original main translator and the
explicitly clamped version return the same expected values on Apple M5, so this test does not demonstrate a
previously visible failure there. Vulkan execution and other devices remain unverified.

The fuzz wrapper now checks each worker's exit status and prints only that invocation's worker logs. Previously,
a failed worker could be hidden by bare `wait`, and logs left by an earlier run with more workers were printed
as current results. `REF=HEAD` is useful for uncommitted output changes; comparing a clean commit to itself is
not an independent compatibility check.

## PBK/BRK reconvergence

A flat per-invocation PC dispatcher can execute the code after BRK while neighbouring lanes are still in the
loop. This can corrupt implicit texture derivatives. Simple forward PBK regions now run in a local structured
dispatcher so lanes rejoin before their continuation. Instructions, texture coordinates and implicit LOD are
preserved; the shared instruction watchdog also bounds the local dispatcher.

Regions with incoming interior edges, escaping branches, nested token setup, SYNC or CONT retain the flat
dispatcher. BRX disables this transformation for the entire shader because its destinations are dynamic.
This is a conservative improvement for simple regions, not a complete control-flow reconstruction.

On Apple M5, a replay of the starter scene fixes the dotted sclera and broken iris shading of Chikorita, Tepig
and Totodile without shader overrides. A live original/local-dispatcher/original control reproduces the defect,
removes it, then restores it. The asset-free GPU test checks a lane-varying PBK loop followed by SHFL against
CPU loop results. That shorter test also passes with the old translator on M5, so it does not independently
reproduce the visual failure. Other scenes, hardware and Vulkan execution remain unverified.
