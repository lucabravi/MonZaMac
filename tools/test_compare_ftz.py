#!/usr/bin/env python3
"""Hand-written Maxwell comparison encodings; no game bytes or GPU required."""
from pathlib import Path
import subprocess
import tempfile
import shlex
import sys

ROOT = Path(__file__).resolve().parents[1]
# Develop before this fix; do not use HEAD, which would compare the fix to itself after committing.
BASELINE = "b5f317a"
HARNESS = r'''
#include "runtime/nvn/maxwell/shader.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#ifdef TEST_GLSL
#include <shaderc/shaderc.h>
#endif
int main(int argc, char **argv) {
    unsigned count = 0;
#ifdef TEST_GLSL
    shaderc_compiler_t compiler=shaderc_compiler_initialize();
#endif
    // Register, cbuf and immediate forms. FTZ is bit 47 for FSETP/FCMP, bit 55 for FSET.
    const uint64_t tops[][4] = {{0x5bb0, 0x4bb0, 0x36b0, 0}, {0x5800, 0x4800, 0x3000, 0}, {0x5ba0, 0x4ba0, 0x36a0, 0x53a0}};
    for (unsigned kind=0;kind<3;kind++) for(unsigned form=0;form<4 && tops[kind][form];form++)
    for (unsigned glsl=0;glsl<2;glsl++) for(unsigned ftz=0;ftz<2;ftz++) {
        if(argc>1 && ftz)continue;
        uint8_t bytes[160] = {0};
        uint64_t op = (tops[kind][form]<<48) | (7ull<<16) | (1ull<<8) | (2ull<<20) | (2ull<<48);
        if(kind==0)op |= 7ull | (7ull<<39); // EQ.AND P0, PT, R1, operand, PT
        else if(kind==1)op |= 4ull | (7ull<<39); // EQ.AND R4, R1, operand, PT
        else op |= 4ull | (3ull<<39); // EQ R4, R1, operand, R3
        op |= (uint64_t)ftz << (kind==1 ? 55 : 47);
        uint64_t code[] = {0x001f8000fc0007e0ull, op, 0xe30000000007000full, 0xe2400fffff87000full};
        memcpy(bytes,code,sizeof code);
        ShaderKey key={0};key.glsl=glsl;
        ShaderInfo *s=maxwell_translate(bytes,sizeof bytes,STAGE_COMPUTE,&key);
        assert(s && s->msl);
        // Count call sites separately from the helper declaration. FCMP must only flush its condition, never its selected data.
        const char *start=strstr(s->msl,"main");assert(start);
        unsigned calls=0;
        for(const char *p=start;(p=strstr(p,"ftz("));p+=4)calls++;
        unsigned want=ftz ? (kind==2 ? 1 : 2) : 0;
        if(calls!=want){fprintf(stderr,"kind %u form %u glsl %u ftz %u: calls %u, expected %u\n",kind,form,glsl,ftz,calls,want);return 1;}
#ifdef TEST_GLSL
        if(glsl) {
            shaderc_compilation_result_t result=shaderc_compile_into_spv(compiler,s->msl,strlen(s->msl),shaderc_compute_shader,"compare-ftz","main",NULL);
            if(shaderc_result_get_compilation_status(result)!=shaderc_compilation_status_success) {
                fprintf(stderr,"%s\n",shaderc_result_get_error_message(result));return 1;
            }
            shaderc_result_release(result);
        }
#endif
        if(argc>1)fputs(s->msl,stdout);
        maxwell_free(s);count++;
    }
#ifdef TEST_GLSL
    shaderc_compiler_release(compiler);
#endif
    printf("PASS: %u comparison encodings (MSL/GLSL, FTZ on/off, all source forms)\n",count);
}
'''
with tempfile.TemporaryDirectory(prefix="compare-ftz-") as tmp:
    tmp = Path(tmp)
    (tmp / "test.c").write_text(HARNESS)
    flags = (["-DTEST_GLSL"] + shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "shaderc"], text=True))) if "--glsl" in sys.argv else []
    subprocess.run(["clang", "-O1", "-I", str(ROOT), str(tmp / "test.c"),
                    str(ROOT / "runtime/nvn/maxwell/translate.c"), *flags, "-o", str(tmp / "test")], check=True)
    subprocess.run([str(tmp / "test")], check=True)
    # Non-FTZ shaders must remain byte-identical to the branch's develop baseline.
    baseline = subprocess.check_output(["git", "show", f"{BASELINE}:runtime/nvn/maxwell/translate.c"], cwd=ROOT)
    (tmp / "translate.c").write_bytes(baseline)
    (tmp / "shader.h").write_bytes((ROOT / "runtime/nvn/maxwell/shader.h").read_bytes())
    subprocess.run(["clang", "-O1", "-I", str(ROOT), str(tmp / "test.c"), str(tmp / "translate.c"),
                    *flags, "-o", str(tmp / "baseline")], check=True)
    assert subprocess.check_output([str(tmp / "test"), "no-ftz"]) == subprocess.check_output([str(tmp / "baseline"), "no-ftz"])
    print("PASS: non-FTZ output remains identical to develop")
