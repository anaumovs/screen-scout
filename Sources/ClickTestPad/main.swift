import AppKit
import CoreGraphics

final class Pad: NSView {
    var events: [[String: Any]] = []
    var logURL: URL?
    var target = CGPoint.zero
    var left = 0, right = 0
    private var pendingSave: DispatchWorkItem?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); wantsLayer = true; layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.25, alpha: 1).cgColor }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved,.activeAlways,.inVisibleRect], owner:self,userInfo:nil))
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        func text(_ string: String, _ y: CGFloat, _ size: CGFloat) {
            let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:size,weight:.medium),.foregroundColor:NSColor.white]
            NSAttributedString(string:string,attributes:attrs).draw(at:NSPoint(x:28,y:y))
        }
        text("Click Test Pad",bounds.height-60,28)
        text("Harmless external window · no network or side effects",bounds.height-92,14)
        text("Left: \(left)      Right: \(right)",bounds.height-145,22)
        text("Click anywhere in this pad. F / G / H are not consumed.",35,13)
        let center = CGPoint(x:bounds.midX,y:bounds.midY)
        NSColor.systemTeal.setStroke(); let ring = NSBezierPath(ovalIn:NSRect(x:center.x-45,y:center.y-45,width:90,height:90));ring.lineWidth=2;ring.stroke()
    }
    func record(_ kind: String, event: NSEvent) {
        let p = event.cgEvent?.location ?? .zero
        var row: [String: Any] = ["type":kind,"time":ProcessInfo.processInfo.systemUptime,"eventTime":event.timestamp,"x":p.x,"y":p.y,"tag":event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0]
        if kind.hasPrefix("key") { row["code"] = event.keyCode; row["repeat"] = event.isARepeat }
        events.append(row); if events.count > 20000 { events.removeFirst(events.count-20000) }
        // Batch movement log writes so disk serialization does not throttle fast
        // playback. Button events flush immediately; a trailing flush retains the
        // last movement even when the engine stops before another event arrives.
        if kind == "move" {
            if pendingSave == nil {
                let work = DispatchWorkItem { [weak self] in self?.pendingSave = nil; self?.save(); self?.needsDisplay = true }
                pendingSave = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
            }
        } else { pendingSave?.cancel(); pendingSave = nil; save(); needsDisplay = true }
    }
    func save() {
        guard let logURL else { return }
        let record: [String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,"window":window?.windowNumber ?? 0,"targetX":target.x,"targetY":target.y,"left":left,"right":right,"events":events]
        if let data=try? JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:logURL,options:.atomic) }
    }
    override func mouseDown(with e:NSEvent) { left += 1;record("leftDown",event:e) }
    override func mouseUp(with e:NSEvent) { record("leftUp",event:e) }
    override func rightMouseDown(with e:NSEvent) { right += 1;record("rightDown",event:e) }
    override func rightMouseUp(with e:NSEvent) { record("rightUp",event:e) }
    override func mouseMoved(with e:NSEvent) { record("move",event:e) }
    override func mouseDragged(with e:NSEvent) { record("leftDrag",event:e) }
    override func rightMouseDragged(with e:NSEvent) { record("rightDrag",event:e) }
    override func keyDown(with e:NSEvent) { record("keyDown",event:e) }
    override func keyUp(with e:NSEvent) { record("keyUp",event:e) }
}
final class PadWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class Delegate: NSObject,NSApplicationDelegate {
    var window:NSWindow!
    func applicationDidFinishLaunching(_ n:Notification) {
        NSEvent.isMouseCoalescingEnabled = false
        let cover = CommandLine.arguments.contains("--cover-display")
        let rect = cover ? (NSScreen.screens.first?.frame ?? NSRect(x:100,y:150,width:720,height:480)) : NSRect(x:100,y:150,width:720,height:480)
        window=PadWindow(contentRect:rect,styleMask:cover ? [.borderless] : [.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Screen Scout — External Click Test Pad"
        let pad=Pad(frame:NSRect(origin:.zero,size:rect.size))
        if let i=CommandLine.arguments.firstIndex(of:"--log"),CommandLine.arguments.count>i+1 { pad.logURL=URL(fileURLWithPath:CommandLine.arguments[i+1]) }
        window.contentView=pad;window.acceptsMouseMovedEvents=true;window.makeKeyAndOrderFront(nil);window.makeFirstResponder(pad)
        NSApp.activate(ignoringOtherApps:true)
        let cocoa=window.convertPoint(toScreen:NSPoint(x:pad.bounds.midX,y:pad.bounds.midY))
        pad.target=CGPoint(x:cocoa.x,y:CGDisplayBounds(CGMainDisplayID()).height-cocoa.y);pad.save()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
}
let application=NSApplication.shared
let delegate=Delegate();application.delegate=delegate;application.setActivationPolicy(.regular);application.run()
