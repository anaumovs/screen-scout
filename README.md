# Screen Scout 2.4.1

**[Download Screen Scout for Mac (ZIP)](https://github.com/anaumovs/screen-scout/releases/latest/download/Screen-Scout-macOS.zip)**

For Intel and Apple silicon Macs running macOS 14 or later. Unzip the download and drag Screen Scout into Applications.

Adds optional secondary-area clicking in Advanced: draw a purple area, choose a minimum and maximum wait (defaults 5–10 seconds), and the pointer curves there, clicks once, and curves back. The option defaults off. Red blocked regions constrain these visits. Pause freezes the wait; Stop resets it. Moving the pointer during a visit pauses it.

# Screen Scout 2.3 — macOS auto-clicker

Screen Scout is a realistic auto clicker for macOS with customizable click timing, curved mouse movement, and automatic breaks. It can automate repetitive game tasks, such as Minecraft farms, with adjustable click and movement patterns for different games.

**Position your mouse over the target, then press F + G + H. Press it again to pause.**

Screen Scout sends real left/right mouse events outside its own window. It starts stopped, uses one mouse controller, and has no screenshot, OCR, recognition or calibration workflow. Existing settings and the original shortcuts are preserved.

## Open and allow access

Build the app from source using Apple's Xcode Command Line Tools (Swift 5.9 or later):

```sh
git clone https://github.com/anaumovs/screen-scout.git
cd screen-scout
./Scripts/build-app.sh
open "dist/Screen Scout.app"
```

The build produces `dist/Screen Scout.app`, the companion `Click Test Pad.app`, and a ZIP package. Build outputs are generated locally and are not tracked in this repository. You can copy Screen Scout to Applications and drag it to the Dock for quick access. The custom icon artwork is saved in `Resources/ScreenScoutIcon.png` and included automatically by the build script.

Open `dist/Screen Scout.app` on an Intel or Apple silicon Mac running macOS 14 or later. Enable **Screen Scout** in **System Settings → Privacy & Security → Accessibility** and **Input Monitoring**. The app has buttons for requesting these permissions and opening the settings panes. Screen Recording is not required.

A new locally signed build can invalidate old grants even if their switches still look enabled. The app cannot grant its own permissions. If needed, remove the stale Screen Scout entry and approve the current build again, then reopen it. Clicking stays unavailable without permissions and global shortcuts. Regular clicking shows Starting until its mouse events are acknowledged by macOS; a movement-only or timer-only session does not need a click acknowledgement.

## Session controls and targets

- **F + G + H:** capture the current pointer as the regular target and start/resume; press again to pause. Release all three keys before toggling again. Holding keys and auto-repeat do not repeatedly toggle.
- **Start:** use the saved regular target. If one is required but missing, a five-second Set target countdown gives you time to position the pointer. Timer-only and movement-only sessions do not need a regular target.
- **Pause:** cancel pending mouse actions and freeze the remaining timer. Resume explicitly to continue. F/G/H resume can choose a new regular target while retaining the remaining time.
- **Stop / emergency F8:** cancel the session and release any held button. The next fresh Start uses the full configured duration. F8 may require Fn on some keyboards; the emergency key remains configurable in Advanced.
- **I + O + P:** save the pointer's exact coordinate as the separate final target. This emits no click, starts no session and does not change the regular target. All three keys must be released to capture again. Capturing during a session pauses it until explicitly resumed.
- **Manual mouse movement:** does not pause or replace either target. Subsequent regular clicks return to the regular target.

Both chords are keyboard-layout aware and listen-only: the letters still reach the focused app. They can also activate game controls. Advanced can inspect a Minecraft `options.txt` for F/G/H conflicts without modifying it. Check I/O/P bindings in the application as well. Rapid typing that holds every key of a chord simultaneously is indistinguishable from the requested chord.

Targets are session-only and are cleared on relaunch or display-configuration changes. Screen Scout's own frontmost controls and off-display coordinates cannot be targets. Coordinates and radii use **macOS screen points**, not physical display pixels.

## Independent switches

Regular clicking and the session timer are in the main controls. The other switches and their settings are under **Advanced**. Turning any switch off retains its configuration. Changing a setting during a session pauses it until explicitly resumed.

| Switch | Behavior |
| --- | --- |
| Regular auto-clicking | Enables repeated left/right clicks. Movement and the timer can run with this off. |
| Randomized click intervals | Selects a fresh interval between the stored minimum and maximum. Off uses the existing basic interval (their midpoint) as a fixed interval. |
| Small movements / Large movements | Independent switches and probabilities **per action cycle**. Both can run sequentially before the cycle's ordinary click, with optional travel clicks. Each retains its own frequency while disabled. |
| Automatic breaks | Enables randomly selected breaks and durations. Off skips breaks entirely. |
| Slight click-position variation | Samples a new return/click offset within the radius around the original regular target for each action cycle. Default radius: 2 points; maximum: 10. Off or zero uses the exact regular target. Down and up share one coordinate. |
| Session timer | Enables the hours/minutes/seconds duration and visible countdown. For example, 00:31:26 is 1,886 seconds. Off preserves unlimited running. |
| Final click at timer completion | Requires an enabled timer and a valid target captured with I/O/P. It works independently of regular clicking and has its own left/right selection, initially matching the previous regular click preference. |

Migration retains the previously selected movement type, enabled state, frequency, radius and display; the other movement type starts disabled. All non-movement preferences are retained, including timer, final button and variation settings. The preference key remains `ClickerSettingsV2`.

## Movement and regions

Small and large excursions begin at the **current pointer**, follow spatial cubic Bézier curves out and independently back, with eased arc-length pacing. Both selected in a cycle run through the same serialized engine. By default, no clicks occur during travel. Each movement type now has its own optional **Click while moving** switch. One area-uniform click-variation coordinate is sampled before movement; the return ends at that exact down/up coordinate. The original target never drifts. Movement-only sessions without a saved target return to each excursion's starting point.

**Edit large-movement regions…** pauses automation and opens an overlay on the selected display. Draw green allowed or red blocked rectangles. Choose **Move / resize**, drag a rectangle or its corner handles, or **Delete selected**. **Clear**, **Save**, and **Cancel** are provided. There can be up to 32 rectangles. Closing the editor does not resume automation, and start/capture chords are gated while it is open.

With no allowed boxes, the display is allowed minus blocked boxes. Otherwise, allowed boxes form a union, with blocked boxes taking priority. These constraints apply **only to large movement**: they do not restrict small movement, ordinary clicks, or exact final clicks.

The planner routes around rectangle obstacles, certifies whole cubic curves with recursive convex-hull bounds, and checks every emitted line segment against exact rectangle boundaries. Narrow barriers and gaps cannot be skipped between samples. It uses bounded attempts and computation time. If the current or return position conflicts with the regions, or no certifiable route is found, it skips the large excursion and displays the reason. It never substitutes an unrestricted path. Difficult or extremely narrow routes may be conservatively skipped. Manual motion never pauses or retargets the session: if it creates an unsafe large-movement segment, that excursion is skipped.

Regions use display UUID identity and display-local, top-left **logical screen points**. Retina pixels are not used as region coordinates. Rearranging a display translates its local boxes; a changed logical display size requires editing/correcting the boxes and saving again. A different display cannot silently inherit another display's boxes.

Existing per-event display and protected-target checks remain. Protected-path failures pause as before. Movement may extend a cycle; no catch-up queue or second loop exists. Pause, Stop, emergency stop and timer expiry cancel movement.

## Large-movement speed and travel clicks

**Movement speed** under Large movements ranges from **1× to 10×** and is separate from frequency. The frequency remains a probability per action cycle. Speed scales the timing between the existing eased, length-dependent path samples on both outward and return travel. **1× preserves the previous timing**. All spatial samples and segment checks remain; faster settings never drop corners or relax region constraints. Actual wall-clock speed also depends on macOS event processing and brief click holds. Small movement and the exact final-click action do not use this speed setting.

The two **Click while moving** switches permit regular clicks along that movement's outward and return paths. To use the requested combination, turn on the large switch and leave the small switch off. Both migrate to **off**, and speed migrates to **1×**; disabled movements retain these values. The main **Regular auto-clicking** switch must also be on. Travel clicks use its left/right selection and fixed/random intervals.

Movement and click deadlines share one cancellable scheduler. When a travel click is due, the engine checks the actual cursor position, completes one down/up pair at exactly that point while holding animation, then continues the curve. Large travel clicks must satisfy the saved regions and protected-target checks. A displaced cursor safely rejoins a checked sample before clicking; an unsafe large excursion is skipped. Manual movement never changes the saved targets.

Travel clicks do not trigger extra movement decisions or break draws. Turnarounds and arrival do not add a click or reset the interval. After returning, the same cadence continues at the cycle's original target/variation coordinate. Disabled travel phases suppress clicking without storing a backlog; after return, at most one overdue click is delivered, with a fresh interval from its actual down. With both switches off, the previous return-and-click timing remains unchanged.

Pause, Stop, emergency stop, permission loss and timer expiry cancel the same pending continuation and release a held button. The timer's final action remains separate, exact, and at most once.

## Timer and final click

The timer uses a monotonic clock and begins when the session successfully starts, after any Set target countdown. Manual Pause freezes it. Automatic breaks and movement count toward it. Changing the configured duration uses the new full duration on the next Start; other changes preserve paused remaining time. Stop resets the next session.

At natural expiry, the controller cancels regular work, releases any held button and, if enabled, sends exactly one down/up pair at the saved final coordinate. That coordinate is never varied. The session then stops, with no later mouse actions. Expiry interrupts long intervals, breaks and movement before a new regular click can begin.

Final click is unavailable while the timer is off, but its switch and configuration are retained. If enabled with the timer, a valid final target is required before starting. If the target becomes invalid, the session stops with an explanation. Pause, Stop, emergency stop, interruption, error or exit never triggers the final click. Uncertain final delivery is reported and is never automatically retried. An already delivered click cannot be undone.

Sleep, screen lock, permission loss or a monitor interruption pauses the session and requires an explicit restart. A substantially delayed expiry callback skips the final action rather than firing late on wake.

## Verification and limits

`./Scripts/build-app.sh` builds both apps. Run `./Scripts/verify.sh` after building to check the logic, source audit, and app signature. The September 30, 2026 verification recorded **111 logic checks** and **110/110 external checks**, including recorded travel clicks, same-path speed comparison, cadence, curvature, segment compliance and direct varied returns in addition to the existing shortcut/timer checks. See `VERIFICATION.md` for the historical results and unverified behavior; generated evidence files are kept locally and are not tracked in this repository.

The separate **Click Test Pad.app** receives actual macOS events in a different process. Keep it beside Screen Scout. After granting permissions, quit Screen Scout and run:

```sh
./Scripts/verify-external.sh
```

The test runner keeps temporary logs outside Documents and copies the finished evidence into this workspace. The opt-in test covers the display with the harmless pad, tests both chords, ordinary and varied clicks, movement-only sessions, timers and exact final clicks, then restores settings and leaves the app stopped. Leave the pad focused until it closes. A temporary test guard refuses input elsewhere; ordinary clicking is not restricted to this pad. Keyboard events and manual-style mouse movement in the automated test are generated, so they do not establish physical keyboard rollover or hardware behavior.

OS event acknowledgement does not prove that every destination app accepts synthetic input. Minecraft captured-cursor/fullscreen behavior and physical hardware still require hands-on checks. Cursor movement may affect the game's camera; movement can be turned off. No detection avoidance or security bypass is included.
