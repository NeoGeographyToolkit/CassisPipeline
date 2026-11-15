# cassis_match_check.py - summarize per-pair triangulations from cassis_match_check.sh: median height
# minus refDem for each L-R match file, and list the files departing from the median over all files by
# more than maxDz m.
# Usage: cassis_match_check.py <pairsDir> <refDem> <maxDz> <dropList>
import sys, os, glob, numpy as np
from osgeo import gdal, osr
gdal.UseExceptions()
pairs, ref, maxDz, dropf = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
d = gdal.Open(ref); z = d.GetRasterBand(1).ReadAsArray().astype(float)
nd = d.GetRasterBand(1).GetNoDataValue()
if nd is not None: z[z == nd] = np.nan
gt = d.GetGeoTransform()
src = osr.SpatialReference(); src.SetFromUserInput('+proj=longlat +R=3396190 +no_defs')
src.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
dst = osr.SpatialReference(wkt=d.GetProjection()); dst.SetAxisMappingStrategy(osr.OAMS_TRADITIONAL_GIS_ORDER)
ct = osr.CoordinateTransformation(src, dst)
med = {}
for p in sorted(os.listdir(pairs)):
    f = os.path.join(pairs, p, 'run-final_residuals_pointmap.csv')
    if not os.path.exists(f): continue
    T = np.loadtxt(f, delimiter=',', comments='#', usecols=(0, 1, 2), ndmin=2)
    if len(T) < 20: continue
    xy = np.array(ct.TransformPoints(T[:, :2]))[:, :2]
    c = ((xy[:, 0] - gt[0]) / gt[1]).astype(int); r = ((xy[:, 1] - gt[3]) / gt[5]).astype(int)
    k = (c >= 0) & (r >= 0) & (c < z.shape[1]) & (r < z.shape[0])
    dz = T[k, 2] - z[r[k], c[k]]; dz = dz[np.isfinite(dz)]
    if len(dz) >= 20: med[p] = (float(np.median(dz)), len(dz))
if not med:
    open(dropf, 'w').close(); print('  no pairs triangulated'); sys.exit(0)
g = float(np.median([m for m, _ in med.values()]))
drop = [p for p, (m, _) in med.items() if abs(m - g) > maxDz]
print(f'  pairs {len(med)}, median of pair medians {g:+.1f} m, maxDz {maxDz:g} m, dropped {len(drop)}')
for p, (m, n) in sorted(med.items(), key=lambda x: -abs(x[1][0] - g)):
    print(f'  {"DROP" if p in drop else "keep"} {m - g:+8.1f} m  n {n:6d}  {p}')
open(dropf, 'w').write(''.join(p + '\n' for p in drop))
