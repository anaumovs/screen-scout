import AppKit
import ApplicationServices
import CoreGraphics

public enum MouseFailure: LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
}

public struct WindowDescriptor {
    public let pid: pid_t
    public let layer: Int
    public let bounds: CGRect
    public let alpha: Double
    public init(pid: pid_t, layer: Int, bounds: CGRect, alpha: Double = 1) {
        self.pid = pid; self.layer = layer; self.bounds = bounds; self.alpha = alpha
    }
}

@MainActor public final class SystemMouse: MouseOutput {
    public static let marker: Int64 = 0x5343000000000000
    public var monitoringAvailable = false
    public var exclusiveOwner = false
    public var onDelivery: (() -> Void)?
    // Set only by the explicitly invoked external test. Production clicking has no app filter.
    public var verificationProcess: pid_t?
    private let source = CGEventSource(stateID: .privateState)
    private var held: (ClickButton, CGPoint)?
    private var serial: Int64 = 0
    private var awaiting: [Int64: TimeInterval] = [:]
    public init() { source?.localEventsSuppressionInterval = 0 }
    public var available: Bool { exclusiveOwner && monitoringAvailable && source != nil && AXIsProcessTrusted() && CGPreflightPostEventAccess() && (verificationProcess == nil || NSWorkspace.shared.frontmostApplication?.processIdentifier == verificationProcess) }
    public var failureReason: String {
        if !exclusiveOwner { return "Another Screen Scout instance owns the clicker. Close it first." }
        if let verificationProcess, NSWorkspace.shared.frontmostApplication?.processIdentifier != verificationProcess { return "External verification stopped because the test pad lost focus." }
        if !AXIsProcessTrusted() || !CGPreflightPostEventAccess() { return "Accessibility permission is missing. Enable Screen Scout in System Settings → Privacy & Security → Accessibility." }
        if !monitoringAvailable { return "The global shortcut/event monitor is unavailable. Enable Input Monitoring, then restart Screen Scout if requested." }
        return "macOS could not create a mouse event source. Restart Screen Scout."
    }
    public func currentPosition() -> CGPoint? { CGEvent(source: nil)?.location }
    public func movementDisplay(for id: UInt32) -> MovementDisplay? {
        let actual = id == 0 ? CGMainDisplayID() : id
        guard let bounds = displayBounds(for: actual), let uuid = CGDisplayCreateUUIDFromDisplayID(actual)?.takeRetainedValue() else { return nil }
        return MovementDisplay(identity: CFUUIDCreateString(nil, uuid) as String, bounds: bounds)
    }
    public func displayBounds(for id: UInt32) -> CGRect? {
        let display = id == 0 ? CGMainDisplayID() : id
        return CGDisplayIsActive(display) != 0 ? CGDisplayBounds(display) : nil
    }
    public func displayBounds(containing point: CGPoint) -> CGRect? {
        NSScreen.screens.compactMap { screen -> CGRect? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            let bounds = CGDisplayBounds(id)
            return bounds.contains(point) ? bounds : nil
        }.first
    }
    public func allows(_ point: CGPoint) -> Bool {
        guard point.x.isFinite && point.y.isFinite else { return false }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success,
              displays.contains(where: { CGDisplayBounds($0).contains(point) }) else { return false }
        // Metadata only: no images, capture permission, OCR, or calibration.
        // Check the topmost window here, so an app behind Minecraft is not excluded.
        let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = records.compactMap { record -> WindowDescriptor? in
            guard let dictionary = record[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  let pid = record[kCGWindowOwnerPID as String] as? Int32 else { return nil }
            return WindowDescriptor(pid: pid, layer: record[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds, alpha: record[kCGWindowAlpha as String] as? Double ?? 1)
        }
        return Self.windowAllows(point, windows: windows, ownPID: ProcessInfo.processInfo.processIdentifier, testPID: verificationProcess)
    }
    public static func windowAllows(_ point: CGPoint, windows: [WindowDescriptor], ownPID: pid_t, testPID: pid_t? = nil) -> Bool {
        for window in windows {
            // macOS includes non-interactive full-display WindowManager overlays.
            // They must not hide the actual application window in this self-control guard.
            guard (window.layer == 0 || window.pid == ownPID), window.alpha > 0.01, window.bounds.contains(point) else { continue }
            if let testPID { return window.pid == testPID }
            return window.pid != ownPID
        }
        return testPID == nil
    }
    public func move(to point: CGPoint) throws {
        try check(point)
        let previous = currentPosition() ?? point
        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else { throw MouseFailure.unavailable("macOS could not create a cursor event.") }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - previous.x).rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - previous.y).rounded()))
        tag(event); event.post(tap: .cghidEventTap)
    }
    public func down(_ button: ClickButton, at point: CGPoint) throws {
        try check(point)
        try buttonEvent(button, at: point, down: true)
        held = (button, point)
    }
    public func up(_ button: ClickButton, at point: CGPoint) throws {
        // An up must still be attempted if a window moves over the target after down.
        guard available else { release(); throw MouseFailure.unavailable(failureReason) }
        try buttonEvent(button, at: point, down: false)
        held = nil
    }
    public func release() {
        awaiting.removeAll()
        if let (button, point) = held {
            try? buttonEvent(button, at: point, down: false, requireAcknowledgement: false)
        }
        held = nil
    }
    public func acknowledge(_ event: CGEvent, type: CGEventType) {
        let tag = event.getIntegerValueField(.eventSourceUserData)
        guard awaiting.removeValue(forKey: tag) != nil else { return }
        if type == .leftMouseUp || type == .rightMouseUp { onDelivery?() }
    }
    public var deliveryTimedOut: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return awaiting.values.contains { now - $0 > 0.8 }
    }
    private func check(_ point: CGPoint) throws {
        guard available else { throw MouseFailure.unavailable(failureReason) }
        guard allows(point) else { throw MouseFailure.unavailable("The target is off-display or over Screen Scout. Reposition and restart.") }
    }
    private func tag(_ event: CGEvent) {
        serial = (serial + 1) & 0x0000FFFFFFFFFFFF
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker | serial)
        event.flags = []
    }
    private func buttonEvent(_ button: ClickButton, at point: CGPoint, down: Bool, requireAcknowledgement: Bool = true) throws {
        let kind: CGEventType = button == .left ? (down ? .leftMouseDown : .leftMouseUp) : (down ? .rightMouseDown : .rightMouseUp)
        guard let event = CGEvent(mouseEventSource: source, mouseType: kind, mouseCursorPosition: point, mouseButton: button == .left ? .left : .right) else { throw MouseFailure.unavailable("macOS could not create a click event.") }
        tag(event); event.setIntegerValueField(.mouseEventClickState, value: 1)
        if requireAcknowledgement { awaiting[event.getIntegerValueField(.eventSourceUserData)] = ProcessInfo.processInfo.systemUptime }
        event.post(tap: .cghidEventTap)
    }
}
