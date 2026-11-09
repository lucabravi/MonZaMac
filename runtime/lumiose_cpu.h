// Force-included (-include) when a mod's translated code is compiled: cpu.h, then stores that go through
// lumiose_test_store, so the writes the mod makes to its private copy of game code reach the real image (lumiose_module.c).
// cpu.h itself stays as it is: every game object depends on it.
#pragma once
#include "cpu.h"
#include "lumiose_rtld.h"
void lumiose_test_store(uint64_t addr, uint64_t value, unsigned size);
#undef ST8
#undef ST16
#undef ST32
#undef ST64
#define ST8(a, v)  lumiose_test_store((a), (uint8_t)(v), 1)
#define ST16(a, v) lumiose_test_store((a), (uint16_t)(v), 2)
#define ST32(a, v) lumiose_test_store((a), (uint32_t)(v), 4)
#define ST64(a, v) lumiose_test_store((a), (uint64_t)(v), 8)
// Loads of the module's code: the address range where it sees rtld is shifted to where rtld is
#undef LD8
#undef LD16
#undef LD32
#undef LD64
#define LD8(a)  (*(const u8a *)(uintptr_t)LUMIOSE_SHIFT((uint64_t)(a)))
#define LD16(a) (*(const u16u *)(uintptr_t)LUMIOSE_SHIFT((uint64_t)(a)))
#define LD32(a) (*(const u32u *)(uintptr_t)LUMIOSE_SHIFT((uint64_t)(a)))
#define LD64(a) (*(const u64u *)(uintptr_t)LUMIOSE_SHIFT((uint64_t)(a)))
