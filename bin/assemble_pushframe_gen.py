#!/usr/bin/env python3
# Generalized: assemble a CaSSIS push-frame ISD for one look by merging its
# per-framelet FRAME ISDs (made by isd_gen.py) into a strip trajectory. Mirrors
# assemble_pushframe.py but takes args so it works for any pair.
# Usage: assemble_pushframe_gen.py <data_dir_with_L*_<sid>> <sid> <reverse 0|1> <keep> <out.json>
#   reverse=1  -> framelet_order_reversed=true (the ~180 deg telescope-rotated look,
#                 whose strip was stacked in reverse order; see stack_strip_gen.py)
#   keep       -> framelet_height in the strip (= the trimmed central rows)
import json, glob, re, sys, copy

data_dir, sid, reverse, keep, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]

def merge_table(base_tab, isds, key, arrays):
    tab = copy.deepcopy(base_tab)
    times = []
    cols = {a: [] for a in arrays}
    for d in isds:
        v = d[key]
        times += v['ephemeris_times']
        for a in arrays:
            if a in v and v[a] is not None:
                cols[a] += v[a]
    order = sorted(range(len(times)), key=lambda i: times[i])
    tab['ephemeris_times'] = [times[i] for i in order]
    for a in arrays:
        if cols[a] and len(cols[a]) == len(order):
            tab[a] = [cols[a][i] for i in order]
    for sk, ek, osz in [('spk_table_start_time','spk_table_end_time','spk_table_original_size'),
                        ('ck_table_start_time','ck_table_end_time','ck_table_original_size')]:
        if sk in tab:
            tab[sk] = tab['ephemeris_times'][0]; tab[ek] = tab['ephemeris_times'][-1]
            tab[osz] = len(tab['ephemeris_times'])
    return tab

files = glob.glob(f'{data_dir}/L*_{sid}/*-{sid}-*-0__4_0.json')
idx = lambda f: int(re.search(rf'-{sid}-(\d+)-0__4_0', f).group(1))
files = sorted(files, key=idx)
isds = [json.load(open(f)) for f in files]
n = len(isds)
base = copy.deepcopy(isds[0])
orig_fh = isds[0]['image_lines']                 # original framelet height (280)
fh = keep
trim_top = (orig_fh - fh) // 2                    # rows removed from each framelet top
base['instrument_position'] = merge_table(base['instrument_position'], isds, 'instrument_position', ['positions','velocities'])
base['instrument_pointing'] = merge_table(base['instrument_pointing'], isds, 'instrument_pointing', ['quaternions','angular_velocities'])
base['body_rotation']       = merge_table(base['body_rotation'],       isds, 'body_rotation',       ['quaternions','angular_velocities'])
if 'sun_position' in base:
    base['sun_position']    = merge_table(base['sun_position'],        isds, 'sun_position',        ['positions','velocities'])
times = [d['center_ephemeris_time'] for d in isds]
exposure = isds[0].get('exposure_duration', 0.001574)
interframe = (times[-1] - times[0]) / (n - 1)
base['name_model']              = 'USGS_ASTRO_PUSH_FRAME_SENSOR_MODEL'
base['image_lines']             = fh * n
base['framelet_height']         = fh
base['interframe_delay']        = interframe
base['exposure_duration']       = exposure
base['num_lines_overlap']       = 0
base['framelets_flipped']       = False
base['framelet_order_reversed'] = bool(reverse)
# CRITICAL: trimming trim_top rows off each framelet top shifts the detector
# origin; carry it so the off-axis CASSIS distortion is evaluated correctly.
base['starting_detector_line']  = isds[0].get('starting_detector_line', 0) + trim_top
base['starting_ephemeris_time'] = times[0] - 0.5 * exposure
base['center_ephemeris_time']   = times[0] + (n - 1) / 2.0 * interframe
base['ending_ephemeris_time']   = times[-1] + 0.5 * exposure
json.dump(base, open(out, 'w'), indent=2)
print(f"{out}: {n} framelets, image_lines={base['image_lines']}, fh={fh}, "
      f"order_reversed={bool(reverse)}, interframe={interframe:.5f}s, "
      f"start_det_line={base['starting_detector_line']}, "
      f"traj pos={len(base['instrument_position']['ephemeris_times'])}")
