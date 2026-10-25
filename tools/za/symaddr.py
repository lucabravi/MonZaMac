"""symaddr.py <tools dir> <exefs> addr...: nearest exported symbol per address (main @0x7000000000, sdk @0x7008000000)"""
import bisect, subprocess, sys
sys.path.insert(0, sys.argv[1])
from nso import Nso
mods = [('main', 0x7000000000), ('sdk', 0x7008000000)]
tabs = {}
for name, base in mods:
    n = Nso(f'{sys.argv[2]}/{name}')
    syms = sorted((base + v, s) for s, info, shndx, v, size in n.syms if shndx and s)
    tabs[name] = (base, base + n.size, syms)
for a in sys.argv[3:]:
    a = int(a, 16)
    for name, (lo, hi, syms) in tabs.items():
        if lo <= a < hi:
            i = bisect.bisect_right([x[0] for x in syms], a) - 1
            s = syms[i][1] if i >= 0 else '?'
            try: s = subprocess.run(['c++filt', s], capture_output=True, text=True).stdout.strip()
            except Exception: pass
            print(f'{a:x} {name}+{a - lo:x}  {s}+{a - syms[i][0]:x}')
