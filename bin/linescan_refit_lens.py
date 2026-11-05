#!/usr/bin/env python3
# linescan_refit_lens.py - build a "refit-lens" linescan CSM state from a native (CaSSIS,
# type-9) one by (a) replacing the optical distortion with the refit transverse lens and
# (b) overwriting each trajectory node's pose with the matching refit per-framelet FRAME
# camera's pose. This is the core of the refitBeforeLinescan reorder: it moves the
# optimized transverse lens + its compensating pose refit UP FRONT, so the linescan (and
# every product built from it: the CTX registration, the stage-7 GCP) uses the refit
# cameras instead of the vendor lens.
#
# WHY this is a direct, conversion-free copy: a usgscsm linescan state stores the
# trajectory as m_positions (3 per node) and m_quaternions (4 per node) in the SAME ECEF
# frame that a frame camera stores in m_currentParameterValue ([x,y,z, q0,q1,q2,q3]).
# linescan2framelets.sh copies linescan node -> frame m_currentParameterValue with no
# transform; this does the inverse copy. The transverse lens is read straight from a refit
# frame cam (all refit framelets share one lens, since it is one physical instrument), so
# the linescan gets exactly the distortion cam_gen produced. Node j (time-sorted) <->
# the j-th present framelet, matching how the pushframe trajectory was assembled
# (assemble_pushframe_gen.py merges present framelets in time order).
#
# Proven on pfe 2026-11-04: distortion-only swap is 111 px off; distortion + refit poses
# is 1.78 px median vs the original linescan (self-consistent). cam_gen refit is
# frame-only, which is why this injection is needed at all.
#
# Usage: linescan_refit_lens.py <in_linescan_state.json> <refit_frame_cam_dir> <sid> <out_state.json>
import json, glob, re, sys

def load(f):
    t = open(f).read()
    try:
        return json.loads(t), False
    except Exception:
        return json.loads(t.split("\n", 1)[1]), True   # strip the 1-line model-name header

def main():
    if len(sys.argv) != 5:
        sys.exit("usage: linescan_refit_lens.py <in_linescan_state> <refit_frame_cam_dir> <sid> <out_state>")
    in_state, cam_dir, sid, out_state = sys.argv[1:5]
    d, hashdr = load(in_state)
    nnodes = len(d["m_positions"]) // 3
    if len(d["m_quaternions"]) // 4 != nnodes:
        sys.exit(f"ERROR positions/quaternions node count mismatch in {in_state}")

    # refit frame cams for this look, in along-track (framelet-index = time) order
    cams = glob.glob(f"{cam_dir}/*-{sid}-*-0__4_0.json")
    if not cams:
        sys.exit(f"ERROR no refit frame cams for sid {sid} under {cam_dir}")
    idxof = lambda f: int(re.search(rf"-{sid}-(\d+)-0__4_0", f).group(1))
    cams = sorted(cams, key=idxof)

    # the transverse lens, read from the first refit frame cam (one lens for all framelets)
    fr0, _ = load(cams[0])
    dist_type = fr0["m_distortionType"]
    dist_coef = fr0["m_opticalDistCoeffs"]
    d["m_distortionType"] = dist_type
    d["m_opticalDistCoeffs"] = list(dist_coef)

    pos = list(d["m_positions"]); quat = list(d["m_quaternions"])
    nwrote = 0
    # time-ordered node j <- j-th present framelet (robust to archive index gaps)
    for j, cf in enumerate(cams):
        if j >= nnodes:
            print(f"  WARN more refit cams ({len(cams)}) than nodes ({nnodes}); extra cams ignored")
            break
        st, _ = load(cf)
        cv = st["m_currentParameterValue"]   # [x,y,z, q0,q1,q2,q3], ECEF, same frame as the node
        pos[3 * j:3 * j + 3] = cv[0:3]
        quat[4 * j:4 * j + 4] = cv[3:7]
        nwrote += 1
    d["m_positions"] = pos; d["m_quaternions"] = quat

    with open(out_state, "w") as f:
        if hashdr:
            f.write(d.get("m_modelName", "USGS_ASTRO_LINE_SCANNER_SENSOR_MODEL") + "\n")
        json.dump(d, f)
    note = "" if len(cams) == nnodes else f"  (NOTE {len(cams)} cams vs {nnodes} nodes - archive gaps?)"
    print(f"linescan_refit_lens {sid}: distortionType {dist_type} ({len(dist_coef)} coeffs), "
          f"overwrote {nwrote}/{nnodes} node poses{note} -> {out_state}")

if __name__ == "__main__":
    main()
