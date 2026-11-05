#!/usr/bin/env python3
# gcp_texture_mask.py - invalidate boot-disparity pixels over featureless (low-texture) terrain
# before dem2gcp builds GCPs. On flat, featureless terrain the hillshade correlation that feeds
# the GCP is unreliable (a small but WRONG disparity, not a large outlier - so a max-disp magnitude
# filter cannot catch it), and the hard fixed-GCP then drags those framelets. This masks the
# disparity where the local hillshade standard deviation (a texture proxy) is below a threshold, so
# dem2gcp simply does not place control there and the dense same-look ties keep continuity instead.
#
# Operates on an ASP 3-band disparity (run-F.tif): band1=dh, band2=dv, band3=good-pixel mask (0/1).
# It only turns band3 from 1 to 0 where texture is low; bands 1-2 are copied unchanged.
#
# Dual mode:
#   diagnostic:  gcp_texture_mask.py <run-F.tif> <hillshade.tif> <win> --         (prints std stats, no write)
#   apply:       gcp_texture_mask.py <run-F.tif> <hillshade.tif> <win> <min_std> <out_run-F.tif>
import sys, numpy as np
from osgeo import gdal
gdal.DontUseExceptions()
from scipy.ndimage import uniform_filter

def local_std(a, valid, win):
    # std over a win x win window, computed only from valid pixels (hillshade 0 = nodata)
    af = np.where(valid, a, 0.0).astype('float64')
    v = valid.astype('float64')
    cnt = uniform_filter(v, win, mode='nearest')
    mean = uniform_filter(af, win, mode='nearest') / np.maximum(cnt, 1e-6)
    meansq = uniform_filter(af * af, win, mode='nearest') / np.maximum(cnt, 1e-6)
    var = np.maximum(meansq - mean * mean, 0.0)
    std = np.sqrt(var)
    std[cnt < 0.2] = np.nan   # too few valid neighbors to judge
    return std

def main():
    disp, hs, win = sys.argv[1], sys.argv[2], int(sys.argv[3])
    out = sys.argv[5] if len(sys.argv) > 5 else None
    min_std = float(sys.argv[4]) if (len(sys.argv) > 4 and sys.argv[4] != '--') else None

    dh = gdal.Open(hs); ha = dh.GetRasterBand(1).ReadAsArray().astype('float64')
    hnd = dh.GetRasterBand(1).GetNoDataValue()
    hvalid = np.isfinite(ha) & (ha != (0 if hnd is None else hnd))
    dd = gdal.Open(disp); nb = dd.RasterCount
    b3 = dd.GetRasterBand(3).ReadAsArray().astype('float64')
    gp = b3 > 0.5

    # align the hillshade grid to the disparity grid if sizes differ (nearest crop/pad)
    H = min(ha.shape[0], gp.shape[0]); W = min(ha.shape[1], gp.shape[1])
    ha = ha[:H, :W]; hvalid = hvalid[:H, :W]; gpc = gp[:H, :W]
    std = local_std(ha, hvalid, win)

    rows = np.where(gpc.any(axis=1))[0]
    if rows.size:
        mid = (rows.min() + rows.max()) // 2
        for name, sl in (("TOP", slice(rows.min(), mid + 1)), ("BOT", slice(mid + 1, rows.max() + 1))):
            s = std[sl][gpc[sl] & np.isfinite(std[sl])]
            if s.size:
                print(f"  {name} local-std over GCP pixels: p5={np.percentile(s,5):.2f} p25={np.percentile(s,25):.2f} "
                      f"p50={np.percentile(s,50):.2f} p75={np.percentile(s,75):.2f}")
    for t in (2, 3, 4, 5, 6, 8):
        frac = 100 * np.mean((std < t)[gpc & np.isfinite(std)]) if gpc.any() else 0
        print(f"  threshold std<{t}: would mask {frac:.0f}% of GCP-candidate pixels")

    if out is None or min_std is None:
        print("diagnostic only (no output written)")
        return
    # apply: band3 -> 0 where local std < min_std (and where std is NaN = too few neighbors)
    lowtex = (~np.isfinite(std)) | (std < min_std)
    newb3 = gpc.astype('float32'); newb3[lowtex] = 0.0
    drv = gdal.GetDriverByName('GTiff')
    o = drv.Create(out, dd.RasterXSize, dd.RasterYSize, nb, gdal.GDT_Float32)
    o.SetGeoTransform(dd.GetGeoTransform()); o.SetProjection(dd.GetProjection())
    for i in (1, 2):
        o.GetRasterBand(i).WriteArray(dd.GetRasterBand(i).ReadAsArray())
    full = dd.GetRasterBand(3).ReadAsArray().astype('float32')
    full[:H, :W] = newb3
    o.GetRasterBand(3).WriteArray(full); o.FlushCache()
    kept = int((full > 0.5).sum()); was = int(gp.sum())
    print(f"wrote {out}: band3 kept {kept}/{was} good pixels ({100*kept/max(was,1):.0f}%), masked low-texture (std<{min_std}, win {win})")

if __name__ == "__main__":
    main()
