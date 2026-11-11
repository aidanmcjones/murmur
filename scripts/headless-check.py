#!/usr/bin/env python3
"""Every headless flag must exit (30 s timeout) and never reach the GUI / event tap (MURMUR_ASSERT_NO_TAP exits 3).

usage: scripts/headless-check.py [path/to/Murmur]   (default build/Murmur.app/Contents/MacOS/Murmur)
"""
import os, subprocess, sys, tempfile

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
exe = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "build/Murmur.app/Contents/MacOS/Murmur")
vec = os.path.join(root, "shared/test-vectors")
tmp = tempfile.mkdtemp()
env = dict(os.environ, MURMUR_ASSERT_NO_TAP="1")
# (args, allowed exit codes)
cases = [
    (["--learn-selftest"], {0}),
    (["--learn-wfparity"], {0}),
    (["--check-test-vectors", vec], {0}),
    (["--dump-test-vectors", tmp], {0}),
    (["--clean-text", "um so I I think so"], {0}),
    (["--clean-text", "hi", "--bundle-id", "com.apple.TextEdit"], {0}),
    (["--learn-test", "my collab tree", "my Kolabtree"], {0}),
    # Missing values and unknown options: usage error, never the GUI.
    (["--check-test-vectors"], {2}),
    (["--dump-test-vectors"], {2}),
    (["--clean-text"], {2}),
    (["--learn-test", "only-one"], {2}),
    (["--transcribe"], {2}),
    (["--asr-boost-eval"], {2}),
    (["--bundle-id", "x"], {2}),
    (["--no-such-flag"], {2}),
    (["--help"], {2}),
]
bad = 0
# Instance guard (flock): two simultaneous guarded processes -> exactly one wins; after it exits a new one wins.
genv = dict(env, MURMUR_SUPPORT_DIR=tmp)
procs = [subprocess.Popen([exe, "--instance-guard-test", "3"], env=genv, stdout=subprocess.PIPE, text=True) for _ in range(2)]
outs = []
for p in procs:
    try: outs.append((p.communicate(timeout=30)[0].strip(), p.returncode))
    except subprocess.TimeoutExpired: p.kill(); outs.append(("timeout", None))
won = sorted(o for o, _ in outs)
good = won == ["lost", "won"] and sorted(c for _, c in outs) == [0, 10]
bad += not good
print(f"{'PASS' if good else 'FAIL'} instance guard: two launches -> {won}")
try:
    r = subprocess.run([exe, "--instance-guard-test", "0"], env=genv, capture_output=True, text=True, timeout=30)
    good = r.stdout.strip() == "won" and r.returncode == 0
except subprocess.TimeoutExpired:
    good = False
bad += not good
print(f"{'PASS' if good else 'FAIL'} instance guard: relaunch after exit wins")
for args, ok in cases:
    try:
        p = subprocess.run([exe] + args, env=env, capture_output=True, text=True, timeout=30)
        code, note = p.returncode, (p.stderr.strip().splitlines() or [""])[-1]
    except subprocess.TimeoutExpired:
        code, note = "timeout", "did not exit within 30 s (killed)"
    good = code in ok
    bad += not good
    print(f"{'PASS' if good else 'FAIL'} {' '.join(args)[:60]!r} exit={code}" + ("" if good else f" ({note})"))
print(f"{len(cases) + 2 - bad}/{len(cases) + 2} headless checks pass (flags exit, no event tap, single instance)")
sys.exit(1 if bad else 0)
