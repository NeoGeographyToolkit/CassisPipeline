#!/usr/bin/env python
# ms_cassis.py - run stereo on MANY image pairs from an OVERLAP LIST and produce either a DEM MOSAIC
# (+ a max tri-error mosaic) [mode dem_mosaic] or a fused MESH [mode mesh]. GNU parallel does the
# per-pair fan-out. Built for CaSSIS mapprojected images + CSM (json) cameras + a seed DEM, but generic.
# This is the pipeline's frame stereo engine (called by cassis_stereo.sh); it is intended to become a
# general ASP multi_stereo tool.
#
# Stages (entry/stop point, like stereo_dist):
#   0 stereo   : per pair, parallel_stereo (mapproj mode with the seed DEM) -> run-PC.tif
#   1 dem      : per pair, point2dem (--errorimage) -> per-pair DEM + IntersectionErr   [mode dem_mosaic]
#                OR per pair, pc_filter -> filtered PC                                    [mode mesh]
#   2 fuse     : dem_mosaic over the per-pair DEMs + dem_mosaic --max over the tri-err    [mode dem_mosaic]
#                OR voxblox mesh over the filtered PCs                                    [mode mesh]
import argparse, os, sys, glob, shlex, subprocess, tempfile

def msg(s): print("ms_cassis: " + s, flush=True)

def parse_args():
    p = argparse.ArgumentParser(description="multi_stereo over an overlap list -> DEM mosaic or mesh.")
    p.add_argument('--overlap-list', required=True,
                   help="Text file; each line is one stereo pair: left_image right_image left_cam right_cam. "
                        "'#' comments and blank lines are skipped.")
    p.add_argument('--dem', dest='seed_dem', default='',
                   help="Seed / mapproject DEM. Passed to parallel_stereo as --mapproj-dem when the images "
                        "are mapprojected (recommended for CaSSIS).")
    p.add_argument('--out-dir', dest='out_dir', required=True, help="Output directory.")
    p.add_argument('--mode', choices=['dem_mosaic', 'mesh'], default='dem_mosaic',
                   help="dem_mosaic: per-pair point2dem then dem_mosaic (+ max tri-err). mesh: pc_filter then "
                        "voxblox fused mesh (adapted from multi_stereo).")
    # Defaults are the pipeline's CaSSIS frame DEM-mode recipe (cassis_stereo_pair.sh). --ip-match-radius 20
    # and --mapproj-geolocation-uncertainty 0 assume well-registered (frame-BA'd) cameras; loosen them
    # (bigger radius / a geolocation-uncertainty collar) for rougher cameras.
    p.add_argument('--stereo-options', dest='stereo_options',
                   default="--alignment-method none --stereo-algorithm asp_mgm --subpixel-mode 9 "
                           "--corr-seed-mode 1 --min-matches 5 --ip-per-tile 2000 "
                           "--mapproj-geolocation-uncertainty 0 --ip-match-radius 20",
                   help="Options passed verbatim to parallel_stereo (default = the CaSSIS frame DEM-mode recipe).")
    p.add_argument('--point2dem-options', dest='point2dem_options',
                   default="--tr 18 --max-valid-triangulation-error 8",
                   help="Options for point2dem (mode dem_mosaic). MUST include --tr. --errorimage is added "
                        "automatically (needed for the max tri-error mosaic); --t_srs is auto-filled from --dem.")
    p.add_argument('--dem-mosaic-options', dest='dem_mosaic_options', default='',
                   help="Extra options for the dem_mosaic of the per-pair DEMs.")
    p.add_argument('--ref-dem', dest='ref_dem', default='',
                   help="Reference DEM (e.g. a sharp CTX) for the blunder filter and output grid. If set, "
                        "a per-pair DEM is dropped from the mosaic when its mean elevation departs from the "
                        "reference over the SAME footprint by more than --blunder-tol. Preferred over --dem "
                        "for --t_srs. A real stereo blunder triangulates far off the reference; a good "
                        "sliver matches it to tens of m at any elevation, so this keeps all real terrain.")
    p.add_argument('--blunder-tol', dest='blunder_tol', default=500.0, type=float,
                   help="Blunder-filter tolerance in meters (needs --ref-dem). Default 500.")
    p.add_argument('--pc-filter-options', dest='pc_filter_options', default='',
                   help="Options for pc_filter (mode mesh).")
    p.add_argument('--mesh-gen-options', dest='mesh_gen_options', default='',
                   help="Options for voxblox_mesh (mode mesh).")
    p.add_argument('--parallel-options', dest='parallel_options', default='--sshdelay 0.2',
                   help="Options passed to GNU parallel.")
    p.add_argument('--num-parallel', dest='num_parallel', default=1, type=int,
                   help="How many pairs to run concurrently under GNU parallel (each parallel_stereo also "
                        "uses its own processes/threads - keep the product within the machine).")
    p.add_argument('--entry-point', dest='entry', default=0, type=int, help="Start stage (0 stereo,1 dem,2 fuse).")
    p.add_argument('--stop-point', dest='stop', default=3, type=int, help="Stop before this stage.")
    p.add_argument('--dry-run', dest='dryrun', default=False, action='store_true', help="Print commands only.")
    return p.parse_args()

