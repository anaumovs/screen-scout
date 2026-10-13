#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts/clicker-v2
app_path="$PWD/dist/Screen Scout.app"
if pgrep -f "$app_path/Contents/MacOS/ScreenScout" >/dev/null; then
    echo 'Quit Screen Scout first, then rerun this script. This avoids a second clicking controller.'
    exit 2
fi
report_path="$PWD/artifacts/clicker-v2/external-report-$(date +%Y%m%d-%H%M%S).json"
# The app only needs input permissions. Put receiver IPC outside protected Documents;
# this terminal runner copies the completed evidence back into the workspace.
run_dir="$(mktemp -d /tmp/screenscout-verification.XXXXXX)"
runtime_report="$run_dir/report.json"
open -n "$app_path" --args --verify-external "$runtime_report"
echo "External verification requested. Report: $report_path"
echo 'The test sends actual mouse input only to the bundled external pad. If that pad loses focus, the test stops.'
python3 - "$runtime_report" "$report_path" <<'PY'
import json, shutil, sys, time
from pathlib import Path
runtime, destination = map(Path, sys.argv[1:])
deadline = time.monotonic() + 240
while not runtime.exists() and time.monotonic() < deadline:
    time.sleep(0.25)
if not runtime.exists():
    raise SystemExit(f'No report within 240 seconds. Inspect the app; runtime evidence is in {runtime.parent}.')
report = json.loads(runtime.read_text())
receiver = report.get('receiverLog')
if receiver:
    source = Path(receiver)
    saved = destination.parent / source.name
    shutil.copy2(source, saved)
    report['receiverLog'] = str(saved)
report['runtimeReportPath'] = str(runtime)
destination.write_text(json.dumps(report, indent=2) + '\n')
print(f"Live test: {report['outcome']}; {sum(c.get('passed', False) for c in report.get('checks', []))}/{len(report.get('checks', []))} checks passed.")
print(destination)
if report['outcome'] != 'passed':
    raise SystemExit(1)
PY
