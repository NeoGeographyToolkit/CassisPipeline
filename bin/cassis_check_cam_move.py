#!/usr/bin/env python3
# cassis_check_cam_move.py - sanity check of an alignment applied to linescan camera states: compare the
# camera positions (m_positions) before and after, and fail if the median displacement exceeds maxMove meters
# or the median distance from the planet center changes by more than maxRadial meters. A wrong-lock alignment
# with a large rotation moves cameras at orbit distance by hundreds of km and must not reach later stages.
# Usage: cassis_check_cam_move.py <maxMove> <maxRadial> <before.json> <after.json> [<before.json> <after.json> ...]
import json
import sys
import numpy as np

def load(p):
  t = open(p).read()
  try:
    return json.loads(t)
  except json.JSONDecodeError:
    return json.loads(t.split("\n", 1)[1])

def positions(p):
  return np.array(load(p)["m_positions"], float).reshape(-1, 3)

maxMove, maxRadial = float(sys.argv[1]), float(sys.argv[2])
bad = 0
args = sys.argv[3:]
for b, a in zip(args[0::2], args[1::2]):
  pb, pa = positions(b), positions(a)
  n = min(len(pb), len(pa))
  move = float(np.median(np.linalg.norm(pa[:n] - pb[:n], axis=1)))
  radial = float(np.median(np.linalg.norm(pa[:n], axis=1) - np.linalg.norm(pb[:n], axis=1)))
  ok = move <= maxMove and abs(radial) <= maxRadial
  bad += not ok
  print("%s camera move: median %.0f m, radial change %+.0f m%s" % (a.split("/")[-1], move, radial,
        "" if ok else "  EXCEEDS %.0f / %.0f m" % (maxMove, maxRadial)))
sys.exit(1 if bad else 0)
