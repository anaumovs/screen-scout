import AppKit
import Carbon
import ScoutClicker

@MainActor final class InputMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var latch = ChordLatch()
    private var finalLatch = ChordLatch(keys: [34, 31, 35])
    private(set) var layoutMapped = false
    var onToggle: (() -> Void)?
    var onCaptureFinal: (() -> Void)?
    var onEmergencyStop: (() -> Void)?
    var emergencyCode: UInt16 = 100
    var emergencyFlags: CGEventFlags = []
    var onFailure: ((String) -> Void)?
    var onMouseEvent: ((CGEvent, CGEventType) -> Void)?
    var isListening: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        guard !isListening else { return true }
        stop()
        guard let keys = Self.letterKeyCodes(), let finalKeys = Self.letterKeyCodes("iop") else { layoutMapped = false; return false }
        layoutMapped = true; latch = ChordLatch(keys: keys); finalLatch = ChordLatch(keys: finalKeys)
        latch.requireRelease(currentlyDown: Set(keys.filter { CGEventSource.keyState(.combinedSessionState, key: $0) }))
        finalLatch.requireRelease(currentlyDown: Set(finalKeys.filter { CGEventSource.keyState(.combinedSessionState, key: $0) }))
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            MainActor.assumeIsolated {
                let owner = Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
                owner.receive(type, event)
            }
            // Listen-only tap: never consume, rewrite, or suppress F/G/H or normal typing.
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let runLoopSource { CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        return isListening
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil; runLoopSource = nil
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onFailure?("The global input monitor was interrupted. Clicking paused; release F, G, H and restart explicitly.")
            latch.requireRelease(currentlyDown: Set(latch.keys.filter { CGEventSource.keyState(.combinedSessionState, key: $0) }))
            finalLatch.requireRelease(currentlyDown: Set(finalLatch.keys.filter { CGEventSource.keyState(.combinedSessionState, key: $0) }))
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type == .keyDown || type == .keyUp {
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // Handle the emergency key synchronously in the observed input stream too.
            // Carbon registration alone does not receive every posted/global key event.
            let shortcutFlags = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            if type == .keyDown && code == emergencyCode && shortcutFlags == emergencyFlags {
                latch.requireRelease(currentlyDown: latch.pressed)
                finalLatch.requireRelease(currentlyDown: finalLatch.pressed)
                onEmergencyStop?()
                return
            }
            let modified = !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
            if modified && type == .keyDown {
                latch.requireRelease(currentlyDown: latch.pressed.union([code]))
                finalLatch.requireRelease(currentlyDown: finalLatch.pressed.union([code])); return
            }
            if latch.update(code: code, down: type == .keyDown, repeated: repeated) { onToggle?() }
            if finalLatch.update(code: code, down: type == .keyDown, repeated: repeated) { onCaptureFinal?() }
        } else { onMouseEvent?(event, type) }
    }
    static func letterKeyCodes(_ letters: String = "fgh") -> Set<UInt16>? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
        var result: Set<UInt16> = []
        for code in UInt16(0)..<128 {
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let error = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            if error == noErr && length == 1 && letters.utf16.contains(chars[0]) { result.insert(code) }
        }
        return result.count == letters.count ? result : nil
    }
}
