// Opt-in, bounded shader diagnostics. Metadata stays local; input dumps require a separate opt-in.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "../cpu.h"
struct NvnShaderStage;
#ifdef __cplusplus
extern "C" {
#endif
bool shader_trace_enabled(void);
void shader_trace_frame(uint64_t frame);
void shader_trace_read(const char *path, uint64_t offset, uint64_t destination, size_t size);
void shader_trace_stage(Cpu *cpu, const struct NvnShaderStage *stage, uint64_t program);
void shader_trace_compile(const char *kind, double ms, uint64_t vs, uint64_t fs,
                          uint64_t vertex_source_hash, uint64_t fragment_source_hash, int archivable);
void shader_trace_flush(void);
void shader_trace_reset(void);
#ifdef __cplusplus
}
#endif
