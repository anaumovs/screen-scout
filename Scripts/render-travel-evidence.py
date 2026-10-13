"""Make a readable report from actual separate-pad events (no simulated input)."""
import json, html, sys
from pathlib import Path

source=Path(sys.argv[1]);report=json.loads(source.read_text());runs=report.get('travelClicking',[])
output=Path('artifacts/travel-v4/travel-evidence.html')
page=['<!doctype html><meta charset="utf-8"><title>Screen Scout travel-click evidence</title><style>body{font:15px system-ui;max-width:1100px;margin:28px auto;background:#f8fafc;color:#17202a}section{background:white;padding:20px;border:1px solid #ddd;border-radius:10px;margin:18px 0}svg{width:100%;max-height:560px;background:#edf2f7}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:9px;border-bottom:1px solid #ddd}small{color:#475569}</style><h1>Recorded travel and clicks</h1>']
page.append('<p>Actual events received by the independent Click Test Pad. Lines show cursor motion; orange dots show regular clicks. Red is blocked; the green rectangle is allowed. All coordinates are macOS screen points.</p>')
page.append('<small>Source: '+html.escape(str(source))+' · Result: '+html.escape(report['outcome'])+'</small>')
page.append('<section><h2>Same path, different speeds</h2><table><tr><th>Case</th><th>Elapsed travel</th><th>Regular clicks</th><th>Mean large-travel click gap</th></tr>')
for run in runs:
    duration=run['returnedAt']-run['phases'][0]['time']
    downs=[e for e in run['events'] if e['type']=='rightDown'];gaps=run['largeClickGaps'];mean=f'{sum(gaps)/len(gaps):.3f} s' if gaps else '—'
    page.append(f'<tr><td>{html.escape(run["name"])}</td><td>{duration:.3f} s</td><td>{len(downs)}</td><td>{mean}</td></tr>')
page.append('</table><p>The movement-only 1×/10× comparison excludes click holds. Click-enabled travel includes short holds for matching releases. Event-processing overhead is included in elapsed times.</p></section>')
for run in runs:
    x,y,w,h=run['allowed'];bx,by,bw,bh=run['blocked']
    moves=[e for e in run['events'] if e['type']=='move'];downs=[e for e in run['events'] if e['type']=='rightDown']
    page.append('<section><h2>'+html.escape(run['name'])+'</h2>')
    page.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x-10} {y-10} {w+20} {h+20}" role="img" aria-label="Actual recorded cursor and click positions">')
    page.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="#dcfce744" stroke="#16a34a"/><rect x="{bx}" y="{by}" width="{bw}" height="{bh}" fill="#ef4444" stroke="#ef4444"/>')
    points=' '.join(f'{e["x"]},{e["y"]}' for e in moves)
    page.append(f'<polyline points="{points}" fill="none" stroke="#2563eb" stroke-width="1.5"/>')
    for e in downs:page.append(f'<circle cx="{e["x"]}" cy="{e["y"]}" r="4" fill="#ea580c" stroke="white" stroke-width="1"/>')
    page.append('</svg><details><summary>Click timestamps and coordinates</summary><table><tr><th>Seconds since start</th><th>X</th><th>Y</th></tr>')
    for e in downs:page.append(f'<tr><td>{e["eventTime"]-run["startedAt"]:.4f}</td><td>{e["x"]:.3f}</td><td>{e["y"]:.3f}</td></tr>')
    page.append('</table></details></section>')
page.append('<p>Physical keyboard/mouse and Minecraft input acceptance are not established by these generated external-input tests. Full check results and limitations are in VERIFICATION.md.</p>')
output.write_text(''.join(page));print(output)
