#!/usr/bin/env python3
"""Exercise SDL quit using a copy of local game saves/settings; needs the user's game files.

Usage: python3 tools/test_game_quit.py <monzamac binary> <data root containing extracted/ and save/>
The visible test run and its log/screenshot are kept under build/quit-test-*.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("data_root", type=Path)
    parser.add_argument("--interrupt", action="store_true", help="send a second Ctrl+C after guest threads stop")
    args = parser.parse_args()
    binary, source = args.binary.resolve(), args.data_root.resolve()
    Path("build").mkdir(exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="quit-test-", dir="build")).resolve()
    for name in ("save", "cache/shaders"):
        if (source / name).is_dir():
            shutil.copytree(source / name, scratch / name)
    if (source / "larecomp.ini").is_file():
        shutil.copy2(source / "larecomp.ini", scratch / "larecomp.ini")
    env = dict(os.environ)
    for name in ("LARECOMP_HIDDEN", "LARECOMP_EXIT_AFTER_SHOT", "LARECOMP_INPUT_REPLAY", "LARECOMP_INPUT_REC",
                 "LARECOMP_NO_PIPELINE_ARCHIVE"):
        env.pop(name, None)
    env.update(LARECOMP_DATA_ROOT=str(scratch), LARECOMP_SETTINGS=str(scratch / "larecomp.ini"),
               LARECOMP_SAVE_DIR=str(scratch / "save"),
               LARECOMP_WINDOW="1280x720", LARECOMP_INPUT="180:A:1,240:A:1,300:A:1",
               LARECOMP_WINDOW_SHOT="600", LARECOMP_SHOT_PATH=str(scratch / "frame.png"))
    log_path = scratch / "play.log"
    print(f"Evidence: {scratch}", flush=True)
    with log_path.open("w") as log:
        child = subprocess.Popen([str(binary), str(source / "extracted"), "--play"], cwd=scratch, env=env,
                                 stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                text = log_path.read_text(errors="replace")
                frames = re.findall(r"\[metal\] t=[\d.]+ frame (\d+)", text)
                if frames and int(frames[-1]) >= 600:
                    break
                if child.poll() is not None:
                    raise AssertionError("game exited before the quit check")
                time.sleep(0.1)
            else:
                raise AssertionError("game did not reach frame 600 in 90 seconds")
            started = time.monotonic()
            child.send_signal(signal.SIGINT)  # SDL turns this into the same event as closing the window.
            if args.interrupt:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if re.search(r"\[reboot\] \d+ guest threads stopped", log_path.read_text(errors="replace")):
                        child.send_signal(signal.SIGINT)
                        break
                    if child.poll() is not None:
                        break
                    time.sleep(0.01)
                else:
                    raise AssertionError("guest threads did not stop before the interrupt check")
            result = child.wait(timeout=30)
            print(f"Exit: {result}; quit took {time.monotonic() - started:.2f}s", flush=True)
            assert result in ((0, -signal.SIGINT) if args.interrupt else (0,)), "unexpected process exit status"
            if args.interrupt and result == 0:
                print("SKIP second-signal check: normal shutdown finished before SIGINT took effect")
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
    text = log_path.read_text(errors="replace")
    after_close = text.split("window closed\n", 1)[1]
    stopped = re.search(r"\[reboot\] \d+ guest threads stopped in \d+ms", after_close)
    assert stopped, "guest threads must stop before exit handlers save the cache"
    assert not re.search(r"\[metal\] t=", after_close[stopped.end():]), "rendering continued after guest threads stopped"
    saving = after_close.find("[shader] pipeline archive sav")
    assert saving < 0 or stopped.end() <= saving, "cache saving started before guest threads stopped"
    print("PASS: guest work stopped before the pipeline archive exit handler")


if __name__ == "__main__":
    main()
