import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScoutCore

struct TargetWindow: Identifiable, Equatable {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let title: String
    let bounds: CGRect
    var label: String { "\(owner) — \(title.isEmpty ? "Window \(id)" : title)" }
}

struct Calibration {
    let window: TargetWindow
    let crop: UnitRect
    let display: CGDirectDisplayID
    let displayBounds: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    var region: CGRect {
        CGRect(x: window.bounds.minX + crop.x * window.bounds.width,
               y: window.bounds.minY + crop.y * window.bounds.height,
               width: crop.width * window.bounds.width, height: crop.height * window.bounds.height)
    }
}

enum CaptureFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

enum WindowCapture {
    static var permitted: Bool { CGPreflightScreenCaptureAccess() }
    static func requestPermission() { _ = CGRequestScreenCaptureAccess() }
    static func windows() -> [TargetWindow] {
        records().compactMap(parse).filter { $0.pid != ProcessInfo.processInfo.processIdentifier && $0.bounds.width > 200 && $0.bounds.height > 150 }
    }
    private static func records() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }
    private static func parse(_ record: [String: Any]) -> TargetWindow? {
        guard (record[kCGWindowLayer as String] as? Int) == 0,
              let id = record[kCGWindowNumber as String] as? UInt32,
              let pid = record[kCGWindowOwnerPID as String] as? Int32,
              let bounds = record[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return TargetWindow(id: id, pid: pid, owner: record[kCGWindowOwnerName as String] as? String ?? "App", title: record[kCGWindowName as String] as? String ?? "", bounds: rect)
    }
    static func preview(_ target: TargetWindow) async throws -> CGImage {
        guard permitted else { throw CaptureFailure.message("Screen Recording access is required. Grant it in System Settings, then relaunch Screen Scout if macOS requests it.") }
        return try await screenshot(target, crop: .full)
    }
    static func calibrate(_ target: TargetWindow, crop: UnitRect) throws -> Calibration {
        guard crop.isValid, let current = windows().first(where: { $0.id == target.id }) else { throw CaptureFailure.message("Select an available window and draw its game area.") }
        guard current.bounds == target.bounds else { throw CaptureFailure.message("The window changed since the snapshot. Take another snapshot and redraw the game area.") }
        let displays = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        guard let display = displays.first(where: { CGDisplayBounds($0).contains(current.bounds) }) else { throw CaptureFailure.message("Keep the entire target window on one display, then recalibrate.") }
        return Calibration(window: current, crop: crop, display: display, displayBounds: CGDisplayBounds(display), pixelWidth: CGDisplayPixelsWide(display), pixelHeight: CGDisplayPixelsHigh(display))
    }
    static func validate(_ calibration: Calibration, requireFocus: Bool) throws {
        guard permitted else { throw CaptureFailure.message("Screen Recording access was lost. Restore permission and restart explicitly.") }
        let info = records()
        guard let index = info.firstIndex(where: { ($0[kCGWindowNumber as String] as? UInt32) == calibration.window.id }), let current = parse(info[index]) else { throw CaptureFailure.message("The target window is closed, minimized, or unavailable. Recalibrate.") }
        guard current.pid == calibration.window.pid && current.bounds == calibration.window.bounds,
              CGDisplayIsActive(calibration.display) != 0,
              CGDisplayBounds(calibration.display) == calibration.displayBounds,
              CGDisplayPixelsWide(calibration.display) == calibration.pixelWidth,
              CGDisplayPixelsHigh(calibration.display) == calibration.pixelHeight else { throw CaptureFailure.message("Window geometry or display scaling changed. Recalibrate before restarting.") }
        if requireFocus && NSWorkspace.shared.frontmostApplication?.processIdentifier != current.pid {
            throw CaptureFailure.message("Target app lost focus. Start the preview again explicitly.")
        }
        if requireFocus, let frontWindow = info.compactMap(parse).first(where: { $0.pid == current.pid }), frontWindow.id != current.id {
            throw CaptureFailure.message("Another window in the selected app is in front. Focus the calibrated window and restart.")
        }
        for record in info.prefix(index) {
            guard let alpha = record[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                  let b = record[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            if bounds.intersects(calibration.region) { throw CaptureFailure.message("Another window obscures the selected area. Uncover it and restart the preview.") }
        }
    }
    static func capture(_ calibration: Calibration) async throws -> CGImage {
        try validate(calibration, requireFocus: true)
        let image = try await screenshot(calibration.window, crop: calibration.crop)
        try validate(calibration, requireFocus: true)
        guard image.width >= 64 && image.height >= 64 else { throw CaptureFailure.message("Capture failed or the game region is too small.") }
        return image
    }
    private static func screenshot(_ target: TargetWindow, crop: UnitRect) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == target.id && $0.owningApplication?.processID == target.pid }) else {
            throw CaptureFailure.message("The selected window is no longer available.")
        }
        guard window.frame == target.bounds else { throw CaptureFailure.message("The window moved or resized during capture. Recalibrate.") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true
        // Source rect is window-local, in logical points; output uses the capture scale.
        let source = CGRect(x: crop.x * target.bounds.width, y: crop.y * target.bounds.height, width: crop.width * target.bounds.width, height: crop.height * target.bounds.height)
        config.sourceRect = source
        config.width = max(1, Int(source.width * CGFloat(filter.pointPixelScale)))
        config.height = max(1, Int(source.height * CGFloat(filter.pointPixelScale)))
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
