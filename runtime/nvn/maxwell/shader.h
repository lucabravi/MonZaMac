// Maxwell (GM20B) shader translation to Metal Shading Language (macOS) or Vulkan GLSL (Windows; compiled to
// SPIR-V at runtime with shaderc). ShaderKey.glsl selects the dialect; the MSL output does not depend on it.
//
// GLSL contract (what the Vulkan renderer binds):
//  - `#version 460`, entry point `main`. Descriptor set: vertex 0, fragment 1, compute 0.
//  - hardware cbuf k -> binding k: `layout(std140, set=S, binding=k) uniform CB<k> { uvec4 cb<k>[N]; };`
//    (anonymous block). N = max(cbuf_size[k] / 16, highest constant-index vec4 + 1), and at least 4096 when
//    cbuf_dynamic has bit k (the renderer binds up to 64 KB). Register-indexed reads are clamped to N - 1.
//  - global memory (LDG/STG) -> binding GMEM_BUFFER_INDEX (17):
//    `layout(std430, set=S, binding=17) [readonly] buffer GMem { uint w[]; } gmem_;`, 32-bit words relative to
//    maxwell_gmem_base. `readonly` unless the shader stores (needs vertexPipeline/fragmentStoresAndAtomics then);
//    byte / short stores are atomicAnd + atomicOr on the containing word.
//  - rscale table -> binding 18: `uniform RScale { vec4 rscale[65]; };` (std140, the MSL buffer 18 contents).
//  - per-draw tint -> binding 19: `uniform Tint { vec4 ltint[2]; };` (fragment, when uses_tint).
//  - texture slot i (ShaderInfo.tex[i]) -> binding 32 + i, a combined image sampler: sampler1D/2D/3D/Cube/
//    1DArray/2DArray/CubeArray, or its *Shadow variant when tex[i].shadow.
//  - vertex inputs `layout(location=i) in vec4|ivec4|uvec4 a<i>;` (key->attr_kind); varyings: location i =
//    generic attribute i, `vec4 v<i>` (fragment side flat / noperspective as in MSL); `invariant gl_Position`;
//    gl_PointSize when writes_point_size, gl_Layer when writes_layer (GL_ARB_shader_viewport_layer_array:
//    shaderOutputLayer). Fragment outputs `layout(location=rt) out vec4|ivec4|uvec4 c<rt>;`,
//    gl_FragDepth when writes_depth.
//  - clip space exactly as the MSL output (key->flip_y / depth_minus_one epilogue unchanged): the renderer uses
//    a negative-height viewport so Vulkan matches Metal's y-up NDC, clip z in [0, 1].
//  - compute: `layout(local_size_x_id = 0, local_size_y_id = 1, local_size_z_id = 2) in;` (spec constants 0..2).
//  - extensions: GL_EXT_shader_explicit_arithmetic_types_int64 (64-bit carry / address math -> shaderInt64),
//    GL_KHR_shader_subgroup_basic/_shuffle/_shuffle_relative (SHFL, FSWZADD lane: fragment/compute subgroup
//    support), GL_EXT_texture_shadow_lod (explicit-LOD array / cube shadow lookups).
//  - not in GLSL: the maxwell_dbg_vs position dump (buffer 29) is MSL only.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { STAGE_VERTEX = 0, STAGE_FRAGMENT = 1, STAGE_GEOMETRY = 2, STAGE_TESS_CTRL = 3, STAGE_TESS_EVAL = 4,
       STAGE_COMPUTE = 5 };

enum { TEXTYPE_1D, TEXTYPE_2D, TEXTYPE_3D, TEXTYPE_CUBE, TEXTYPE_2D_ARRAY, TEXTYPE_CUBE_ARRAY, TEXTYPE_1D_ARRAY,
       TEXTYPE_BUFFER, TEXTYPE_2D_MS };

typedef struct {
    uint8_t attr_kind[32];  // vertex inputs: 0 float, 1 signed int, 2 unsigned int
    uint8_t rt_kind[8];     // fragment outputs: 0 float, 1 signed int, 2 unsigned int
    bool depth_minus_one;   // NVN depth mode [-1,1]: remap clip z
    bool flip_y;            // lower-left window origin
    bool flip_x;            // mirror the image left to right (mirror mode's scene composite). (In the padding
                            // after flip_y: keys without it hash as before - shader caches stay valid.)
    uint32_t vs_out_mask;   // fragment: varyings the vertex shader provides
    uint8_t glsl;           // emit Vulkan GLSL (see the contract above) instead of MSL
    uint32_t stencil_slots; // texture handle slots ((handle_offset - 0x20) / 8) bound in stencil mode
                            // (NVN depth/stencil mode STENCIL): a usampler, results read as uint bits
    // (GLSL vertex) transform feedback: buffer b takes xfb_count[b] 32-bit output components, xfb_stride[b] bytes per
    // vertex. The written varying components go to the buffers in order (location, then x..w). Where (and whether)
    // per draw: rscale[66 + b] = (word offset of buffer b in global memory, -, on, -) as uint bits (binding 18).
    uint8_t xfb_count[4];
    uint16_t xfb_stride[4];
    uint8_t xfb_void;       // (MSL vertex) rasterizer discard: Metal wants a void return then (outputs only go to the xfb buffers)
    uint32_t sint_slots, uint_slots; // sampled texture scalar kinds, indexed by the same handle slots
    uint8_t img_sint, img_uint;      // bound image scalar kinds, by image index ((handle offset - IMAGE_HANDLE_BASE) / 8)
} ShaderKey;