def read_pairs(path):
    pairs = []
    with open(path) as f:
        for ln in f:
            ln = ln.split('#', 1)[0].strip()
            if not ln: continue
            t = ln.split()
            if len(t) < 4:
                sys.exit(f"ms_cassis: overlap-list line needs 4 tokens "
                         f"(left_image right_image left_cam right_cam): {ln}")
            pairs.append(tuple(t[:4]))
    if not pairs: sys.exit("ms_cassis: no pairs read from " + path)
    return pairs

def find_tool(name):
    # prefer the dev install / PATH; ASP tools resolve from PATH in the run env
    from shutil import which
    t = which(name)
    if t is None: sys.exit(f"ms_cassis: cannot find tool '{name}' on PATH. Activate the ASP env.")
    return t

def run_parallel(cmds, num_parallel, parallel_options, dryrun):
    """Run a list of shell-command strings concurrently with GNU parallel (fan-out over pairs)."""
    if not cmds: return
    if dryrun:
        for c in cmds: print("  DRY: " + c)
        return
    par = find_tool('parallel')
    with tempfile.NamedTemporaryFile('w', suffix='.jobs', delete=False) as jf:
        jf.write("\n".join(cmds) + "\n"); jobs = jf.name
    cmd = [par] + shlex.split(parallel_options) + ['-j', str(num_parallel), '--halt', 'never', '-a', jobs]
    msg(f"GNU parallel: {len(cmds)} jobs, -j {num_parallel}")
    r = subprocess.run(cmd)
    os.unlink(jobs)
    if r.returncode != 0: msg(f"WARNING: GNU parallel returned {r.returncode} (some pairs may have failed)")

def pair_dir(out_dir, li, ri):
    lp = os.path.splitext(os.path.basename(li))[0]; rp = os.path.splitext(os.path.basename(ri))[0]
    return os.path.join(out_dir, "stereo", f"{lp}__{rp}")

def stage_stereo(args, pairs):
    msg("STAGE 0: per-pair parallel_stereo")
    ps = find_tool('parallel_stereo')
    # For mapprojected input images the seed DEM is a TRAILING positional arg (parallel_stereo
    # ... L R Lcam Rcam out_prefix input-DEM), not an option. It tells stereo which DEM the images
    # were mapprojected onto.
    seed = [args.seed_dem] if args.seed_dem else []
    cmds = []
    for (li, ri, lc, rc) in pairs:
        sd = pair_dir(args.out_dir, li, ri); os.makedirs(sd, exist_ok=True)
        pre = os.path.join(sd, 'run')
        cmd = [ps] + shlex.split(args.stereo_options) + [li, ri, lc, rc, pre] + seed
        cmds.append(shlex.join(cmd))
    run_parallel(cmds, args.num_parallel, args.parallel_options, args.dryrun)

def stage_dem(args, pairs):
    msg("STAGE 1: per-pair point2dem (--errorimage)")
    p2d = find_tool('point2dem')
    opts = shlex.split(args.point2dem_options)
    if '--tr' not in args.point2dem_options:
        sys.exit("ms_cassis: --point2dem-options must include --tr")
    if '--errorimage' not in args.point2dem_options: opts = opts + ['--errorimage']
    # auto-fill --t_srs so every per-pair DEM shares one projection (needed for dem_mosaic); prefer the
    # sharp --ref-dem (it sets the output grid, like the pipeline's refDem), else the seed --dem.
    srs_src = args.ref_dem or args.seed_dem
    if '--t_srs' not in args.point2dem_options and srs_src:
        try:
            srs = subprocess.run([find_tool('gdalsrsinfo'), '-o', 'proj4', srs_src],
                                 capture_output=True, text=True).stdout.strip()
            if srs: opts = opts + ['--t_srs', srs]
        except Exception as e: msg(f"WARNING: could not read --t_srs from {srs_src}: {e}")
    cmds = []
    for (li, ri, lc, rc) in pairs:
        pre = os.path.join(pair_dir(args.out_dir, li, ri), 'run')
        cmd = [p2d] + opts + ['-o', pre, pre + '-PC.tif']
        cmds.append(shlex.join(cmd))
    run_parallel(cmds, args.num_parallel, args.parallel_options, args.dryrun)

