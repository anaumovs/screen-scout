import SwiftUI
import ScoutClicker
import Carbon

private let accent = Color(red: 0.32, green: 0.87, blue: 0.76)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var advanced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "cursorarrow.click.2").font(.system(size: 26)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Screen Scout").font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Desktop auto-clicker").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("F + G + H").font(.system(size: 12, weight: .semibold, design: .monospaced)).padding(9).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("Position your mouse over the target, then press F + G + H. Press it again to pause.")
                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Circle().fill(model.status == .running ? accent : (model.status == .takingBreak ? .orange : .gray)).frame(width: 9, height: 9)
                    Text(model.targetCountdown.map { "Set target in \($0)…" } ?? model.status.rawValue).font(.headline).accessibilityIdentifier("status")
                    Spacer()
                }
                Text(model.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let note = model.movementNote { Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                Divider()
                HStack {
                    Text("Saved target").foregroundStyle(.secondary)
                    Spacer()
                    if let target = model.target { Text("x \(Int(target.x))   y \(Int(target.y))").monospacedDigit() }
                    else { Text("Not set").foregroundStyle(.secondary) }
                    Button("Set target…") { model.setTargetCountdown() }.disabled(!model.ready)
                }.font(.caption)
                if model.finalTarget != nil || model.settings.finalClickEnabled {
                    HStack {
                        Text("Final target (screen points)").foregroundStyle(.secondary)
                        Spacer()
                        if let p = model.finalTarget { Text(String(format: "x %.2f   y %.2f", p.x, p.y)).monospacedDigit() }
                        else { Text("Set with I + O + P").foregroundStyle(.orange) }
                    }.font(.caption)
                }
                if model.settings.timerEnabled {
                    HStack {
                        Text("Time remaining").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(model.countdown).font(.system(size: 24, weight: .semibold, design: .monospaced)).accessibilityIdentifier("countdown")
                    }
                }
            }.padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            Toggle("Regular auto-clicking", isOn: $model.settings.regularClickingEnabled)
            HStack {
                Picker("Mouse button", selection: $model.settings.button) { ForEach(ClickButton.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).disabled(!model.settings.regularClickingEnabled)
                Spacer(minLength: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Interval (seconds)").font(.caption).foregroundStyle(.secondary)
                    TextField("Interval", value: Binding(get: { model.baseInterval }, set: { model.setBaseInterval($0) }), format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                }
            }
            HStack {
                Toggle("Session timer", isOn: $model.settings.timerEnabled)
                Spacer()
                duration("Hours", $model.settings.timerHours)
                duration("Minutes", $model.settings.timerMinutes)
                duration("Seconds", $model.settings.timerSeconds)
            }
            if !model.ready {
                VStack(alignment: .leading, spacing: 9) {
                    Label(model.permissionReason, systemImage: "lock.shield").font(.caption).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Request permissions…") { model.requestPermissions() }
                        Button("Accessibility") { model.openPrivacy("Accessibility") }
                        Button("Input Monitoring") { model.openPrivacy("ListenEvent") }
                    }.font(.caption)
                    Text("Enable Screen Scout in both panes. Relaunch if macOS asks. No screen-recording permission is used.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                Button { model.startButton() } label: { Label(model.active ? "Pause" : "Start", systemImage: model.active ? "pause.fill" : "play.fill").frame(minWidth: 85) }
                    .buttonStyle(.borderedProminent).disabled(!model.ready && !model.active)
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill").frame(minWidth: 65) }.keyboardShortcut(".", modifiers: .command)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("Emergency stop: \(model.emergencyLabel)").font(.caption)
                    Text(model.settings.secondaryClickEnabled ? "Moving your mouse pauses a secondary visit." : "Moving your mouse does not pause.").font(.caption2).foregroundStyle(.secondary)
                }
            }.controlSize(.large)
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Randomized click intervals", isOn: $model.settings.randomIntervalsEnabled)
                        HStack { number("Minimum interval", $model.settings.minInterval); number("Maximum interval", $model.settings.maxInterval) }.disabled(!model.settings.randomIntervalsEnabled)
                        Text("When off, the basic interval is fixed. These intervals also pace movement-only cycles. Movement can lengthen a cycle; missed actions never accumulate.").font(.caption2).foregroundStyle(.secondary)
                        Divider()
                        Toggle("Small movements", isOn: $model.settings.smallMovementEnabled)
                        VStack(alignment: .leading, spacing: 10) {
                            probability("Small frequency", $model.settings.movementProbability)
                            number("Maximum distance (screen points)", $model.settings.movementRadius)
                            Toggle("Click while moving", isOn: $model.settings.smallClickWhileMoving)
                            Text("Permits regular clicks along the small outward and return paths. Requires Regular auto-clicking.").font(.caption2).foregroundStyle(.secondary)
                        }.disabled(!model.settings.smallMovementEnabled)
                        Toggle("Large movements", isOn: $model.settings.largeMovementEnabled)
                        probability("Large frequency", $model.settings.largeMovementProbability).disabled(!model.settings.largeMovementEnabled)
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Movement speed").font(.caption).frame(width: 140, alignment: .leading)
                                Slider(value: $model.settings.largeMovementSpeed, in: 1...10, step: 0.5)
                                Text(String(format: "%g×", model.settings.largeMovementSpeed)).font(.caption.monospacedDigit()).frame(width: 40)
                            }
                            Text("1× is the existing travel speed. Higher values shorten travel time; frequency still controls the chance per cycle. Small movement and final clicks are unchanged.").font(.caption2).foregroundStyle(.secondary)
                            Toggle("Click while moving", isOn: $model.settings.largeClickWhileMoving)
                            Text("Permits regular clicks along the allowed large-movement path. Uses your regular button and click intervals. Requires Regular auto-clicking.").font(.caption2).foregroundStyle(.secondary)
                        }.disabled(!model.settings.largeMovementEnabled)
                        Picker("Active display", selection: Binding(get: { model.settings.movementDisplayID }, set: { model.selectMovementDisplay($0) })) {
                            Text("Main display").tag(UInt32(0))
                            ForEach(model.displays) { Text($0.name).tag($0.id) }
                            if model.settings.movementDisplayID != 0 && !model.displays.contains(where: { $0.id == model.settings.movementDisplayID }) {
                                Text("Unavailable display — choose another").tag(model.settings.movementDisplayID)
                            }
                        }
                        Button("Edit movement / click areas…") { model.editMovementRegions() }.disabled(model.regionEditing)
                        Text("Each frequency is an independent chance per cycle. Both can run in sequence. Travel clicks are off unless enabled separately above. Curved returns end at the cycle’s click position; movement-only sessions can return to their starting point without a saved target.").font(.caption2).foregroundStyle(.secondary)
                        Text("Green areas limit large movement. Red blocked areas also apply to secondary-area visits. Small movement, regular clicks and exact final clicks are unaffected.").font(.caption2).foregroundStyle(.secondary)
                        Divider()
                        secondaryClickOptions
                        Divider()
                        Toggle("Slight click-position variation", isOn: $model.settings.clickVariationEnabled)
                        number("Variation radius (screen points, 0–10)", $model.settings.clickVariationRadius).disabled(!model.settings.clickVariationEnabled)
                        Text("Fresh offset around the original regular target, never cumulative. Off or zero means exact target clicks. Final clicks are always exact.").font(.caption2).foregroundStyle(.secondary)
                        Divider()
                        Toggle("Automatic breaks", isOn: $model.settings.breaksEnabled)
                        probability("Break frequency", $model.settings.breakProbability).disabled(!model.settings.breaksEnabled)
                        HStack { number("Minimum break (seconds)", $model.settings.minBreak); number("Maximum break (seconds)", $model.settings.maxBreak) }.disabled(!model.settings.breaksEnabled)
                        Text("Timer time includes breaks and movement. Pause freezes it; Stop resets it for a fresh start. Changing timer duration resets it on the next start.").font(.caption2).foregroundStyle(.secondary)
                        Divider()
                        Toggle("Final click at timer completion", isOn: $model.settings.finalClickEnabled).disabled(!model.settings.timerEnabled)
                        if !model.settings.timerEnabled { Text("Enable Session timer to use the final click. Its saved settings are retained while disabled.").font(.caption2).foregroundStyle(.secondary) }
                        Picker("Final click button", selection: $model.settings.finalButton) { ForEach(ClickButton.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.disabled(!model.settings.finalClickEffective)
                        Text(model.finalTargetNote).font(.caption2).foregroundStyle(.secondary)
                        Text("I + O + P saves only the exact final coordinate, without clicking or starting. Capturing during a run pauses it. Final click works with regular clicking off and fires only on natural timer completion.").font(.caption2).foregroundStyle(.secondary)
                        Divider()
                        HStack {
                            Picker("Emergency key", selection: $model.settings.emergencyCode) { Text("F8").tag(UInt32(100)); Text("F9").tag(UInt32(101)); Text("F10").tag(UInt32(109)); Text("Escape").tag(UInt32(53)) }
                            Picker("Modifier", selection: $model.settings.emergencyModifiers) { Text("None").tag(UInt32(0)); Text("Control + Option").tag(UInt32(controlKey | optionKey)) }
                        }
                        Text("F + G + H controls the session; I + O + P captures the final target. Release all three keys of each chord before using it again. Both pass through to the focused app. Some keyboards need Fn with the emergency function key.").font(.caption2).foregroundStyle(.secondary)
                        Text(model.conflictNote).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack { Button("Check Minecraft options…") { model.chooseMinecraftOptions() }; Button("Open click test pad") { model.openTestPad() } }
                        if let error = model.settings.validationError { Text(error).font(.caption).foregroundStyle(.orange) }
                    }.padding(.top, 10).padding(.trailing, 4)
                }.frame(height: 210)
            }.font(.callout)
        }.padding(22).frame(width: 540)
            .background(Color(red: 0.075, green: 0.095, blue: 0.12)).tint(accent)
            .onChange(of: model.settings) { _, _ in model.settingsChanged() }
            .alert("Screen Scout", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }
    private var secondaryClickOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Secondary-area clicking", isOn: $model.settings.secondaryClickEnabled)
            HStack {
                number("Minimum wait (seconds)", $model.settings.secondaryMinInterval)
                number("Maximum wait (seconds)", $model.settings.secondaryMaxInterval)
            }.disabled(!model.settings.secondaryClickEnabled)
            HStack {
                Label("Purple click area", systemImage: "square.fill").foregroundStyle(.purple)
                Spacer()
                Button("Choose purple area…") { model.editMovementRegions(secondary: true) }.disabled(model.regionEditing)
            }
            Text("Draw one purple area on the active display. After each random wait, move there in a curve, click once with the selected mouse button, then curve back to the regular target or starting point. Waits restart after returning; a visit waits for current movement or a break to finish.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(title, value: value, format: .number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder) }.frame(maxWidth: .infinity)
    }
    private func duration(_ title: String, _ value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 60)
        }.disabled(!model.settings.timerEnabled)
    }
    private func probability(_ title: String, _ value: Binding<Double>) -> some View {
        HStack { Text(title).font(.caption).frame(width: 140, alignment: .leading); Slider(value: value, in: 0...1, step: 0.01); Text("\(Int(value.wrappedValue * 100))%").font(.caption.monospacedDigit()).frame(width: 40) }
    }
}
