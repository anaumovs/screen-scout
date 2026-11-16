import AppKit
import SwiftUI
import Carbon
import ApplicationServices
import ScoutClicker

@MainActor final class AppModel: ObservableObject {
    @Published var settings: ClickSettings
    @Published var status = ClickStatus.stopped
    @Published var detail = "Position your mouse over the target, then press F + G + H. Press it again to pause."
    @Published var target: CGPoint?
    @Published var finalTarget: CGPoint?
    @Published var finalTargetNote = "Position the pointer and press I + O + P to save the exact final target."
    @Published var remainingDuration: TimeInterval?
    @Published var displays: [DisplayChoice] = []
    @Published var movementNote: String?
    @Published var regionEditing = false
    private var regionEditor: MovementRegionEditor?
    @Published var targetCountdown: Int?
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var shortcutReady = false
    @Published var emergencyReady = false
    @Published var errorMessage: String?
    @Published var conflictNote = "Minecraft controls have not been checked."
    @Published var confirmedClicks = 0
    let lease = InstanceLease()
    let mouse = SystemMouse()
    // The opt-in external verifier can replay identical random paths across speeds.
    // Ordinary launches always use the original system random distribution.
    var verificationRandom: ((ClosedRange<Double>) -> Double)?
    let monitor = InputMonitor()
    private(set) var engine: ClickEngine!
    private var hotkey = GlobalHotkey()
    private var timer: Timer?
    private var captureDeadline: TimeInterval?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var layoutObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?
    struct DisplayChoice: Identifiable { let id: UInt32; let name: String }
    var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var active: Bool { engine?.active == true || captureDeadline != nil }
    var ready: Bool { accessibility && inputMonitoring && shortcutReady && emergencyReady && lease.acquired && !IsSecureEventInputEnabled() }
    var emergencyLabel: String { (settings.emergencyModifiers == 0 ? "" : "⌃⌥ ") + ([UInt32(100): "F8", 101: "F9", 109: "F10", 53: "Esc"][settings.emergencyCode] ?? "F8") }
    var baseInterval: Double { settings.basicInterval }
    var countdown: String {
        let seconds = max(0, Int(ceil(remainingDuration ?? settings.timerDuration)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
    var permissionReason: String {
        if !lease.acquired { return "Another Screen Scout instance is open. Close it before starting this one." }
        if !accessibility { return "Enable Accessibility to send real mouse clicks." }
        if !inputMonitoring { return "Enable Input Monitoring so F + G + H works in other apps." }
        if IsSecureEventInputEnabled() { return "macOS Secure Input is active. Close the secure input field and restart explicitly." }
        if !monitor.layoutMapped { return "F/G/H or I/O/P could not be mapped on the active keyboard layout. No substitute shortcut is used." }
        if !shortcutReady { return "The global F + G + H listener is unavailable. Reopen Screen Scout after granting permission." }
        if !emergencyReady { return "The emergency shortcut is already in use. Choose another emergency key in Advanced." }
        return "Permissions ready."
    }
    init() {
        settings = ClickSettings.load(current: UserDefaults.standard.data(forKey: "ClickerSettingsV2"), legacy: UserDefaults.standard.data(forKey: "ScoutSettings"))
        mouse.exclusiveOwner = lease.acquired
        engine = ClickEngine(output: mouse, scheduler: MainScheduler(), random: { [weak self] range in
            if CommandLine.arguments.contains("--verify-external"), let replay = self?.verificationRandom { return replay(range) }
            return Double.random(in: range)
        })
        engine.changed = { [weak self] in self?.sync() }
        mouse.onDelivery = { [weak self] in self?.engine.confirmDelivery() }
        monitor.onToggle = { [weak self] in self?.toggleFromChord() }
        monitor.onCaptureFinal = { [weak self] in self?.captureFinalFromChord() }
        monitor.onEmergencyStop = { [weak self] in self?.stop() }
        monitor.onMouseEvent = { [weak self] event, type in self?.mouse.acknowledge(event, type: type) }
        monitor.onFailure = { [weak self] reason in self?.pause(reason) }
        hotkey.onStop = { [weak self] in self?.stop() }
        configureEmergency()
        refreshDisplays()
        if settings.movementDisplayIdentity == nil { settings.movementDisplayIdentity = mouse.movementDisplay(for: settings.movementDisplayID)?.identity }
        checkMinecraftOptions(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/minecraft/options.txt"))
        refreshPermissions()
        persist()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.regionEditor?.cancel(); self?.cancelCapture(); self?.engine.clearTargets(); self?.refreshDisplays()
                self?.detail = "Display configuration changed. Set targets again with F + G + H and I + O + P."
                self?.finalTargetNote = "Display configuration changed; final target cleared."
            }
        })
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.pause("Mac locked or went to sleep. Restart explicitly.") } })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause("Mac locked. Timer frozen; restart explicitly after unlocking.") }
        }
        layoutObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause("Keyboard layout changed. Release F, G, H, then restart."); self?.monitor.stop(); self?.refreshPermissions() }
        }
    }
    func sync() {
        status = engine.status; detail = engine.detail; target = engine.target; finalTarget = engine.finalTarget
        remainingDuration = engine.remainingDuration; confirmedClicks = engine.clicksPosted; movementNote = engine.movementNote
    }
    func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return DisplayChoice(id: id, name: screen.localizedName)
        }
    }
    func selectMovementDisplay(_ id: UInt32) {
        settings.movementDisplayID = id
        settings.movementDisplayIdentity = mouse.movementDisplay(for: id)?.identity
    }
    func editMovementRegions(secondary: Bool = false) {
        guard !regionEditing, let display = mouse.movementDisplay(for: settings.movementDisplayID),
              let screen = NSScreen.screens.first(where: { screen in
                  guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return false }
                  return mouse.movementDisplay(for: id)?.identity == display.identity
              }) else { errorMessage = "Select an available movement display first."; return }
        pause("Editing movement / click areas. Resume explicitly after Save or Cancel.")
        regionEditing = true
        let profile = settings.movementRegions.first { $0.displayIdentity == display.identity }
        regionEditor = MovementRegionEditor(screen: screen, display: display, profile: profile, initialTool: secondary ? .secondary : .allowed) { [weak self] boxes in
            guard let self else { return }
            if let boxes {
                self.settings.movementDisplayIdentity = display.identity
                self.settings.movementRegions.removeAll { $0.displayIdentity == display.identity }
                self.settings.movementRegions.append(MovementRegionProfile(displayIdentity: display.identity, referenceSize: display.bounds.size, boxes: boxes))
                self.persist()
            }
            self.regionEditing = false; self.regionEditor = nil
        }
    }
    func persist() { if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "ClickerSettingsV2") } }
    func settingsChanged() {
        if active { pause("Settings changed. Start again to use the new values.") }
        persist(); configureEmergency()
    }
    func setBaseInterval(_ value: Double) {
        guard value.isFinite else { return }
        let center = max(0.08, min(3600, value)), spread = min((settings.maxInterval - settings.minInterval) / 2, center - 0.08, 3600 - center)
        settings.minInterval = center - max(0, spread); settings.maxInterval = center + max(0, spread)
    }
    func configureEmergency() {
        monitor.emergencyCode = UInt16(settings.emergencyCode)
        monitor.emergencyFlags = settings.emergencyModifiers == 0 ? [] : [.maskControl, .maskAlternate]
        emergencyReady = lease.acquired && hotkey.register(code: settings.emergencyCode, modifiers: settings.emergencyModifiers)
    }
    func requestPermissions() {
        if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        refreshPermissions()
    }
    func openPrivacy(_ category: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + category) { NSWorkspace.shared.open(url) }
    }
    func refreshPermissions() {
        accessibility = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        inputMonitoring = CGPreflightListenEventAccess()
        if lease.acquired && accessibility && inputMonitoring && !monitor.isListening { _ = monitor.start() }
        shortcutReady = monitor.isListening
        mouse.monitoringAvailable = shortcutReady && emergencyReady && !IsSecureEventInputEnabled()
    }
    private func ensureReady() -> Bool {
        refreshPermissions()
        guard ready else { pause(permissionReason); errorMessage = permissionReason; return false }
        if let error = settings.validationError { pause(error); errorMessage = error; return false }
        return true
    }
    func toggleFromChord() {
        guard !regionEditing else { return }
        if active { pause(); return }
        guard ensureReady(), let point = mouse.currentPosition() else { return }
        cancelCapture()
        engine.start(at: point, settings: settings)
    }
    func startButton() {
        guard !regionEditing else { return }
        if active { pause(); return }
        guard ensureReady() else { return }
        if engine.target != nil || !settings.needsRegularTarget { engine.start(settings: settings) }
        else { setTargetCountdown() }
    }
    func captureFinalFromChord() {
        guard !regionEditing else { return }
        guard ready, let point = mouse.currentPosition() else { return }
        cancelCapture()
        if engine.captureFinalTarget(point) {
            finalTargetNote = String(format: "Final target saved: x %.2f, y %.2f screen points. No click sent.", point.x, point.y)
        } else { finalTargetNote = "Final target was not saved. Choose an active display outside Screen Scout." }
    }
    func setTargetCountdown() {
        guard !regionEditing else { return }
        guard ensureReady() else { return }
        engine.stop(); captureDeadline = clock + 5; targetCountdown = 5
        detail = "Set target: move the pointer outside Screen Scout. Capturing in 5 seconds."
    }
    func pause(_ reason: String = "Paused. Reposition, then press F + G + H to resume at the new position.") { cancelCapture(); engine.pause(reason) }
    func stop() { cancelCapture(); engine.stop() }
    private func cancelCapture() { captureDeadline = nil; targetCountdown = nil }
    private func tick() {
        refreshPermissions()
        remainingDuration = engine.remainingDuration
        if active && !ready { pause(permissionReason); return }
        if engine.active && mouse.deliveryTimedOut { pause("macOS did not confirm click delivery. Check permissions and the focused app, then restart explicitly."); return }
        engine.checkEnvironment()
        guard let deadline = captureDeadline else { return }
        let remaining = Int(ceil(deadline - clock))
        if remaining > 0 { targetCountdown = remaining; detail = "Set target: position your mouse. Capturing in \(remaining) seconds." }
        else {
            cancelCapture()
            guard let point = mouse.currentPosition(), mouse.allows(point) else { pause("Target was over Screen Scout or off-display. Use Set target again and move outside this window."); return }
            engine.start(at: point, settings: settings)
        }
    }
    func checkMinecraftOptions(at url: URL) {
        guard let text = try? String(contentsOf: url) else { conflictNote = "No standard Minecraft options.txt found. Check F / G / H bindings in the game, or choose its options file below."; return }
        let conflicts = text.split(separator: "\n").filter { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && parts[0].hasPrefix("key_") && ["key.keyboard.f", "key.keyboard.g", "key.keyboard.h"].contains(String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        conflictNote = conflicts.isEmpty ? "This options file has no F / G / H bindings. Mods or other profiles may still use them." : "Bindings found: " + conflicts.map(String.init).joined(separator: "; ") + ". Reassign conflicts inside Minecraft if needed."
    }
    func chooseMinecraftOptions() {
        let panel = NSOpenPanel(); panel.message = "Choose Minecraft's options.txt to check F/G/H bindings without changing them."
        guard panel.runModal() == .OK, let url = panel.url else { return }; checkMinecraftOptions(at: url)
    }
    func openTestPad() {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Click Test Pad.app")
        guard FileManager.default.fileExists(atPath: url.path) else { errorMessage = "Build the test pad with Scripts/build-app.sh first."; return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
