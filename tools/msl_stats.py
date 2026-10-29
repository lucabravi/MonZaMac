#!/usr/bin/env python3
"""Shape of a translated shader, without its code: build/msl/<addr>_fs.metal (LARECOMP_SAVE_MSL=1) -> line count, texture
reads, loops, branches, discards, constant-buffer reads, registers used. Prints numbers only, so it can be shared.

usage: tools/msl_stats.py build/msl/<addr>_fs.metal [...]
"""
import re
import sys

for path in sys.argv[1:]:
    s = open(path, errors="replace").read()
    body = s[s.find("main0("):] if "main0(" in s else s
    n = lambda pat: len(re.findall(pat, body))
    regs = {int(m) for m in re.findall(r"\br(\d+)\b", body)}
    print("%s: %d lines | texture reads %d (sample %d, read %d, gather %d) | loops %d | ifs %d | discards %d | cbuf reads %d | "
          "gmem %d | registers %d | fma/mul %d | rsqrt/sqrt/exp/log/pow/sin/cos %d" % (
              path.rsplit("/", 1)[-1], body.count("\n"), n(r"\.(sample|read|gather)\w*\("), n(r"\.sample\w*\("), n(r"\.read\("),
              n(r"\.gather\w*\("), n(r"\b(for|while)\s*\("), n(r"\bif\s*\("), n(r"discard_fragment"), n(r"\bcb\d+\["),
              n(r"\bgmem"), len(regs), n(r"\bfma\("), n(r"\b(rsqrt|sqrt|exp2?|log2?|pow|sin|cos)\(")))
