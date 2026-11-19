# PyInstaller spec: the button icon maker (tools/za/prompt_textures.py) as a standalone onedir helper, so the start
# screen can redraw Pokémon Legends Z-A's button icons for the keyboard, Xbox and PlayStation from the player's own game
# files (runtime/ui/launcher.mm make_prompts) without Python. -> build/helper/zaprompts/ (zaprompts + _internal/), with
# the Oodle decoder library (tools/shader_decode, MIT) in it. Same command line as prompt_textures.py.
import os
import sys

from PyInstaller.utils.hooks import collect_data_files

TOOLS = os.path.normpath(SPECPATH)
ROOT = os.path.dirname(TOOLS)
DECODER = os.path.join(ROOT, 'build', 'shader-decode', 'release', 'libmonzamac_ooz.dylib')

a = Analysis(
    [os.path.join(TOOLS, 'za', 'prompt_textures.py')],
    pathex=[os.path.join(TOOLS, 'za')],
    binaries=[(DECODER, '.')],  # (_internal/: prompt_textures.py looks there, sys._MEIPASS)
    datas=collect_data_files('cffsubr', include_py_files=False),  # (its tx program, which subroutinizes the fonts)
    excludes=['tkinter', 'pydoc', 'doctest', 'unittest', 'pdb', 'IPython', 'setuptools', '_distutils_hack',
              'pkg_resources', 'ssl', '_ssl', '_hashlib'],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, exclude_binaries=True, name='zaprompts', console=True, strip=sys.platform == 'darwin', upx=False)
coll = COLLECT(exe, a.binaries, a.datas, strip=sys.platform == 'darwin', upx=False, name='zaprompts')
