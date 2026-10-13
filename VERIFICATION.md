# Screen Scout 2.3 verification — 2026-09-30

**Release 2.3.0 (build 5) built successfully. All 111 logic checks and all 110 external checks passed.** Screen Scout was left open and Stopped, with the user's settings restored. No ordinary clicking session was started after verification.

This is a historical record of the September 30, 2026 local verification. The referenced generated evidence, settings snapshots, and packaged binaries are not tracked in this repository. Use the included scripts to produce new verification results on your own Mac.

## Delivered app

`dist/Screen Scout.app`

The runnable app and companion Click Test Pad are also in `dist/Screen Scout.zip`. This is a locally signed Apple Silicon build for macOS 14 or later. `artifacts/travel-v4/delivery-sha256.json` records the exact tested binaries. Packaging does not rebuild or change those binaries.

## Commands actually completed

- `./Scripts/build-app.sh`: release builds of both apps, signing, signature checks, app packaging.
- `./Scripts/verify.sh`: **111 checks, zero failures**, source audit, signature verification. The installed Command Line Tools emitted an XCTest-path warning; the standalone check executable completed successfully.
- `./Scripts/verify-external.sh`: **110/110 passed** after permissions were renewed for this build.
- `python3 Scripts/audit-travel-evidence.py artifacts/clicker-v2/external-report-20260930-165900.json`: independent receiver-data audit, settings restoration and binary hash checks.
- `python3 Scripts/render-travel-evidence.py artifacts/clicker-v2/external-report-20260930-165900.json`: readable plots of the actual received paths and clicks.

## Real external results

The separate foreground Click Test Pad process recorded **223 matching click pairs: 212 right, 11 left**. No engine movement occurred between matching down/up events, and paired coordinates matched. The intentional untagged manual-movement test displaced the pointer once during an ordinary click hold; this external displacement is recorded separately in the audit. Engine travel animation remained suspended during its click pairs.

The new suite exercised all four small/large travel-click combinations, both outward and return phases, the main regular-clicking override, fixed cadence at different speeds, no arrival bonus or catch-up burst, region compliance, Pause and Stop during actual travel mouse-down, and timer expiry followed by one exact final click. The existing checks also passed for left/right input, F/G/H and I/O/P global debouncing and key passthrough, generated manual pointer movement, breaks, emergency stopping, variations, and timer pause/resume.

The same deterministic large route was replayed through the production engine at both speeds. The external receiver recorded the **same 264 movement samples**, in the same order, with clicking disabled:

| Setting | Outward + return elapsed time | Comparison |
| --- | --- | --- |
| 1× | 7.306 seconds | Baseline |
| 10× | 1.982 seconds | 3.686 times faster in this live run |

The multiplier scales requested animation delays; macOS dispatch and per-event checks add overhead, so wall-clock travel is not guaranteed to be exactly ten times faster. All samples and safety checks are retained. The fake-clock tests confirm exact timing scaling and unchanged small-movement timing.

With travel clicking enabled and a configured 0.160-second interval, measured large-travel click gaps averaged **0.166613 seconds at 1×** and **0.165978 seconds at 10×**. Observed ranges were 0.160063–0.188739 seconds and 0.161712–0.185894 seconds, respectively. Faster travel reduced the number of clicks during the shorter excursion without increasing click frequency. Click holds add time to movement.

An independent slab-intersection audit of **2,262 recorded movement segments** across the eight new travel scenarios found zero crossings of the thin blocked rectangle and zero out-of-allowed-bounds samples, including at 10×. The app's live checks also validated actual travel-click coordinates against the path and region rules.

## Logic and preservation checks

The 22 new checks cover migration, disabled-value retention, speed validation, all switch combinations, fixed/random cadence, exact sample preservation, no extra break/movement draws, sampled return-coordinate preservation, thin obstacles at maximum speed, safe rejoining after manual displacement, cancellation/release during a held pair, timer expiry, exact-once final clicks, and one pending continuation. All 89 earlier checks still pass.

All **27 existing stored setting keys** retained their values. The new defaults are **1×**, small travel clicking **off**, and large travel clicking **off**, as requested. The full migrated settings object was restored after the live test. The original preference key remains unchanged.

The checkpoint diff was reviewed. Curved geometry, region validation/editor, display handling, input monitoring, real mouse event production, shortcut handling, permissions, and single-instance ownership files remain unchanged. Production changes are confined to the requested settings, controls, and coordinated engine scheduling, plus a command-line-gated deterministic test fixture and the version number. Verification helpers and documentation were updated.

## Evidence and attempt history

- `artifacts/clicker-v2/external-report-20260930-165900.json`: complete successful external checks and per-scenario event data.
- `artifacts/clicker-v2/external-pad-83C46C44-7918-484A-89EC-F312B934D4EC.json`: independent receiver log.
- `artifacts/travel-v4/travel-evidence.html`: actual path plots, click positions and timestamps.
- `artifacts/travel-v4/verification-checks.txt`: all 111 logic results and source audit.
- `artifacts/travel-v4/final-verification.json`: independent segment/pair audit, settings restoration and unchanged tested-binary checks.
- `artifacts/travel-v4/settings-migration.json`: old-setting comparison and migration defaults.
- `artifacts/travel-v4/source.patch` and `scope.json`: checkpoint diff and change inventory.

The earlier attempt `external-report-20260930-165502.json` was blocked before any checks because the rebuilt app lacked valid Accessibility/Input Monitoring grants. After the user renewed both grants, the unchanged binary passed. Previous 2.2 results are historical and preserved in `artifacts/travel-v4/previous-verification.md` and the package's previous-version reports.

## Not verified

Minecraft acceptance of synthetic input, captured-cursor/fullscreen gameplay, physical keyboard rollover, physical mouse behavior, visual native-control interaction, real multi-display rearrangement, and active sleep/lock transitions were not hands-on tested. Keyboard chords and manual-style pointer moves in the external suite were generated macOS input. Permission-loss cancellation was verified with controlled output availability in logic tests; permissions were not revoked midway through a live click. No target-app acceptance or exact wall-clock multiplier beyond the recorded test is promised.
