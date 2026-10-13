"""Render receiver-recorded trajectories, not planned/simulated paths."""
import json, sys, html
from pathlib import Path

report_path=Path(sys.argv[1]);report=json.loads(report_path.read_text())
out=Path('artifacts/movement-v3/trajectory-report.html')
colors={'Small outward':'#16a34a','Small return':'#0891b2','Large outward':'#9333ea','Large return':'#ea580c'}
parts=['<!doctype html><meta charset="utf-8"><title>Screen Scout recorded movement</title><style>body{font:16px system-ui;max-width:1100px;margin:30px auto;background:#f8fafc;color:#17202a}section{background:white;padding:20px;margin:20px 0;border:1px solid #ddd;border-radius:12px}svg{width:100%;max-height:650px;background:#edf2f7}small{color:#475569}code{font-size:12px}input{margin-right:8px}</style><h1>Recorded external cursor trajectories</h1>']
parts.append('<p>Actual mouse events received by the separate Click Test Pad. Coordinates are macOS screen points, with y increasing downward. Colored paths join received events; dots show individual events. Red rectangles are blocked; the green outline marks the allowed area. This shows observed paths, not intended Bézier controls.</p>')
parts.append('<p><small>Source: '+html.escape(str(report_path))+' · Outcome: '+html.escape(report['outcome'])+'</small></p>')
for case in report.get('trajectories',[]):
 if not case['phases']:continue
 allowed=case['allowed'];blocked=case['blocked']
 allpoints=[case['start']]+[[r['x'],r['y']] for p in case['phases'] for r in p['events']]
 if case['case']==0:
  xs=[p[0] for p in allpoints];ys=[p[1] for p in allpoints];view=[min(xs)-12,min(ys)-12,max(xs)-min(xs)+24,max(ys)-min(ys)+24]
 else:view=[allowed[0]-10,allowed[1]-10,allowed[2]+20,allowed[3]+20]
 parts.append('<section><h2>'+{0:'Small movement',1:'Large movement',2:'Both, sequentially'}[case['case']]+'</h2>')
 for index,phase in enumerate(case['phases']):
  ident=f"phase-{case['case']}-{index}";color=colors[phase['phase']]
  parts.append(f'<label style="color:{color}"><input type="checkbox" checked onchange="document.getElementById(\'{ident}\').style.display=this.checked?\'\':\'none\'">{html.escape(phase["phase"])}</label> ')
 parts.append('<svg xmlns="http://www.w3.org/2000/svg" viewBox="'+' '.join(map(str,view))+'" role="img" aria-label="Recorded mouse trajectories">')
 parts.append(f'<rect x="{allowed[0]}" y="{allowed[1]}" width="{allowed[2]}" height="{allowed[3]}" fill="#dcfce733" stroke="#22c55e" stroke-width="1"/>')
 parts.append(f'<rect x="{blocked[0]}" y="{blocked[1]}" width="{blocked[2]}" height="{blocked[3]}" fill="#ef444499" stroke="#dc2626" stroke-width="1"/>')
 for index,phase in enumerate(case['phases']):
  points=[phase['start']]+[[r['x'],r['y']] for r in phase['events']]
  color=colors[phase['phase']];width=.45 if case['case']==0 else 1.3
  parts.append(f'<g id="phase-{case["case"]}-{index}"><polyline points="'+ ' '.join(f'{x},{y}' for x,y in points)+f'" fill="none" stroke="{color}" stroke-width="{width}"/>')
  for x,y in points:parts.append(f'<circle cx="{x}" cy="{y}" r="{width*.65}" fill="{color}"/>')
  parts.append('</g>')
 ax,ay=case['anchor'];parts.append(f'<circle cx="{ax}" cy="{ay}" r="2" fill="#111827"/><text x="{ax+4}" y="{ay+5}" font-size="{3 if case["case"]==0 else 11}">saved anchor</text></svg>')
 for phase in case['phases']:parts.append(f'<p>{html.escape(phase["phase"])}: {len(phase["events"])} received events; maximum distance from its straight endpoint chord {phase["maximumChordDeviation"]:.3f} points; region segment check {"passed" if phase["segmentsCompliant"] else "failed"}.</p>')
 parts.append('</section>')
parts.append('<p>Small movement is exempt from the boxes. Native region drawing/resizing, physical keyboard/mouse hardware, multiple real displays and Minecraft were not tested by this report.</p>')
out.write_text(''.join(parts));print(out)
