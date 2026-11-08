"""How the Lumiose tools start each other: as scripts of a source checkout, or as commands of the bundled lasgen helper
(PyInstaller, sys.frozen), where `lasgen online <tool>` runs tools/lumiose/<tool>.py and plain `lasgen` is tools/gen.py."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FROZEN = bool(getattr(sys, 'frozen', False))


def tool(name):
    """argv prefix that runs tools/lumiose/<name>.py ('prepare', 'prepare_game', 'activate', ...)."""
    return [sys.executable, 'online', name] if FROZEN else [sys.executable, str(HERE / (name + '.py'))]


def generator():
    """argv prefix of the game code generator (tools/gen.py's command line)."""
    return [sys.executable] if FROZEN else [sys.executable, str(HERE.parent / 'gen.py')]
