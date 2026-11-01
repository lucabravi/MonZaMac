"""Native decoder protocol checks; no game fixtures."""
from pathlib import Path
import struct, subprocess, sys, tempfile
exe=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as temp:
    root=Path(temp);source=root/'input';dest=root/'output'
    expected=b'Z'*0x40000
    source.write_bytes(struct.pack('<Q',len(expected))+b'\x4c\x06'+expected)
    subprocess.run([exe,source,dest],check=True)
    assert dest.read_bytes()==expected
    # The helper must not overwrite an existing output, even on valid input.
    assert subprocess.run([exe,source,dest],stderr=subprocess.DEVNULL).returncode!=0
    assert dest.read_bytes()==expected
    dest.unlink()
    for bad in (b'bad',struct.pack('<Q',1<<40)+b'x',struct.pack('<Q',16)+b'bad'):
        source.write_bytes(bad)
        assert subprocess.run([exe,source,dest],stderr=subprocess.DEVNULL).returncode!=0
        assert not dest.exists()
print('PASS: native decoder roundtrip, exclusive output, malformed/oversize inputs')
