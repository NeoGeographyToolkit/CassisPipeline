#!/usr/bin/env python3
# pushframe2linescan.py - convert a CaSSIS push-frame ISD (USGS_ASTRO_PUSH_FRAME
# SENSOR_MODEL) over an already-assembled strip into a LINESCAN ISD
# (USGS_ASTRO_LINE_SCANNER_SENSOR_MODEL) over the SAME strip.
#
# WHY (Oleg's theory, see cassis_pushframe_notes.sh entry 12): the push-frame
# image->ground quantizes line -> integer framelet -> ONE time per framelet, so
# pose (position AND orientation) is FROZEN within a framelet and STEPS at every
# boundary -> framelet-period seams in the DEM. A linescan over the same strip
# gives each line a CONTINUOUS Lagrange-interpolated pose -> the "glorified
# linescan". This script does that with NO C++ change, to test the hypothesis.
#
# THE MAPPING (derived in the notes):
#  - Pose tables (instrument_pointing / instrument_position) are copied verbatim;
#    the linescan Lagrange-interps them continuously instead of on a staircase.
#  - line->time is continuous: time(line) = startTime + dt*line (single
#    line_scan_rate segment, startLine=0.5). Anchored so the linescan time at
#    each framelet-block CENTER (strip line j*H + H/2) equals the push-frame time
#    for that framelet -> the two models agree exactly at framelet centers and
#    differ only (smoothly) toward the edges.
#      dt = (-1 if reversed else +1) * interframe_delay / H
#      not reversed: startTime = A - interframe/2
#      reversed:     startTime = A + (nF-1)*interframe + interframe/2
#    where A = starting_eph + 0.5*exposure - center_eph (center-relative time of
#    framelet 0), nF = image_lines / H, H = framelet_height.
#  - The linescan losToEcf HARDCODES detector line 0.0, so the fixed look uses
#    detLine = starting_detector_line. The CaSSIS framelet images its CENTRAL row
#    ~884 detector rows off the optical center (that off-axis row IS the fore/aft
#    look tilt). So set the linescan starting_detector_line = push-frame
#    starting_detector_line + H/2 (the framelet-band center). detector_center
#    (optical center, line 1024) and iTransL are kept, so the fixed look + the
#    CASSIS distortion are evaluated at the framelet center, matching push-frame.
#
# Usage: pushframe2linescan.py <in_pushframe.json> <out_linescan.json>
import json, sys

def convert(d):
    H   = float(d["framelet_height"])
    nF  = round(d["image_lines"] / H)
    ifd = d["interframe_delay"]
    exp = d["exposure_duration"]
    sE  = d["starting_ephemeris_time"]
    cE  = d["center_ephemeris_time"]
    rev = bool(d.get("framelet_order_reversed", False))
    sdl = d["starting_detector_line"]

    A = sE + 0.5 * exp - cE                      # center-relative time of framelet 0
    if rev:
        dt = -ifd / H
        startTime = A + (nF - 1) * ifd + ifd / 2.0
    else:
        dt = ifd / H
        startTime = A - ifd / 2.0

    ls = dict(d)                                 # shallow copy, then fix up
    ls["name_model"] = "USGS_ASTRO_LINE_SCANNER_SENSOR_MODEL"
    ls["line_scan_rate"] = [[0.5, startTime, dt]]
    ls["starting_detector_line"] = sdl + H / 2.0  # framelet-band center row
    ls.setdefault("interpolation_method", "lagrange")
    # Drop push-frame-only keys (harmless if left, but keep the ISD clean).
    for k in ("framelet_height", "interframe_delay", "num_lines_overlap",
              "framelet_order_reversed", "framelets_flipped", "exposure_duration"):
        ls.pop(k, None)

    info = dict(H=H, nF=nF, reversed=rev, dt=dt, startTime=startTime,
                ls_starting_detector_line=ls["starting_detector_line"],
                node_min_rel=d["instrument_pointing"]["ck_table_start_time"] - cE,
                node_max_rel=d["instrument_pointing"]["ck_table_end_time"] - cE,
                line0_time=startTime + dt * 0.0,
                lineN_time=startTime + dt * (d["image_lines"] - 1))
    return ls, info

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: pushframe2linescan.py <in_pushframe.json> <out_linescan.json>")
    d = json.load(open(sys.argv[1]))
    if d.get("name_model") != "USGS_ASTRO_PUSH_FRAME_SENSOR_MODEL":
        sys.exit("input is not a push-frame ISD: %s" % d.get("name_model"))
    ls, info = convert(d)
    json.dump(ls, open(sys.argv[2], "w"), indent=2)
    for k, v in info.items():
        print("  %-26s %s" % (k, v))
    print("wrote", sys.argv[2])
