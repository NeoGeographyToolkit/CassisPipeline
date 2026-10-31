#!/usr/bin/env python3
# cassis_gallery.py - build a self-contained HTML results gallery for a set of CaSSIS DEMs evaluated
# against a CTX reference. Generic: the site list + metadata come from a MANIFEST, and the per-site
# metrics come from the <tag>_stats.tsv files that cassis_eval_plots.py writes next to the panels.
#
# Per site it lays out the six cassis_eval_plots panels, 3 per row (each scales to ~1/3 width):
#   row 1: CTX reference DEM | aligned linescan DEM | final stage-7 framelet DEM   (coverage check)
#   row 2: dz (m) | dd-H across-track (px) | dd-V along-track (px)                  (registration)
# plus a summary table ranked by dz NMAD. Images are embedded as data URIs so the page is portable.
#
# Usage: cassis_gallery.py <manifest.tsv> <panels_dir> <out.html> [title]
#   manifest.tsv : one line per site, TAB-separated, '#'/blank lines ignored, columns:
#       tag  id  coord  conv  group  note
#     e.g.  003837<TAB>MY34_003837_009<TAB>8.9&deg;N, 155.9&deg;E<TAB>23.1&deg;<TAB>run A<TAB>Tightest fit...
#   panels_dir : holds <tag>_{1ctx,2linescan,3final,4dz,5ddh,6ddv}.png and <tag>_stats.tsv per site
import base64, pathlib, sys, html as _html

if len(sys.argv) < 4:
    sys.exit("usage: cassis_gallery.py <manifest.tsv> <panels_dir> <out.html> [title]")
manifest, pdir, outhtml = sys.argv[1:4]
title = sys.argv[4] if len(sys.argv) > 4 else "CaSSIS DEMs registered to CTX"
P = pathlib.Path(pdir)

def b64(name):
    f = P/name
    return "data:image/png;base64," + base64.b64encode(f.read_bytes()).decode() if f.exists() else ""

def stats(tag):
    f = P/f"{tag}_stats.tsv"
    if not f.exists(): return None
    p = f.read_text().strip().split('\t')
    return dict(dzm=float(p[1]), dzn=float(p[2]), hm=float(p[3]), hn=float(p[4]), vm=float(p[5]), vn=float(p[6]))

sites = []
for ln in pathlib.Path(manifest).read_text().splitlines():
    if not ln.strip() or ln.lstrip().startswith('#'): continue
    c = ln.split('\t')
    g = dict(tag=c[0], id=c[1], coord=c[2] if len(c) > 2 else '', conv=c[3] if len(c) > 3 else '',
             group=c[4] if len(c) > 4 else '', note=c[5] if len(c) > 5 else '')
    g['st'] = stats(g['tag'])
    sites.append(g)
sites.sort(key=lambda g: g['st']['dzn'] if g['st'] else 1e9)

def pill(g):
    if not g['st']: return '<span class="pill ok">no stats</span>'
    v = "good" if g['st']['dzn'] <= 6 else "ok"
    return f'<span class="pill {v}">dz NMAD {g["st"]["dzn"]:.1f} m</span>'

cards = ""
for g in sites:
    p = {k: b64(f"{g['tag']}_{k}.png") for k in ['1ctx', '2linescan', '3final', '4dz', '5ddh', '6ddv']}
    s = g['st'] or dict(dzm=0, dzn=0, hm=0, hn=0, vm=0, vn=0)
    grp = f'<span class="tag">{_html.escape(g["group"])}</span>' if g['group'] else ''
    cards += f"""
    <article class="site">
      <header class="site-h"><h2>{_html.escape(g['id'])}</h2>{pill(g)}{grp}<span class="coord">{g['coord']} &middot; conv {g['conv']}</span></header>
      <div class="grid3">
        <figure><img src="{p['1ctx']}" alt="CTX"><figcaption>CTX reference DEM</figcaption></figure>
        <figure><img src="{p['2linescan']}" alt="linescan"><figcaption>aligned linescan CaSSIS DEM</figcaption></figure>
        <figure><img src="{p['3final']}" alt="final"><figcaption>final stage-7 framelet DEM</figcaption></figure>
      </div>
      <div class="grid3">
        <figure><img src="{p['4dz']}" alt="dz"><figcaption>dz = CaSSIS &minus; CTX (m) &middot; median {s['dzm']:+.2f} / NMAD {s['dzn']:.2f}</figcaption></figure>
        <figure><img src="{p['5ddh']}" alt="ddh"><figcaption>dd-H across-track (px &times;18 m) &middot; {s['hm']:+.2f} / NMAD {s['hn']:.2f}</figcaption></figure>
        <figure><img src="{p['6ddv']}" alt="ddv"><figcaption>dd-V along-track (px &times;18 m) &middot; {s['vm']:+.2f} / NMAD {s['vn']:.2f}</figcaption></figure>
      </div>
      <p class="cap">{g['note']}</p>
    </article>"""

rows = ""
for g in sites:
    s = g['st']
    if not s:
        rows += f'<tr><td class="mono">{_html.escape(g["id"])}</td><td>{g["group"]}</td><td colspan="4">&mdash;</td></tr>'; continue
    rows += (f'<tr><td class="mono">{_html.escape(g["id"])}</td><td>{g["group"]}</td>'
             f'<td>{s["dzm"]:+.2f}</td><td>{s["dzn"]:.2f}</td><td>{s["hm"]:+.2f}</td><td>{s["vm"]:+.2f}</td></tr>')

