#!/usr/bin/env python3
# cassis_ctx_ncc_align.py <ctx_dem> <cassis_dem> <res_m> <outdir> - find the rigid horizontal shift of a
# CaSSIS DEM onto a CTX reference by sliding-window normalized cross-correlation (NCC) of their hillshades,
# plus the vertical offset. A GLOBAL exhaustive template match, so (unlike ICP from scratch) it cannot
# settle into a wrong local minimum - the CaSSIS-to-CTX registration is a known rigid shift and the raw
# strip already sits inside the (3x) CTX box, so this is the ideal tool for it.
#
# Prints:
#   NED_TRANSLATION <North> <East> <Down>   (meters) - the shift to apply to the CaSSIS (source) DEM/cameras,
#       in the local North-East-Down frame at the site. Feed it to
#       `pc_align --num-iterations 0 --initial-ned-translation "<N> <E> <D>"` to get the honest ECEF
#       cassis->ctx transform (the same final-transform step cassis_linescan_dem.sh method 2 uses).
#   plus a human-readable line with the NCC peak and the shift magnitude.
# Writes <outdir>/ncc_aligned.tif (the shifted CaSSIS DEM on the CTX grid) and <outdir>/ncc_match.png.
#
# Near the projection center, proj +x is East and +y is North, so dx_m -> East, dy_m -> North, and the
# elevation offset dz (CTX - CaSSIS) -> Down = -dz. The shift is tiny (~km) so the local-frame NED is an
# excellent model; pc_align then produces the exact ECEF transform including curvature.
#
# scipy, numpy, matplotlib, and the GDAL python bindings must be importable (the 'geo' conda env).
# Depends only on numpy, scipy, and the GDAL python bindings (all in the pipeline's conda env) - no
# matplotlib, so the hillshade is computed in numpy and the optional debug PNG degrades gracefully.
import sys, numpy as np
from osgeo import gdal; gdal.UseExceptions()
from scipy.signal import fftconvolve

ctxp, casp, res, outdir = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]

def nphillshade(z, azdeg=315.0, altdeg=45.0, ve=2.0):
    gy, gx = np.gradient(z * ve)
    slope = np.pi/2.0 - np.arctan(np.hypot(gx, gy))
    aspect = np.arctan2(-gx, gy)
    az = np.radians(azdeg); alt = np.radians(altdeg)
    sh = np.sin(alt)*np.sin(slope) + np.cos(alt)*np.cos(slope)*np.cos((az - np.pi/2.0) - aspect)
    return np.clip(sh, 0.0, 1.0)

ctxds = gdal.Warp("/vsimem/ncc_ctx.tif", ctxp, xRes=res, yRes=res, resampleAlg="cubicspline")
gt = ctxds.GetGeoTransform(); CNX, CNY = ctxds.RasterXSize, ctxds.RasterYSize
casds = gdal.Warp("/vsimem/ncc_cas.tif", casp, xRes=res, yRes=res, resampleAlg="cubicspline",
                  outputBounds=[gt[0], gt[3]+CNY*gt[5], gt[0]+CNX*gt[1], gt[3]], dstSRS=ctxds.GetProjection())

def arr(ds):
    b=ds.GetRasterBand(1); a=b.ReadAsArray().astype('float64'); nd=b.GetNoDataValue()
    m=(a==nd)|~np.isfinite(a)|(a<-1e5); return a, m
C, Cm = arr(ctxds); S, Sm = arr(casds)
def hshade(a, m):
    z=np.where(m, np.nan, a); return np.nan_to_num(nphillshade(z), nan=0.0)
Ch, Sh = hshade(C, Cm), hshade(S, Sm)

ys, xs = np.where(~Sm)
if ys.size == 0:
    print("NED_TRANSLATION 0 0 0"); print("NCC: empty CaSSIS DEM"); sys.exit(0)
r0, r1, c0, c1 = ys.min(), ys.max()+1, xs.min(), xs.max()+1
T = Sh[r0:r1, c0:c1].copy(); M = (~Sm[r0:r1, c0:c1]).astype('float64')
n = M.sum(); Tc = (T - (T*M).sum()/n)*M; Tc2 = float((Tc*Tc).sum())

# Lewis-1995 masked normalized cross-correlation of the template over the search image, via FFT.
num  = fftconvolve(Ch, Tc[::-1, ::-1], mode="valid")
sumI = fftconvolve(Ch, M[::-1, ::-1], mode="valid")
sumI2= fftconvolve(Ch*Ch, M[::-1, ::-1], mode="valid")
denom = np.sqrt(np.clip(sumI2 - sumI*sumI/n, 1e-9, None) * Tc2)
ncc = num/denom
pr, pc = np.unravel_index(np.argmax(ncc), ncc.shape); peak = float(ncc[pr, pc])

dR, dC = pr - r0, pc - c0
dx_m, dy_m = dC*gt[1], dR*gt[5]        # East, North (gt[5] < 0)
mag = (dx_m**2 + dy_m**2)**0.5
# Vertical offset at the matched location (CTX - CaSSIS).
Cwin = C[pr:pr+(r1-r0), pc:pc+(c1-c0)]; Cwm = Cm[pr:pr+(r1-r0), pc:pc+(c1-c0)]
both = (M > 0) & (~Cwm)
dz = float(np.median(Cwin[both] - S[r0:r1, c0:c1][both])) if both.sum() else 0.0

print("NED_TRANSLATION %.3f %.3f %.3f" % (dy_m, dx_m, -dz))
print("NCC peak %.3f  horizontal shift %.0f m (%.2f km)  vertical %.0f m  overlap px %d"
      % (peak, mag, mag/1000.0, dz, int(both.sum())))

# Shifted CaSSIS DEM on the CTX grid, for inspection / a quick dd check.
Sv = np.where(Sm, np.nan, S)
al = np.roll(np.roll(Sv, dR, axis=0), dC, axis=1) + dz
al = np.where(np.isfinite(al), al, -32768.0)
od = gdal.GetDriverByName("GTiff").Create(outdir+"/ncc_aligned.tif", CNX, CNY, 1, gdal.GDT_Float32)
od.SetGeoTransform(gt); od.SetProjection(ctxds.GetProjection())
ob = od.GetRasterBand(1); ob.SetNoDataValue(-32768.0); ob.WriteArray(al.astype('float32')); od.FlushCache()
try:   # optional debug render; matplotlib is not required
    import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle
    fig, ax = plt.subplots(figsize=(CNX/90.0, CNY/90.0)); ax.imshow(Ch, cmap='gray'); ax.set_xticks([]); ax.set_yticks([])
    ax.add_patch(Rectangle((pc, pr), c1-c0, r1-r0, fill=False, edgecolor='red', lw=1.5))
    fig.savefig(outdir+"/ncc_match.png", dpi=90, bbox_inches='tight', pad_inches=0.02); plt.close()
except Exception:
    pass
