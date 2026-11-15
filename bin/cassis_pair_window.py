#!/usr/bin/env python3
# cassis_pair_window.py - for two framelets mapprojected on the same grid and projection, print the
# bounding box of their valid-pixel overlap and the integer ground shift of B relative to A:
#   xmin ymin xmax ymax dx dy peak
# where B(col+dx, row+dy) best matches A(col, row) by masked normalized cross-correlation of high-passed
# images, searched up to +-maxShift px (coarse at half resolution, then refined). Prints nothing if the
# footprints do not overlap or the overlap is too small to measure.
# Usage: cassis_pair_window.py <mapA.tif> <mapB.tif> <maxShift>
import sys
import numpy as np
from osgeo import gdal

gdal.UseExceptions()

def read(path):
  ds = gdal.Open(path)
  band = ds.GetRasterBand(1)
  a = band.ReadAsArray().astype(float)
  nd = band.GetNoDataValue()
  m = np.isfinite(a) & (a > -1e30)
  if nd is not None:
    m &= (a != nd)
  return a, m, ds.GetGeoTransform()

def box_mean(a, k):
  # mean over a (2k+1) x (2k+1) box via a summed-area table, edges clamped
  p = np.pad(a, k + 1, mode="edge").cumsum(0).cumsum(1)
  n = 2 * k + 1
  s = p[n:, n:] - p[:-n, n:] - p[n:, :-n] + p[:-n, :-n]
  return s[:a.shape[0], :a.shape[1]] / float(n * n)

def high_pass(a, m, k):
  w = box_mean(m.astype(float), k) + 1e-9
  h = a - box_mean(np.where(m, a, 0.0), k) / w
  h[~m] = 0.0
  return h

def ncc(pa, ma, pb, mb, dx, dy):
  H, W = pa.shape
  ya0, ya1 = max(0, -dy), min(H, H - dy)
  xa0, xa1 = max(0, -dx), min(W, W - dx)
  if ya1 <= ya0 or xa1 <= xa0:
    return -2.0
  m = ma[ya0:ya1, xa0:xa1] & mb[ya0 + dy:ya1 + dy, xa0 + dx:xa1 + dx]
  if m.sum() < 500:
    return -2.0
  u = pa[ya0:ya1, xa0:xa1][m]
  v = pb[ya0 + dy:ya1 + dy, xa0 + dx:xa1 + dx][m]
  return float((u * v).sum() / np.sqrt((u * u).sum() * (v * v).sum() + 1e-12))

def search(pa, ma, pb, mb, xs, ys):
  best = (-2.0, 0, 0)
  for dy in ys:
    for dx in xs:
      c = ncc(pa, ma, pb, mb, dx, dy)
      if c > best[0]:
        best = (c, dx, dy)
  return best

A, mA, gA = read(sys.argv[1])
B, mB, gB = read(sys.argv[2])
S = int(sys.argv[3])
res = gA[1]

def bbox(m, g):
  r = np.where(m.any(1))[0]
  c = np.where(m.any(0))[0]
  return g[0] + c[0] * g[1], g[3] + (r[-1] + 1) * g[5], g[0] + (c[-1] + 1) * g[1], g[3] + r[0] * g[5]

if not mA.any() or not mB.any():
  sys.exit(0)
a0 = bbox(mA, gA)
b0 = bbox(mB, gB)
x0, y0 = max(a0[0], b0[0]), max(a0[1], b0[1])
x1, y1 = min(a0[2], b0[2]), min(a0[3], b0[3])
if x1 <= x0 or y1 <= y0:
  sys.exit(0)
# snap the window to the shared lattice, padded by the search range so shifted content stays inside
x0 = gA[0] + np.floor((x0 - gA[0]) / res) * res
y1 = gA[3] - np.floor((gA[3] - y1) / res) * res
x1 = gA[0] + np.ceil((x1 - gA[0]) / res) * res
y0 = gA[3] - np.ceil((gA[3] - y0) / res) * res

# resample both onto the padded common window (nearest, same lattice) for the shift search
def crop(a, m, g):
  W = int(round((x1 - x0) / res)) + 2 * S
  H = int(round((y1 - y0) / res)) + 2 * S
  c0 = int(round((x0 - g[0]) / res)) - S
  r0 = int(round((g[3] - y1) / res)) - S
  out = np.zeros((H, W)); om = np.zeros((H, W), bool)
  rs, cs = max(0, r0), max(0, c0)
  re, ce = min(a.shape[0], r0 + H), min(a.shape[1], c0 + W)
  if re > rs and ce > cs:
    out[rs - r0:re - r0, cs - c0:ce - c0] = a[rs:re, cs:ce]
    om[rs - r0:re - r0, cs - c0:ce - c0] = m[rs:re, cs:ce]
  return out, om

ca, cma = crop(A, mA, gA)
cb, cmb = crop(B, mB, gB)
pa, pb = high_pass(ca, cma, 7), high_pass(cb, cmb, 7)
# coarse: half resolution, then refine +-2 px at full resolution
h = 2
c1 = search(pa[::h, ::h], cma[::h, ::h], pb[::h, ::h], cmb[::h, ::h],
            range(-(S // h), S // h + 1), range(-(S // h), S // h + 1))
if c1[0] <= -1:
  sys.exit(0)
c2 = search(pa, cma, pb, cmb, range(c1[1] * h - 2, c1[1] * h + 3), range(c1[2] * h - 2, c1[2] * h + 3))
print("%.6f %.6f %.6f %.6f %d %d %.3f" % (x0, y0, x1, y1, c2[1], c2[2], c2[0]))
