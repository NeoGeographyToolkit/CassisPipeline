#!/usr/bin/env python3
# cassis_check_lens.py - verify that CSM camera states carry the optimized transverse lens: the
# state's m_opticalDistCoeffs must equal the optimized_distortion coefficients of the recipe. Exit 0
# if all states match, 1 otherwise, printing which state differs.
# Usage: cassis_check_lens.py "<optimized_distortion coefficients>" <state.json> [<state.json> ...]
import json
import sys

def load(path):
  t = open(path).read()
  try:
    return json.loads(t)
  except json.JSONDecodeError:
    # an ASP state may start with a one-line model-name header
    return json.loads(t.split("\n", 1)[1])

want = [float(x) for x in sys.argv[1].split()]
bad = 0
for p in sys.argv[2:]:
  have = [float(x) for x in load(p).get("m_opticalDistCoeffs", [])]
  ok = len(have) == len(want) and all(abs(a - b) <= 1e-9 + 1e-6 * abs(b) for a, b in zip(have, want))
  if not ok:
    bad += 1
    print("LENS MISMATCH %s: has %d coefficients (first %s), want the optimized lens (first %s)"
          % (p, len(have), have[:2], want[:2]))
sys.exit(1 if bad else 0)