def gdal_mean(path):
    """STATISTICS_MEAN of a raster, or None."""
    import re
    t = subprocess.run([find_tool('gdalinfo'), '-stats', path], capture_output=True, text=True).stdout
    m = re.search(r'STATISTICS_MEAN=(-?[0-9.]+)', t)
    return float(m.group(1)) if m else None

def gdal_bbox(path):
    """(ulx uly lrx lry) map-coordinate bounding box, or None."""
    import re
    t = subprocess.run([find_tool('gdalinfo'), path], capture_output=True, text=True).stdout
    ul = re.search(r'Upper Left\s+\(\s*(-?[0-9.]+),\s*(-?[0-9.]+)\)', t)
    lr = re.search(r'Lower Right\s+\(\s*(-?[0-9.]+),\s*(-?[0-9.]+)\)', t)
    return (ul.group(1), ul.group(2), lr.group(1), lr.group(2)) if ul and lr else None

def blunder_filter(dems, ref_dem, tol):
    """Drop a per-pair DEM if its mean elevation departs from ref_dem over the SAME footprint by > tol.
    Relief-aware (compares each DEM to the reference locally, not to a global median), so it keeps real
    high/low terrain and drops only true blunders (which triangulate thousands of m off). Where the
    reference has no data over a DEM, the DEM is kept (cannot judge). Mirrors cassis_stereo.sh."""
    import tempfile
    keep, drop = [], []
    gt = find_tool('gdal_translate')
    for d in dems:
        ms = gdal_mean(d); bb = gdal_bbox(d)
        if ms is None:
            continue
        mc = None
        if bb is not None:
            with tempfile.NamedTemporaryFile(suffix='.tif', delete=False) as tf:
                crop = tf.name
            subprocess.run([gt, '-q', '-projwin', bb[0], bb[1], bb[2], bb[3], ref_dem, crop],
                           capture_output=True, text=True)
            if os.path.exists(crop):
                mc = gdal_mean(crop); os.unlink(crop)
        if mc is None or abs(ms - mc) <= tol:
            keep.append(d)
        else:
            drop.append(d)
    msg(f"  blunder filter (ref-relative, tol={tol:g} m): kept {len(keep)}, dropped {len(drop)}")
    return keep

def stage_fuse_dem_mosaic(args, pairs):
    msg("STAGE 2: dem_mosaic (DEMs) + dem_mosaic --max (tri-error)")
    dm = find_tool('dem_mosaic')
    dems = [os.path.join(pair_dir(args.out_dir, li, ri), 'run-DEM.tif') for (li, ri, _, _) in pairs]
    errs = [os.path.join(pair_dir(args.out_dir, li, ri), 'run-IntersectionErr.tif') for (li, ri, _, _) in pairs]
    dems = [d for d in dems if os.path.exists(d) or args.dryrun]
    errs = [e for e in errs if os.path.exists(e) or args.dryrun]
    # optional relief-aware blunder filter against a reference DEM (drops the DEMs AND their tri-err mates)
    if args.ref_dem and not args.dryrun:
        keep = set(blunder_filter(dems, args.ref_dem, args.blunder_tol))
        errs = [e for e, d in zip(errs, dems) if d in keep]
        dems = [d for d in dems if d in keep]
    mos = os.path.join(args.out_dir, 'dem_mosaic')
    c1 = [dm] + shlex.split(args.dem_mosaic_options) + dems + ['-o', mos + '-DEM.tif']
    c2 = [dm, '--max'] + errs + ['-o', mos + '-IntersectionErr.tif']
    run_parallel([shlex.join(c1), shlex.join(c2)], min(2, args.num_parallel), args.parallel_options, args.dryrun)
    if not args.dryrun:
        msg("  DEM mosaic:      " + mos + "-DEM.tif")
        msg("  max tri-err mos: " + mos + "-IntersectionErr.tif")

def main():
    args = parse_args()
    os.makedirs(args.out_dir, exist_ok=True)
    pairs = read_pairs(args.overlap_list)
    msg(f"{len(pairs)} pairs, mode={args.mode}, stages [{args.entry},{args.stop})")
    if args.entry <= 0 < args.stop: stage_stereo(args, pairs)
    if args.mode == 'dem_mosaic':
        if args.entry <= 1 < args.stop: stage_dem(args, pairs)
        if args.entry <= 2 < args.stop: stage_fuse_dem_mosaic(args, pairs)
    else:
        msg("mode 'mesh' not yet wired in this prototype (adapt pc_filter + voxblox from multi_stereo).")
    msg("done")

if __name__ == '__main__':
    main()
