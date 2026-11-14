#!/usr/bin/env python
# cassis_eval_continuity.py - continuity QC of a final CaSSIS DEM: coverage, gaps, seams,
# and wild fraction. Median dz/dd stats hide all of these, so this complements them.
#
# Usage: cassis_eval_continuity.py <finalDem> <linescanDem> <dzDiff> <outTsv> [tag]
#   finalDem    final framelet DEM (e.g. frame/pass1_stereo/cassis_dem.tif)
#   linescanDem aligned linescan DEM, the reference footprint (it is not mapproject-limited)
#   dzDiff      geodiff of the final DEM vs CTX (e.g. cassis_dem_ctxdiff-diff.tif)
#   outTsv      one header line + one row of metrics (appended if it exists)
# All rasters are resampled onto the linescan DEM grid. The footprint is the linescan valid
# area with holes filled, eroded a few pixels so the ragged edge does not count as a gap.
# Metrics:
#   coverage     final-valid fraction of the footprint
#   gap_frac     no-data fraction in the INTERIOR footprint (eroded more), i.e. holes
#   n_gaps       interior no-data components larger than 20 pixels; max_gap = largest (px)
#   wild_*       fraction of valid pixels with |dz| > 50 m, overall and per along-track third
#   step_p99, step_max  along-track seam steps: the median dz in 1-pixel along-track bins,
#                then the absolute bin-to-bin difference (m). A seam shows as a large step.
import sys
import os
import numpy as np
from osgeo import gdal
from scipy import ndimage

gdal.UseExceptions()

def read_on(path, ref):
  # Resample a raster onto the grid of the reference dataset, return float with NaN.
  gt = ref.GetGeoTransform()
  nx, ny = ref.RasterXSize, ref.RasterYSize
  b = (gt[0], gt[3] + gt[5] * ny, gt[0] + gt[1] * nx, gt[3])
  ds = gdal.Warp('', path, format='MEM', outputBounds=b, width=nx, height=ny,
                 dstSRS=ref.GetProjection(), resampleAlg='bilinear', dstNodata=-1e30)
  a = ds.GetRasterBand(1).ReadAsArray().astype(float)
  a[a < -1e20] = np.nan
  return a

def main():
  if len(sys.argv) < 5:
    print(__doc__ if __doc__ else 'see header')
    sys.exit(1)
  fin, ls, dz, out = sys.argv[1:5]
  tag = sys.argv[5] if len(sys.argv) > 5 else os.path.basename(os.path.dirname(fin))
  ref = gdal.Open(ls)
  L = ref.GetRasterBand(1).ReadAsArray().astype(float)
  nd = ref.GetRasterBand(1).GetNoDataValue()
  if nd is not None:
    L[L == nd] = np.nan
  L[L < -1e20] = np.nan
  F = read_on(fin, ref)
  D = read_on(dz, ref)

  foot = ndimage.binary_fill_holes(np.isfinite(L))
  foot = ndimage.binary_erosion(foot, iterations=3)
  inner = ndimage.binary_erosion(foot, iterations=6)
  fv = np.isfinite(F)
  nfoot = max(1, foot.sum())
  coverage = (fv & foot).sum() / nfoot
  holes = inner & ~fv
  gap_frac = holes.sum() / max(1, inner.sum())
  lab, n = ndimage.label(holes)
  sizes = ndimage.sum(holes, lab, range(1, n + 1)) if n > 0 else np.array([0])
  n_gaps = int((sizes > 20).sum())
  max_gap = int(sizes.max()) if n > 0 else 0

  # Along-track axis = principal axis of the footprint.
  yy, xx = np.nonzero(foot)
  c = np.vstack([xx - xx.mean(), yy - yy.mean()])
  w, v = np.linalg.eigh(np.cov(c))
  ax = v[:, np.argmax(w)]
  Y, X = np.mgrid[0:L.shape[0], 0:L.shape[1]]
  s = (X - xx.mean()) * ax[0] + (Y - yy.mean()) * ax[1]

  ok = foot & np.isfinite(D)
  wild = np.abs(D) > 50
  wild_all = (wild & ok).sum() / max(1, ok.sum())
  lo, hi = np.percentile(s[foot], [0, 100])
  edges = np.linspace(lo, hi, 4)
  wild_third = []
  for i in range(3):
    m = ok & (s >= edges[i]) & (s <= edges[i + 1])
    wild_third.append((wild & m).sum() / max(1, m.sum()))

  # Seam steps: median dz per 1-pixel along-track bin, inside the interior footprint.
  m = inner & np.isfinite(D)
  si = np.round(s[m]).astype(int)
  dv = D[m]
  order = np.argsort(si)
  si, dv = si[order], dv[order]
  ub, idx = np.unique(si, return_index=True)
  meds = np.array([np.median(g) for g in np.split(dv, idx[1:])])
  cnt = np.diff(np.append(idx, len(si)))
  good = cnt >= 10
  ub, meds = ub[good], meds[good]
  adj = np.diff(ub) == 1
  steps = np.abs(np.diff(meds))[adj] if len(meds) > 1 else np.array([0.0])
  step_p99 = float(np.percentile(steps, 99)) if len(steps) else 0.0
  step_max = float(steps.max()) if len(steps) else 0.0

  dzv = D[ok]
  med = float(np.median(dzv)) if dzv.size else np.nan
  nmad = float(1.4826 * np.median(np.abs(dzv - med))) if dzv.size else np.nan

  hdr = ('tag\tcoverage\tgap_frac\tn_gaps\tmax_gap_px\twild_all\twild_t1\twild_t2\twild_t3'
         '\tstep_p99\tstep_max\tdz_med\tdz_nmad')
  row = '%s\t%.4f\t%.4f\t%d\t%d\t%.4f\t%.4f\t%.4f\t%.4f\t%.2f\t%.2f\t%.2f\t%.2f' % (
    tag, coverage, gap_frac, n_gaps, max_gap, wild_all, wild_third[0], wild_third[1],
    wild_third[2], step_p99, step_max, med, nmad)
  new = not os.path.exists(out)
  with open(out, 'a') as f:
    if new:
      f.write(hdr + '\n')
    f.write(row + '\n')
  print(hdr)
  print(row)

if __name__ == '__main__':
  main()
