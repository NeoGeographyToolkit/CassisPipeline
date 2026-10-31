#!/usr/bin/env python3
# cassis_eval_plots.py - per-site evaluation figures for a CaSSIS DEM registered to a CTX reference.
#
# Produces the six panels of the standard CaSSIS evaluation (see the CaSSIS documentation), as SINGLE
# images so a gallery can lay them 3-per-row:
#   row 1 (grayscale hillshade, the COVERAGE check): <tag>_1ctx.png  <tag>_2linescan.png  <tag>_3final.png
#          = CTX reference | aligned linescan DEM (the ~complete baseline) | final framelet/pass1 DEM.
#          The final DEM must cover the same ground as the linescan - the dz/dd stats below hide missing
#          coverage, so this row is how you catch it.
#   row 2 (diverging + colorbar): <tag>_4dz.png (m)  <tag>_5ddh.png (px)  <tag>_6ddv.png (px)
#          = elevation difference, and the across/along-track hillshade-correlation disparity.
# All six share ONE window = the aligned-linescan footprint + 20% margin, on the 18 m CTX grid.
# Also writes <outdir>/<tag>_stats.tsv : tag  dz_med dz_nmad  ddh_med ddh_nmad  ddv_med ddv_nmad
# (consumed by cassis_gallery.py). Run with the plotting conda env (matplotlib + osgeo).
#
# Usage: cassis_eval_plots.py <tag> <ctx_18m> <aligned_linescan> <final_on_ctx> <dz-diff> <ddH> <ddV> <outdir>
#   ctx_18m          ref/<site>_ctx/<tag>_ctx_18m.tif
#   aligned_linescan <site>_out/linescan/linescan_dem/align/aligned_oncoarse.tif
#   final_on_ctx     <site>_out/frame/pass1_stereo/cassis_dem_on_ctx.tif
#   dz-diff / ddH / ddV   <site>_out/frame/pass1_stereo/eval18/{dz-diff,run-F-H,run-F-V}.tif
import sys, numpy as np
from osgeo import gdal; gdal.UseExceptions()
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.colors import LightSource

if len(sys.argv) != 9:
    sys.exit("usage: cassis_eval_plots.py <tag> <ctx_18m> <aligned_linescan> <final_on_ctx> "
             "<dz-diff> <ddH> <ddV> <outdir>")
tag, ctx, lsn, fin, dzf, ddh, ddv, outdir = sys.argv[1:9]

d = gdal.Open(lsn); gt = d.GetGeoTransform(); nx, ny = d.RasterXSize, d.RasterYSize
b = d.GetRasterBand(1); a = b.ReadAsArray().astype('float64'); nd = b.GetNoDataValue()
m = (a == nd) if nd is not None else ~np.isfinite(a); m |= ~np.isfinite(a)
ys, xs = np.where(~m)
r0, r1 = ys.min(), ys.max()+1; c0, c1 = xs.min(), xs.max()+1
mh = int(0.2*(r1-r0)); mw = int(0.2*(c1-c0))
r0 = max(0, r0-mh); r1 = min(ny, r1+mh); c0 = max(0, c0-mw); c1 = min(nx, c1+mw)
pw = [gt[0]+c0*gt[1], gt[3]+r0*gt[5], gt[0]+c1*gt[1], gt[3]+r1*gt[5]]
res = abs(gt[1]); LS = LightSource(azdeg=315, altdeg=40)

def win(path, name):
    ds = gdal.Open(path)
    if ds is None: return None, None
    t = gdal.Translate('/vsimem/w_'+tag+name, ds, projWin=pw)
    bb = t.GetRasterBand(1); arr = bb.ReadAsArray().astype('float64'); ndd = bb.GetNoDataValue()
    mm = (arr == ndd) if ndd is not None else ~np.isfinite(arr); mm |= ~np.isfinite(arr); mm |= (np.abs(arr) > 1e5)
    return arr, mm

def nmad(arr, mm):
    x = arr[~mm]
    if x.size == 0: return 0.0, 0.0
    md = float(np.median(x)); return md, float(1.4826*np.median(np.abs(x-md)))

def save_hs(path, out):
    arr, mm = win(path, 'h')
    if arr is None: open(out, 'w').close(); return
    zf = np.where(mm, np.nan, arr); h = LS.hillshade(zf, dx=res, dy=res, vert_exag=2.0)
    h = np.clip(np.nan_to_num(h, nan=1.0), 0, 1); rgb = plt.cm.gray(h); rgb[mm] = [1, 1, 1, 1]
    fig, ax = plt.subplots(figsize=(4, 6.2)); ax.imshow(rgb); ax.set_xticks([]); ax.set_yticks([])
    fig.savefig(out, dpi=110, bbox_inches='tight', pad_inches=0.02); plt.close(fig)

def save_div(path, out, unit, name):
    arr, mm = win(path, name)
    if arr is None: return 0.0, 0.0
    md, nm = nmad(arr, mm); lim = max(1.0 if unit == 'meters' else 0.5, 3*nm)
    fig, ax = plt.subplots(figsize=(4.5, 6.2))
    im = ax.imshow(np.where(mm, np.nan, arr), cmap='RdBu_r', vmin=-lim, vmax=lim)
    ax.set_xticks([]); ax.set_yticks([]); cb = fig.colorbar(im, ax=ax, fraction=0.046, pad=0.04); cb.set_label(unit)
    fig.savefig(out, dpi=110, bbox_inches='tight', pad_inches=0.02); plt.close(fig)
    return md, nm

save_hs(ctx, outdir+'/'+tag+'_1ctx.png')
save_hs(lsn, outdir+'/'+tag+'_2linescan.png')
save_hs(fin, outdir+'/'+tag+'_3final.png')
dzm, dzn = save_div(dzf, outdir+'/'+tag+'_4dz.png', 'meters', 'z')
hm, hn = save_div(ddh, outdir+'/'+tag+'_5ddh.png', 'pixels', 'h')
vm, vn = save_div(ddv, outdir+'/'+tag+'_6ddv.png', 'pixels', 'v')
with open(outdir+'/'+tag+'_stats.tsv', 'w') as f:
    f.write(f"{tag}\t{dzm:.2f}\t{dzn:.2f}\t{hm:.2f}\t{hn:.2f}\t{vm:.2f}\t{vn:.2f}\n")
print(f"{tag} dz {dzm:+.2f}/{dzn:.2f} m  ddh {hm:+.2f}/{hn:.2f} px  ddv {vm:+.2f}/{vn:.2f} px  -> {outdir}/{tag}_stats.tsv")
