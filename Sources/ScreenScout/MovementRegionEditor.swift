import AppKit
import SwiftUI
import ScoutClicker

@MainActor final class RegionDraft: ObservableObject {
    enum Tool: String, CaseIterable { case select = "Move / resize", allowed = "Draw allowed", blocked = "Draw blocked", secondary = "Draw secondary" }
    @Published var boxes: [MovementBox]
    @Published var selected: UUID?
    @Published var tool: Tool = .allowed
    let display: MovementDisplay
    let sizeChanged: Bool
    var finish: (([MovementBox]?) -> Void)?
    var redraw: (() -> Void)?
    init(display: MovementDisplay, profile: MovementRegionProfile?, initialTool: Tool = .allowed) {
        self.display=display;boxes=profile?.boxes ?? [];tool=initialTool;sizeChanged=profile.map { $0.referenceSize != display.bounds.size } ?? false
    }
    var valid: Bool {
        let profile = MovementRegionProfile(displayIdentity: display.identity, referenceSize: display.bounds.size, boxes: boxes)
        return profile.domain(for: display) != nil && (!boxes.contains(where: { $0.secondaryClick }) || profile.secondaryDomain(for: display) != nil)
    }
    func delete() { boxes.removeAll { $0.id == selected };selected=nil;redraw?() }
}
private struct RegionToolbar: View {
    @ObservedObject var draft: RegionDraft
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Movement / click areas").font(.headline)
            HStack { Label("Allowed", systemImage: "square.fill").foregroundStyle(.green); Label("Blocked (takes priority)", systemImage: "square.fill").foregroundStyle(.red); Label("Secondary click", systemImage: "square.fill").foregroundStyle(.purple) }.font(.caption)
            Picker("Tool", selection: $draft.tool) { ForEach(RegionDraft.Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Text("Drag to draw. In Move / resize, drag a box or one of its corner handles. No green boxes means large movement can use the whole display minus red boxes. Draw one purple secondary click area; drawing another replaces it. Maximum 32 boxes.").font(.caption).fixedSize(horizontal: false, vertical: true)
            if draft.sizeChanged || !draft.valid { Text("Display size changed or boxes need correction. Move/resize or clear invalid boxes before saving.").foregroundStyle(.orange).font(.caption) }
            HStack {
                Button("Delete selected") { draft.delete() }.disabled(draft.selected == nil)
                Button("Clear") { draft.boxes=[];draft.selected=nil;draft.redraw?() }
                Text("\(draft.boxes.count) / 32").font(.caption)
                Spacer()
                Button("Cancel") { draft.finish?(nil) }
                Button("Save") { draft.finish?(draft.boxes) }.buttonStyle(.borderedProminent).disabled(!draft.valid)
            }
            Text("Automation is paused. Save or Cancel, then resume explicitly. Regular clicks, small movement and exact final clicks are unaffected by these boxes.").font(.caption2).foregroundStyle(.secondary)
        }.padding(14).frame(width: 640).background(.regularMaterial).cornerRadius(12)
    }
}
private final class RegionWindow: NSWindow { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { true } }
@MainActor final class MovementRegionEditor {
    private let window: NSWindow
    private let draft: RegionDraft
    init(screen: NSScreen, display: MovementDisplay, profile: MovementRegionProfile?, initialTool: RegionDraft.Tool = .allowed, completion: @escaping ([MovementBox]?) -> Void) {
        draft=RegionDraft(display:display,profile:profile,initialTool:initialTool)
        window=RegionWindow(contentRect:screen.frame, styleMask:[.borderless], backing:.buffered, defer:false)
        window.isReleasedWhenClosed=false;window.level = .floating;window.isOpaque=false;window.backgroundColor = .clear
        let canvas=RegionCanvas(frame:CGRect(origin:.zero,size:screen.frame.size),draft:draft)
        window.contentView=canvas
        let toolbar=NSHostingView(rootView:RegionToolbar(draft:draft).preferredColorScheme(.dark))
        toolbar.frame=CGRect(x:16,y:16,width:668,height:292);canvas.addSubview(toolbar)
        draft.redraw = { [weak canvas] in canvas?.needsDisplay=true }
        draft.finish = { [weak self] boxes in self?.window.close();completion(boxes) }
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func cancel() { draft.finish?(nil) }
}
@MainActor private final class RegionCanvas: NSView {
    let draft: RegionDraft
    private var origin: CGPoint?
    private var original: CGRect?
    private var corner: Int?
    private var replacedSecondary: MovementBox?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(frame: CGRect, draft: RegionDraft) { self.draft=draft;super.init(frame:frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func local(_ event: NSEvent) -> CGPoint {
        let p=convert(event.locationInWindow,from:nil),size=draft.display.bounds.size
        return CGPoint(x:max(0,min(size.width,p.x*size.width/bounds.width)),y:max(0,min(size.height,p.y*size.height/bounds.height)))
    }
    private func viewRect(_ rect: CGRect) -> CGRect {
        let size=draft.display.bounds.size
        return CGRect(x:rect.minX*bounds.width/size.width,y:rect.minY*bounds.height/size.height,width:rect.width*bounds.width/size.width,height:rect.height*bounds.height/size.height)
    }
    private func corners(_ r: CGRect) -> [CGPoint] { [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)] }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.24).setFill();bounds.fill()
        for box in draft.boxes {
            let r=viewRect(box.rect),color: NSColor = box.secondaryClick ? .systemPurple : (box.blocked ? .systemRed : .systemGreen)
            color.withAlphaComponent(0.18).setFill();r.fill();color.setStroke()
            let path=NSBezierPath(rect:r);path.lineWidth=box.id == draft.selected ? 3 : 2;path.stroke()
            let label=box.secondaryClick ? "SECONDARY CLICK" : (box.blocked ? "BLOCKED" : "ALLOWED")
            (label as NSString).draw(at:CGPoint(x:r.minX+5,y:r.minY+5),withAttributes:[.font:NSFont.boldSystemFont(ofSize:12),.foregroundColor:color])
            if box.id == draft.selected {
                for p in corners(r) { NSColor.white.setFill();CGRect(x:p.x-5,y:p.y-5,width:10,height:10).fill() }
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let p=local(event);origin=p;corner=nil;original=nil
        if draft.tool != .select {
            let secondary = draft.tool == .secondary
            replacedSecondary = secondary ? draft.boxes.first(where: { $0.secondaryClick }) : nil
            guard draft.boxes.count < 32 || replacedSecondary != nil else { origin=nil;return }
            if secondary { draft.boxes.removeAll { $0.secondaryClick } }
            let box=MovementBox(rect:CGRect(origin:p,size:.zero),blocked:draft.tool == .blocked,secondaryClick:secondary)
            draft.boxes.append(box);draft.selected=box.id
        } else {
            if let selected=draft.boxes.first(where: { $0.id == draft.selected }), let k=corners(selected.rect).firstIndex(where: { movementDistance($0,p)<10 }) {
                corner=k;original=selected.rect
            } else if let box=draft.boxes.reversed().first(where: { $0.rect.contains(p) }) { draft.selected=box.id;original=box.rect }
            else { draft.selected=nil;origin=nil }
        }
        needsDisplay=true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin, let i=draft.boxes.firstIndex(where: { $0.id == draft.selected }) else { return }
        let p=local(event),size=draft.display.bounds.size
        if let original {
            if let corner {
                let opposite=corners(original)[(corner+2)%4]
                draft.boxes[i].rect=CGRect(x:min(p.x,opposite.x),y:min(p.y,opposite.y),width:abs(p.x-opposite.x),height:abs(p.y-opposite.y))
            } else {
                let x=max(0,min(size.width-original.width,original.minX+p.x-origin.x)),y=max(0,min(size.height-original.height,original.minY+p.y-origin.y))
                draft.boxes[i].rect=CGRect(x:x,y:y,width:original.width,height:original.height)
            }
        } else { draft.boxes[i].rect=CGRect(x:min(origin.x,p.x),y:min(origin.y,p.y),width:abs(origin.x-p.x),height:abs(origin.y-p.y)) }
        needsDisplay=true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with:event)
        draft.boxes.removeAll { $0.rect.width < 0.1 || $0.rect.height < 0.1 }
        if !draft.boxes.contains(where: { $0.id == draft.selected }) {
            if let previous = replacedSecondary { draft.boxes.append(previous); draft.selected=previous.id }
            else { draft.selected=nil }
        }
        replacedSecondary=nil
        origin=nil;original=nil;corner=nil;needsDisplay=true
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 51 || event.keyCode == 117 { draft.delete() } else { super.keyDown(with:event) } }
}
