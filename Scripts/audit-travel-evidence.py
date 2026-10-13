"""Independently audit received events, packaged input binaries, and restored settings."""
import collections
import hashlib
import json
import plistlib
import statistics
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
destination = root / 'artifacts/travel-v4'
source = Path(sys.argv[1]).resolve()
report = json.loads(source.read_text())
receiver = json.loads(Path(report['receiverLog']).read_text())
events, seen = [], set()
for event in receiver['events']:
    # Tracking areas can duplicate a posted move; untagged external moves are distinct.
    key = (event.get('tag'), event['type'], None if event.get('tag') else event['eventTime'])
    if key not in seen:
        seen.add(key)
        events.append(event)

held, pairs, violations, external_displacements = None, collections.Counter(), [], []
for event in events:
    kind = event['type']
    if kind in ('leftDown', 'rightDown'):
        if held:
            violations.append('overlapping down')
        held = event
    elif kind in ('leftUp', 'rightUp'):
        if not held or held['type'].replace('Down', 'Up') != kind or (held['x'], held['y']) != (event['x'], event['y']):
            violations.append('unmatched or displaced up')
        else:
            pairs[kind.removesuffix('Up')] += 1
        held = None
    elif held and kind in ('move', 'leftDrag', 'rightDrag'):
        if event.get('tag', 0) & 0xFFFF000000000000 == 0x5343000000000000:
            violations.append('engine movement during hold')
        else:
            external_displacements.append(event)
if held:
    violations.append('unreleased down')


def intersects(a, b, box):
    """Closed slab intersection, independent of the app's region code."""
    low, high = 0., 1.
    for axis in range(2):
        start, end = box[axis], box[axis] + box[axis + 2]
        delta = b[axis] - a[axis]
        if delta == 0:
            if a[axis] < start or a[axis] > end:
                return False
        else:
            lo, hi = sorted(((start - a[axis]) / delta, (end - a[axis]) / delta))
            low, high = max(low, lo), min(high, hi)
            if low > high:
                return False
    return True


runs, segments, invalid = [], 0, []
for run in report['travelClicking']:
    previous, samples, checked = None, 0, 0
    ax, ay, aw, ah = run['allowed']
    for event in run['events']:
        if event['type'] != 'move':
            continue
        point = (event['x'], event['y'])
        samples += 1
        if not (ax <= point[0] <= ax + aw and ay <= point[1] <= ay + ah):
            invalid.append([run['name'], 'outside allowed', point])
        if previous is not None:
            segments += 1
            checked += 1
            if intersects(previous, point, run['blocked']):
                invalid.append([run['name'], 'blocked segment', previous, point])
        previous = point
    gaps = run['largeClickGaps']
    runs.append({
        'name': run['name'], 'durationSeconds': run['returnedAt'] - run['phases'][0]['time'],
        'movementSamples': samples, 'segmentsChecked': checked,
        'clicks': sum(event['type'] == 'rightDown' for event in run['events']),
        'largeClickGapSeconds': {'min': min(gaps), 'mean': statistics.mean(gaps), 'max': max(gaps)} if gaps else None,
    })

slow, fast = [run for run in report['travelClicking'] if run['name'].startswith('Movement-only')]
def points(run):
    return [(event['x'], event['y']) for event in run['events'] if event['type'] == 'move']

saved = plistlib.loads((destination / 'migrated-settings.plist').read_bytes())
live = plistlib.loads(subprocess.check_output(['defaults', 'export', 'local.screenscout.app', '-']))
expected = json.loads((destination / 'delivery-sha256.json').read_text())
result = {
    'externalReport': str(source),
    'checksPassed': sum(check['passed'] for check in report['checks']), 'checksTotal': len(report['checks']),
    'appStatusAtEnd': report['appStatusAtEnd'], 'recordedPairs': dict(pairs), 'pairViolations': violations,
    'untaggedExternalDisplacementsDuringHold': external_displacements,
    'externalDisplacementNote': 'The manual-movement test posts an untagged move independently of the engine; it does not establish animation during a click hold.',
    'travelSegmentsChecked': segments, 'regionViolations': invalid,
    'samePathAtBothSpeeds': points(slow) == points(fast), 'runs': runs,
    'settingsRestored': json.loads(saved['ClickerSettingsV2']) == json.loads(live['ClickerSettingsV2']),
    'approvedBinariesUnchanged': all(hashlib.sha256((root / path).read_bytes()).hexdigest() == digest for path, digest in expected.items()),
    'minecraftTested': False, 'physicalKeyboardMouseTested': False, 'nativeUIVisualTested': False,
}
(destination / 'final-verification.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({key: value for key, value in result.items() if key not in ('runs', 'untaggedExternalDisplacementsDuringHold')}, indent=2))
assert not violations and not invalid and result['samePathAtBothSpeeds'] and result['settingsRestored'] and result['approvedBinariesUnchanged']
