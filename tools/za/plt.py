"""plt.py <tools> <nso> addr...: what a call target is (PLT stub -> imported symbol, or nearest export)"""
import bisect, re, subprocess, sys
sys.path.insert(0, sys.argv[1])
from nso import Nso
import capstone
n = Nso(sys.argv[2])
md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
slot = {r[0]: r[2] for r in n.relocs if r[1] in (1026, 1025, 257)}
exp = sorted((v, s) for s, info, shndx, v, size in n.syms if shndx and s)
dm = lambda s: subprocess.run(['c++filt', s], capture_output=True, text=True).stdout.strip()
for a in sys.argv[3:]:
    a = int(a, 16)
    ins = list(md.disasm(bytes(n.image[a:a + 12]), a))
    if len(ins) >= 2 and ins[0].mnemonic == 'adrp' and ins[1].mnemonic == 'ldr':
        page = int(re.findall(r'#(0x[0-9a-f]+)', ins[0].op_str)[0], 16)
        m = re.findall(r'#(0x[0-9a-f]+)\]', ins[1].op_str)
        g = page + (int(m[0], 16) if m else 0)
        if g in slot:
            print(f'{a:x} PLT -> {dm(n.syms[slot[g]][0])}'); continue
    i = bisect.bisect_right([x[0] for x in exp], a) - 1
    print(f'{a:x} {dm(exp[i][1])}+{a - exp[i][0]:x}' if i >= 0 else f'{a:x} ?')