body = f"""<div class="wrap">
  <header class="top">
    <p class="eyebrow">TGO CaSSIS &middot; stereo DEM &middot; Mars</p>
    <h1>{_html.escape(title)} &mdash; {len(sites)} sites</h1>
    <p class="lede">Each CaSSIS stereo pair taken end to end to a delivered DEM, evaluated against a controlled-CTX reference. Per site, row 1 shows the <b>CTX reference</b>, the <b>aligned linescan</b> DEM, and the <b>final stage-7</b> DEM &mdash; they should cover the same ground; row 2 shows the <b>dz</b> (metres) and the <b>dd-H / dd-V</b> registration disparity (pixels).</p>
    <div class="tbl-wrap"><table>
      <thead><tr><th>pair</th><th>group</th><th>dz median (m)</th><th>dz NMAD (m)</th><th>dd-H med (px)</th><th>dd-V med (px)</th></tr></thead>
      <tbody>{rows}</tbody>
    </table></div>
  </header>
  <section class="gallery">{cards}
  </section>
</div>"""

style = """
:root{ --bg:#f3f3f0; --surface:#fbfbf9; --ink:#1b1e22; --muted:#5c626b; --faint:#8a909a; --accent:#b25f20; --good:#2f7d49; --border:#e3e2dd; --shadow:0 1px 2px rgba(20,20,20,.05),0 8px 24px rgba(20,20,20,.05);}
@media (prefers-color-scheme:dark){ :root{ --bg:#141619; --surface:#1c1f23; --ink:#e9eaec; --muted:#9aa0a9; --faint:#6b717a; --accent:#d9893f; --good:#51b06e; --border:#2b2f35; --shadow:0 1px 2px rgba(0,0,0,.3),0 8px 28px rgba(0,0,0,.35);}}
:root[data-theme="light"]{ --bg:#f3f3f0; --surface:#fbfbf9; --ink:#1b1e22; --muted:#5c626b; --faint:#8a909a; --accent:#b25f20; --good:#2f7d49; --border:#e3e2dd;}
:root[data-theme="dark"]{ --bg:#141619; --surface:#1c1f23; --ink:#e9eaec; --muted:#9aa0a9; --faint:#6b717a; --accent:#d9893f; --good:#51b06e; --border:#2b2f35;}
*{box-sizing:border-box} .mono{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.86em;}
body{margin:0;background:var(--bg);color:var(--ink);font-family:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;line-height:1.55;-webkit-font-smoothing:antialiased;}
.wrap{max-width:1180px;margin:0 auto;padding:44px 22px 70px;}
.eyebrow{font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:var(--accent);font-weight:600;margin:0 0 10px;}
h1{font-size:clamp(26px,4vw,40px);line-height:1.06;letter-spacing:-.02em;margin:0 0 14px;text-wrap:balance;font-weight:700;}
.lede{font-size:16px;color:var(--muted);max-width:72ch;margin:0 0 22px;} .lede b{color:var(--ink);font-weight:600;}
.tbl-wrap{overflow-x:auto;border:1px solid var(--border);border-radius:10px;background:var(--surface);box-shadow:var(--shadow);}
table{border-collapse:collapse;width:100%;font-size:13.5px;font-variant-numeric:tabular-nums;} th,td{text-align:right;padding:9px 15px;border-bottom:1px solid var(--border);} th:first-child,td:first-child{text-align:left;}
thead th{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--faint);font-weight:600;} tbody tr:last-child td{border-bottom:none;}
.gallery{display:flex;flex-direction:column;gap:26px;margin:32px 0;}
.site{background:var(--surface);border:1px solid var(--border);border-radius:12px;padding:18px;box-shadow:var(--shadow);}
.site-h{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:14px;} .site-h h2{font-size:16px;margin:0;font-family:ui-monospace,Menlo,monospace;font-weight:600;}
.coord{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.78em;color:var(--muted);white-space:nowrap;margin-left:auto;}
.tag{font-size:11px;color:var(--faint);border:1px solid var(--border);border-radius:5px;padding:1px 6px;}
.grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-bottom:12px;}
.grid3 figure{margin:0;text-align:center;} .grid3 img{width:100%;height:auto;border-radius:5px;background:#efefec;border:1px solid var(--border);}
.grid3 figcaption{font-size:11.5px;color:var(--faint);margin-top:6px;line-height:1.35;}
.cap{font-size:13.5px;color:var(--muted);margin:10px 2px 2px;max-width:96ch;} .cap b{color:var(--ink);font-weight:600;}
.pill{display:inline-block;font-size:11.5px;font-weight:600;padding:3px 9px;border-radius:999px;border:1px solid transparent;white-space:nowrap;}
.pill.good{color:var(--good);background:color-mix(in srgb,var(--good) 14%,transparent);border-color:color-mix(in srgb,var(--good) 30%,transparent);}
.pill.ok{color:var(--accent);background:color-mix(in srgb,var(--accent) 14%,transparent);border-color:color-mix(in srgb,var(--accent) 30%,transparent);}
@media (max-width:720px){ .grid3{grid-template-columns:1fr;} .site-h .coord{margin-left:0;width:100%;} }
"""
out = f'<title>{_html.escape(title)}</title>\n<style>{style}</style>\n{body}\n'
pathlib.Path(outhtml).write_text(out)
print(f"wrote {len(out)} bytes, {len(sites)} sites -> {outhtml}")
