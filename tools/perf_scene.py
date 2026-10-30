#!/usr/bin/env python3
"""CPU and GPU time per frame in a scripted scene: the frame times of a window of a run, as a mean.

  tools/perf_scene.py --save <folder holding save_0> [--binary build/za202/monzamac] [--runs 2] [--from 3600] [--frames 1800]

Starts the game from a copy of the save (LARECOMP_SAVE_DIR: the save is never touched), presses through the title with
the scripted input of tools/perf_sweep.py, lets it settle until frame --from and averages the "[perf]" lines
(LARECOMP_PERF_LOG: the F3 overlay's smoothed submit CPU time and GPU busy time, in ms) of the next --frames frames
(1800 = 30 s at 60 fps), and the frame rate of the "[metal]" lines in the same window. For the unlocked frame rate
set dev_uncapped_fps = 1 in larecomp.ini (Developer tab). The scene is wherever the save is, left standing. Settings come from larecomp.ini: set the
internal resolution or any option there first. The window is 1280x720 so runs compare; keep the Mac otherwise idle and
the window in front.
"""
import argparse, os, re, shutil, subprocess, sys, tempfile, time

TITLE_INPUT = '400:A:6,520:A:6,900:ZL:8,900:ZR:8,1300:A:6,1600:A:6,1900:A:6,2200:A:6'
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
LINE = re.compile(r'\[perf\] frame (\d+) cpu ([\d.]+) gpu ([\d.]+)')
FPS = re.compile(r'\[metal\] t=[\d.]+ frame (\d+) ([\d.]+) fps')

ap = argparse.ArgumentParser()
ap.add_argument('--save', required=True, help='folder holding save_0 (copied for each run)')
ap.add_argument('--binary', default=os.path.join(ROOT, 'build', 'za202', 'monzamac'))
ap.add_argument('--runs', type=int, default=1)
ap.add_argument('--from', dest='start', type=int, default=3600, help='first frame of the window (after the title input and the load)')
ap.add_argument('--frames', type=int, default=1800, help='length of the window in frames')
args = ap.parse_args()

for run in range(1, args.runs + 1):
    tmp = tempfile.mkdtemp(prefix='perf_scene_')
    shutil.copytree(os.path.join(args.save, 'save_0'), os.path.join(tmp, 'save_0'))
    env = dict(os.environ, LARECOMP_SAVE_DIR=tmp, LARECOMP_INPUT=TITLE_INPUT, LARECOMP_WINDOW='1280x720', LARECOMP_PERF_LOG='60', LARECOMP_FPS_INTERVAL='1')
    end = args.start + args.frames
    log = os.path.join(tmp, 'run.log')
    with open(log, 'w') as f:
        p = subprocess.Popen([args.binary, 'extracted'], cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT)
        t0 = time.time()
        while p.poll() is None and time.time() - t0 < end / 60 * 1.5 + 90:
            time.sleep(2)
            fr = [int(m) for m in re.findall(r'\[perf\] frame (\d+)', open(log, errors='replace').read()[-3000:])]
            if fr and fr[-1] >= end: break
        p.terminate()
        try: p.wait(10)
        except subprocess.TimeoutExpired: p.kill()
    rows = [(int(a), float(b), float(c)) for a, b, c in LINE.findall(open(log, errors='replace').read()) if args.start <= int(a) <= end]
    if not rows:
        print(f'run {run}: no [perf] lines in frames {args.start}-{end} (log: {log})')
        continue
    cpu, gpu = [r[1] for r in rows], [r[2] for r in rows]
    fps = [float(b) for a, b in FPS.findall(open(log, errors='replace').read()) if args.start <= int(a) <= end]
    fps_text = f'  fps {sum(fps) / len(fps):.1f} (min {min(fps):.1f})' if fps else ''
    print(f'run {run}: {len(rows)} samples  cpu {sum(cpu) / len(cpu):.2f} ms (max {max(cpu):.2f})  gpu {sum(gpu) / len(gpu):.2f} ms (max {max(gpu):.2f}){fps_text}')
    shutil.rmtree(tmp, ignore_errors=True)
