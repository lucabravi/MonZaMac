# Maxwell shader translator audit

`runtime/nvn/maxwell/translate.c` compared, instruction by instruction, with Ryujinx's shader decoder
(`Ryujinx.Graphics.Shader` 1.1.477: `Decoders/InstDecoders.cs`, `Instructions/InstEmitTexture.cs`,
`InstEmitSurface.cs`, `InstEmitMemory.cs`, `InstEmitConversion.cs`, `InstEmitWarp.cs`, the GLSL backend's
`InstGenMemory.cs` for the meaning of the texture source lists) and, where the two disagree or Ryujinx is vague,
yuzu's `shader_recompiler/frontend/maxwell/translate/impl/*.cpp`. Both the MSL and the GLSL paths were read.

This is a code comparison only: nothing here was run on a Switch, a Mac GPU or in the game. The hand-written
checks are `tools/test_translate.c`'s `cases` mode (`tools/test_translate.sh` runs them first).

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
| TLDS 0 1D.LZ / 1 1D.LL | x Ra, lod Rb | ok |
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
| TLD4 | Dim 28-30, WMask 31-34, .DC 50, toff 54-55, component 56-57; Ra: layer, coords; Rb: offsets (1, or 2 for .PTP), dref; .PTP texel k from register k/2, bits (k&1)*16 / +8 | ok (1D / 3D dims n/a) |
| TEX | Dim 28-30, WMask 31-34, .DC 50, .AOFFI 54, LOD mode 55-57; Ra: layer, coords; Rb: lod / bias, offsets, dref | ok |
| TEX 3D + .AOFFI | z offset (bits 8-11) | **unsure**: only x / y offsets are emitted |
| TEX array index | yuzu masks it to 16 bits | **unsure** (as TLDS 8) |
| TEX.B, TLD, TLD.B, TXD, TMML.B, TXQ.B | | n/a |
| TMML | Ra: layer (skipped), coords; Rd components swapped (comp ^ 1), 8.8 fixed point, z / w = 0 | ok (1D in MSL n/a) |
| TXQ | query 22-27, WMask 31-34, lod Ra; dimension query | ok for width / height / levels. z is always 1: Ryujinx / yuzu return the depth or layer count for 3D / array textures. **unsure** (the slot's type may only be known after the TXQ) |

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
| SHFL MSL | clamp / segment semantics, predicate = source lane valid | ok |
| SHFL GLSL | same | **fixed**: ignored clamp / segment, predicate always true (case `shfl up glsl`) |
| VOTE | source predicate 39-41 (+ invert 42), dest predicate 45-47, mode 48-49, ballot to Rd | ok |
| FSWZADD | swizzle 28-35, per quad lane: a+b, b-a, a-b, b | ok in fragment shaders; other stages emit a + b (Ryujinx uses the lane everywhere): **unsure** |

## Conversions

| Instruction | Checked | Status |
|---|---|---|
| I2F | source format bits 10-11 + sign bit 13, byte select 41-42, dest format 8-9, .NEG 45 / .ABS 49 (float negate after the conversion, as yuzu) | ok. Rounding mode 39-40 ignored (round to nearest); 64-bit sources read as 32-bit: **unsure** |
| F2I | dest size 8-9 + sign bit 12, source format 10-11 (+ half select 41), rounding 39-40, .NEG / .ABS | ok (64-bit destinations written as 32-bit) |
| F2F | formats 8-9 / 10-11, half select 41, .SAT 50, rounding 39-40 + 42 | **fixed**: integer rounding only when the formats are equal (case `f2f f16.f32 no integer round`) |
