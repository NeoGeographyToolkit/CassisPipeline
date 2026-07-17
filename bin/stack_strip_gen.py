#!/usr/bin/env python3
# Generalized CaSSIS strip stacker (any Jezero pair). For each look (strip id):
#   - measure the signed consecutive-framelet along-track advance (1D profile
#     xcorr, median over all pairs - robust; a per-pair subset is noisy),
#   - the look with NEGATIVE advance is ~180 deg telescope-rotated -> stack its
#     framelets in REVERSE order so the strip is continuous (the other look is
#     time-order),
#   - trim each framelet to its central KEEP rows (KEEP = even(|advance|)) so the
#     ~overlap is removed and the strip does not washboard.
# Writes <out_dir>/<sid>_strip.tif and prints, per sid, REVERSE/TIME + KEEP, which
# assemble_pushframe_gen.py consumes (framelet_order_reversed).
#
# Usage: stack_strip_gen.py <inputCassisDir> <sid1> <sid2> <out_dir>
#   inputCassisDir holds the looks' cubs (found by the sid in the filename, any subdir layout).
import sys, glob, re, numpy as np
from osgeo import gdal
gdal.UseExceptions()

data_dir, sid1, sid2, out_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
import os; os.makedirs(out_dir, exist_ok=True)

def framelets(sid):
    fs = glob.glob(f'{data_dir}/*/*-{sid}-*-0__4_0.cub') + glob.glob(f'{data_dir}/*-{sid}-*-0__4_0.cub')
    idx = lambda f: int(re.search(rf'-{sid}-(\d+)-0__4_0', f).group(1))
    return [f for f in sorted(fs, key=idx)]

def signed_advance(fs):
    # Per consecutive-framelet pair, find the along-track advance by 1D xcorr of
    # the central-column mean profile, SUB-PIXEL (parabolic peak interpolation).
    # The advance is ~223 rows here and is fractional; a coarse integer xcorr
    # under-measures it (it returned 220, off by ~3 rows -> a constant seam every
    # framelet). Sub-pixel + round-to-nearest fixes the stitch pitch.
    sh = []
    for k in range(len(fs)-1):
        a = gdal.Open(fs[k]).ReadAsArray().astype(float)
        b = gdal.Open(fs[k+1]).ReadAsArray().astype(float)
        w = a.shape[1]
        ca = a[:, w//2-300:w//2+300].mean(1); cb = b[:, w//2-300:w//2+300].mean(1)
        ca = (ca-ca.mean())/(ca.std()+1e-9); cb = (cb-cb.mean())/(cb.std()+1e-9)
        corr = {}
        for s in range(-279, 280):
            if s >= 0: x = ca[s:]; y = cb[:len(x)]
            else:      y = cb[-s:]; x = ca[:len(y)]
            if len(x) < 45: continue   # was 60, which CAPPED detectable advance at
                                       # 220 (280-row framelet); true advance ~223
            corr[s] = np.corrcoef(x, y)[0, 1]
        s0 = max(corr, key=corr.get)
        # parabolic sub-pixel refinement about the integer peak s0
        if (s0-1) in corr and (s0+1) in corr:
            cm, c0, cp = corr[s0-1], corr[s0], corr[s0+1]
            denom = (cm - 2*c0 + cp)
            d = 0.5*(cm - cp)/denom if abs(denom) > 1e-12 else 0.0
        else:
            d = 0.0
        sh.append(s0 + d)
    sh = np.array(sh)
    mag = float(np.median(np.abs(sh)))                    # sub-pixel advance
    sign = 1 if (sh > 0).sum() >= (sh < 0).sum() else -1   # majority sign
    return sign, mag

results = {}
for sid in (sid1, sid2):
    fs = framelets(sid)
    sign, mag = signed_advance(fs)
    results[sid] = (sign, mag, fs)

# PER-LOOK KEEP: each strip is trimmed to ITS OWN |advance| (the two looks of a
# pair can have different framelet rates -> different advance/width, e.g. 014234),
# so each strip is seamless. The pushframe JSON's framelet_height per look = its KEEP.
KEEP_OVERRIDE = int(sys.argv[5]) if len(sys.argv) > 5 else 0  # force KEEP (true advance)
for sid in (sid1, sid2):
    sign, mag, fs = results[sid]
    keep = KEEP_OVERRIDE if KEEP_OVERRIDE else int(round(mag))   # nearest int to sub-pixel |advance|
    reverse = (sign < 0)
    fs_ordered = list(reversed(fs)) if reverse else fs
    arrs = []
    for f in fs_ordered:
        a = gdal.Open(f).ReadAsArray()
        t = (a.shape[0] - keep) // 2
        arrs.append(a[t:t+keep, :])
    strip = np.vstack(arrs)
    out = f'{out_dir}/{sid}_strip.tif'
    drv = gdal.GetDriverByName('GTiff')
    ds = drv.Create(out, strip.shape[1], strip.shape[0], 1, gdal.GDT_Float32)
    ds.GetRasterBand(1).WriteArray(strip); ds = None
    print(f"{sid}: advance {sign*mag} -> {'REVERSE' if reverse else 'TIME'} order, "
          f"KEEP={keep}, {len(fs)} framelets -> {strip.shape[1]}x{strip.shape[0]}  {out}")
print(f"KEEP={keep}")
