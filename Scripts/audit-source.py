from pathlib import Path

app = [p for p in Path('Sources/ScreenScout').glob('*.swift') if p.name != 'WindowCapture.swift']
active = app + list(Path('Sources/ScoutClicker').glob('*.swift'))
source = '\n'.join(p.read_text() for p in active)
for token in ['import Vision', 'import ScreenCaptureKit', 'CGWindowListCreateImage',
              'VNRecognizeTextRequest', 'CGRequestScreenCaptureAccess', 'URLSession', 'NWConnection']:
    if token in source:
        raise SystemExit(f'Unexpected capture/OCR/network code in active clicker: {token}')
for p in active:
    if '.post(tap:' in p.read_text() and p.name not in ['SystemMouse.swift', 'ExternalVerification.swift']:
        raise SystemExit(f'Unexpected second input producer: {p}')
monitor = Path('Sources/ScreenScout/InputMonitor.swift').read_text()
assert 'options: .listenOnly' in monitor, 'FGH must not swallow normal keyboard input'
assert '.mouseMoved' not in monitor, 'Physical mouse movement must not trigger the chord handler'
package = Path('Package.swift').read_text()
assert 'name: "ScreenScout", dependencies: ["ScoutClicker"]' in package
print('PASS: active app has no capture/OCR/network client; real mouse output has one owner; FGH uses a listen-only monitor.')