typedef struct {
    uint32_t handle_offset;  // byte offset of the texture handle in the bound texture cbuf
    uint8_t type;            // TEXTYPE_*
    bool shadow, is_array, is_image, bindless;
    bool stencil;            // a stencil view (ShaderKey.stencil_slots)
    bool atomic;             // image: reduced with SURED (needs a read_write atomic texture)
    uint8_t scalar_kind;      // 0 float, 1 signed int, 2 unsigned int (stencil is unsigned)
    uint32_t bindless_cbuf, bindless_offset;
} ShaderTexture;

typedef struct {
    int stage;
    char *msl;              // complete MSL or GLSL source (MSL entry "main0", GLSL "main"); NULL on failure
    uint32_t cbuf_mask;     // hardware constant buffers read
    uint32_t cbuf_size[18];
    uint32_t cbuf_dynamic;  // cbufs indexed with a register: bind the whole buffer
    int ntex;
    ShaderTexture tex[64];
    uint32_t attr_mask;     // vertex: input attributes; fragment: input varyings
    uint32_t out_mask;      // vertex: output varyings; fragment: render targets written
    bool writes_depth, uses_discard, writes_point_size;
    bool writes_layer;      // vertex: writes the render target layer (attribute 0x64)
    bool uses_gmem;         // global memory access: bind the guest heap at GMEM_BUFFER_INDEX
    bool uses_gmem_map;     // (GLSL compute only) gmem loads look their address up in GMap (uniform, binding
                            // GMAP_BUFFER_INDEX) and read GFast (storage, GFAST_BUFFER_INDEX) - a device-local copy of the
                            // dispatch's storage buffers - when found, stores too (copied back after the dispatch).
                            // runtime/nvn/vulkan/exec.c
    bool uses_gmem_store;   // writes global memory (STG)
    bool uses_tint;        // fragment: reads the per-draw tint (buffer 19, float4[2]) applied to color target 0
    bool uses_rscale;       // reads the resolution-scale table (fragment/compute buffer 18): float4 [0] = render
                            // target scale, [1 + i] = allocation scale of texture i
    bool uses_xfb;          // (MSL vertex) writes transform feedback: per-draw buffer table at XFB_BUFFER_INDEX
    uint32_t local_mem;     // bytes of local memory
    uint32_t num_insts;
    bool structured_flow;  // forward control flow, without the PC dispatcher (diagnostic)
    char error[256];        // set when translation fails
} ShaderInfo;

// Global memory (LDG/STG) is addressed through one buffer that wraps the guest heap.
#define GMEM_BUFFER_INDEX 17
// Vertex transform feedback: MSL binds a uint4 table {gmem word offset, size, on, -}; GLSL binds the output directly.
#define XFB_BUFFER_INDEX 22
#define IMAGE_HANDLE_BASE 0x120  // NVN: image handles follow the 32 texture handles (0x20 + 8 * slot) in the driver cbuf
// (MSL) Metal's sampler slots a stage. A shader with more textures takes its samplers as an array of all the slots
// and the slot of each texture from a table of uints at SMAP_BUFFER_INDEX (fragment, compute; [i] = texture i's slot).
#define MSL_MAX_SAMPLERS 16
#define SMAP_BUFFER_INDEX 22
// (GLSL compute, Vulkan) the fast copy of a dispatch's storage buffers: its address table and its data
#define GMAP_BUFFER_INDEX 20
#define GFAST_BUFFER_INDEX 21
#define GMAP_MAX 16  // ranges in the table (GMap { uvec4 gmap[GMAP_MAX + 1]; }: [i] = addr lo, addr hi, size, word offset;
                     // [GMAP_MAX].x = count)
extern uint64_t maxwell_gmem_base, maxwell_gmem_size;
// Debug: when translating the shader whose code starts at maxwell_dbg_code, output register
// maxwell_dbg_reg as captured after the instruction at maxwell_dbg_pc (greyscale, all targets).
extern const uint8_t *maxwell_dbg_code;
extern uint32_t maxwell_dbg_pc;
extern int maxwell_dbg_reg;
// Debug: the vertex shader at maxwell_dbg_vs writes each vertex's position to buffer 18 (slot iid*8+vid).
extern const uint8_t *maxwell_dbg_vs;
#define DBG_VS_BUFFER_INDEX 29

// code: shader binary (with the 0x50-byte SPH header for graphics stages)
ShaderInfo *maxwell_translate(const uint8_t *code, size_t max_size, int stage, const ShaderKey *key);
// Compiler-owned c1 data, stored with the program, permits bounded jump-table analysis.
ShaderInfo *maxwell_translate_with_constants(const uint8_t *code, size_t max_size, int stage, const ShaderKey *key,
                                           const uint8_t *constants, size_t constants_size);
// A fragment stage that writes nothing: programs with only a vertex shader (depth-only passes: shadow maps, prepass)
ShaderInfo *maxwell_empty_fragment(void);
void maxwell_free(ShaderInfo *s);
// Disassemble for debugging (writes text to f).
void maxwell_disassemble(const uint8_t *code, size_t max_size, int stage, void *file);
