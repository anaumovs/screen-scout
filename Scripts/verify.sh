#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts/clicker-v2
swift run ClickerChecks 2>&1 | tee artifacts/clicker-v2/core-checks.txt
python3 Scripts/audit-source.py
codesign --verify --deep --strict 'dist/Screen Scout.app'
