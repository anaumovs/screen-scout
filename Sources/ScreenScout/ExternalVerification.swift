import AppKit
import ScoutClicker

/// Explicit opt-in integration test. Real input is confined to a separate harmless pad.
/// No synthetic keyboard events are used by the ordinary app.
@MainActor final class ExternalVerification {
    private static var started = false
    let model: AppModel
    let reportPath: String
    var checks: [[String: Any]] = []
    var trajectoryReports: [[String: Any]] = []
    var travelReports: [[String: Any]] = []
    var pad: NSRunningApplication?
    var logURL: URL!
    var target = CGPoint.zero
    var keyboard = CGEventSource(stateID: .privateState)
    var heldKeys: Set<CGKeyCode> = []
    init(model: AppModel, reportPath: String) { self.model = model; self.reportPath = reportPath }
    func begin() {
        guard !Self.started else { return }; Self.started = true
        Task { await run() }
    }
    private func sleep(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func check(_ name: String, _ pass: Bool, _ detail: String = "") { checks.append(["name":name,"passed":pass,"detail":detail]) }
    private func write(_ outcome: String, reason: String = "") {
        let report: [String: Any] = ["outcome":outcome,"reason":reason,"accessibility":model.accessibility,"inputMonitoring":model.inputMonitoring,"globalShortcut":model.shortcutReady,"emergency":model.emergencyReady,"checks":checks,"trajectories":trajectoryReports,"travelClicking":travelReports,"receiverLog":logURL?.path ?? "","physicalKeyboardTested":false,"minecraftTested":false,"appStatusAtEnd":model.status.rawValue]
        if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) { try? data.write(to:URL(fileURLWithPath:reportPath),options:.atomic) }
    }
    private func receiver() throws -> [String: Any] {
        let data = try Data(contentsOf:logURL)
        guard let record = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw MouseFailure.unavailable("Invalid test receiver log.") }; return record
    }
    private func count(_ key: String) -> Int { (try? receiver()[key] as? Int) ?? 0 }
    private func total() -> Int { count("left") + count("right") }
    private func events() -> [[String: Any]] { (try? receiver()["events"] as? [[String:Any]]) ?? [] }
    private func isMouseOutput(_ event: [String:Any]) -> Bool {
        (((event["tag"] as? Int64) ?? 0) & Int64(bitPattern: 0xFFFF000000000000)) == SystemMouse.marker
    }
    private func mouseOutputCount() -> Int { events().filter(isMouseOutput).count }
    private func distance(_ event: [String:Any], _ point: CGPoint) -> Double {
        hypot((event["x"] as? Double ?? -10000)-point.x,(event["y"] as? Double ?? -10000)-point.y)
    }
    private func focusGuard() throws {
        guard let pad, !pad.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == pad.processIdentifier else { throw MouseFailure.unavailable("Test pad lost focus. Verification stopped before sending more input.") }
    }
    private func key(_ code: CGKeyCode, down: Bool, repeatKey: Bool = false, flags: CGEventFlags = []) throws {
        try focusGuard()
        guard let event = CGEvent(keyboardEventSource:keyboard,virtualKey:code,keyDown:down) else { throw MouseFailure.unavailable("Could not construct test key event.") }
        event.flags = flags; event.setIntegerValueField(.keyboardEventAutorepeat,value:repeatKey ? 1 : 0)
        if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
        event.post(tap:.cghidEventTap)
    }
    private func chord(_ letters: String = "fgh") async throws {
        guard let keys = InputMonitor.letterKeyCodes(letters) else { throw MouseFailure.unavailable("Keyboard mapping unavailable.") }
        for k in keys.sorted() { try key(k,down:true); await sleep(0.025) }
        await sleep(0.08)
        for k in keys.sorted() { try key(k,down:false); await sleep(0.025) }
        await sleep(0.1)
    }
    private func awaitStatus(_ desired: ClickStatus, timeout: Double = 3) async -> Bool {
        let deadline = model.clock + timeout
        while model.clock < deadline { if model.status == desired { return true }; await sleep(0.025) }; return false
    }
    private func launchPad() async throws {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Click Test Pad.app")
        let config = NSWorkspace.OpenConfiguration(); config.createsNewApplicationInstance = true; config.activates = true; config.arguments = ["--log",logURL.path,"--cover-display"]
        pad = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at:path,configuration:config) { app,error in
                if let app { continuation.resume(returning:app) } else { continuation.resume(throwing:error ?? MouseFailure.unavailable("Could not launch external pad.")) }
            }
        }
        for _ in 0..<50 {
            if let r = try? receiver(), let x=r["targetX"] as? Double, let y=r["targetY"] as? Double { target=CGPoint(x:x,y:y); break }
            await sleep(0.1)
        }
        guard target != .zero, let pad else { throw MouseFailure.unavailable("Test pad did not initialize.") }
        pad.activate(options:[]); await sleep(0.4); try focusGuard()
        model.mouse.verificationProcess = pad.processIdentifier
    }
    private func verifyMovementTrajectories(emergency: ClickSettings) async throws {
        guard let display=model.mouse.movementDisplay(for:0) else { throw MouseFailure.unavailable("No movement display") }
        let bounds=display.bounds
        let allowed=bounds.insetBy(dx:60,dy:60)
        // A thin barrier inside the allowed rectangle; routes can go around either end.
        let blocked=CGRect(x:bounds.midX+45,y:bounds.midY-80,width:1.5,height:160)
        let boxes=[MovementBox(rect:allowed.offsetBy(dx:-bounds.minX,dy:-bounds.minY),blocked:false),MovementBox(rect:blocked.offsetBy(dx:-bounds.minX,dy:-bounds.minY),blocked:true)]
        let profile=MovementRegionProfile(displayIdentity:display.identity,referenceSize:bounds.size,boxes:boxes)
        let domain=profile.domain(for:display)!
        for mode in 0..<4 {
            model.stop();model.engine.clearTargets()
            var settings=ClickSettings()
            settings.emergencyCode=emergency.emergencyCode;settings.emergencyModifiers=emergency.emergencyModifiers
            settings.smallMovementEnabled=mode == 0 || mode == 2;settings.largeMovementEnabled=mode == 1 || mode == 2
            settings.movementProbability=1;settings.largeMovementProbability=1;settings.movementRadius=15
            settings.movementDisplayIdentity=display.identity;settings.movementRegions=[profile]
            settings.breaksEnabled=false;settings.minInterval=100;settings.maxInterval=100
            settings.clickVariationEnabled=true;settings.clickVariationRadius=2
            model.settings=settings;await sleep(0.1)
            // Save an anchor, pause before any action, then start from elsewhere.
            try model.mouse.move(to:target);await sleep(0.05)
            model.engine.start(at:target,settings:settings);model.pause()
            let current=CGPoint(x:target.x-55,y:target.y-40)
            try model.mouse.move(to:current);await sleep(0.08)
            var phases:[(String,Double,CGPoint)]=[]
            let previousChanged=model.engine.changed
            model.engine.changed={ [weak model] in
                previousChanged?()
                if let model,let phase=model.engine.movementPhase,phases.last?.0 != phase {
                    phases.append((phase,model.clock,model.mouse.currentPosition() ?? current))
                }
            }
            let began=model.clock, beforeCount=total()
            model.startButton()
            let deadline=model.clock+12
            while total()==beforeCount && model.engine.active && model.clock<deadline { await sleep(0.04) }
            await sleep(0.1);model.stop();model.engine.changed=previousChanged;await sleep(0.08)
            let recorded=events().filter { isMouseOutput($0) && ($0["time"] as? Double ?? 0)>=began }
            let moves=recorded.filter { ($0["type"] as? String)=="move" }
            let downs=recorded.filter { ($0["type"] as? String)=="rightDown" }
            let ups=recorded.filter { ($0["type"] as? String)=="rightUp" }
            let expected=(settings.smallMovementEnabled ? ["Small outward","Small return"] : [])+(settings.largeMovementEnabled ? ["Large outward","Large return"] : [])
            check("Live movement switches case \(mode): ordered excursions, exactly one click",phases.map(\.0)==expected && downs.count==1 && ups.count==1,"\(phases.map(\.0)); \(moves.count) recorded moves")
            func point(_ row:[String:Any])->CGPoint { CGPoint(x:row["x"] as? Double ?? -1,y:row["y"] as? Double ?? -1) }
            if let down=downs.first,let up=ups.first,let last=moves.last {
                check("Live case \(mode): direct return to one varied down/up coordinate",point(down)==point(up) && point(last)==point(down) && movementDistance(point(down),target)<=2.001 && model.target==target)
            }
            if mode != 3,let first=moves.first { check("Live case \(mode): no initial target snap",movementDistance(point(first),current)<10 && movementDistance(point(first),target)>10) }
            var phaseReports:[[String:Any]]=[]
            for i in phases.indices {
                let phase=phases[i],until=i+1<phases.count ? phases[i+1].1 : (downs.first?["time"] as? Double ?? model.clock)
                let rows=moves.filter { let t=$0["time"] as? Double ?? 0;return t>=phase.1 && t<until }
                let points=[phase.2]+rows.map(point)
                let last=points.last ?? phase.2, length=max(0.000001,movementDistance(phase.2,last))
                let dx=last.x-phase.2.x, dy=last.y-phase.2.y
                var deviation=0.0
                for p in points { let cross=dx*(p.y-phase.2.y)-dy*(p.x-phase.2.x); deviation=max(deviation,abs(cross)/length) }
                check("Recorded \(phase.0) is spatially curved (case \(mode))",rows.count>=8 && deviation>0.03,"\(rows.count) events; maximum deviation from endpoint chord \(deviation) screen points")
                var compliant=true
                if phase.0.hasPrefix("Large") {
                    for j in 1..<points.count { if !domain.permitsSegment(points[j-1],points[j]) { compliant=false } }
                    check("Recorded \(phase.0) and every intervening segment obey regions (case \(mode))",compliant && rows.count>=8)
                }
                let premature=recorded.contains { let t=$0["time"] as? Double ?? 0;return t>=phase.1 && t<until && ["leftDown","rightDown"].contains($0["type"] as? String ?? "") }
                check("No button-down during \(phase.0) (case \(mode))",!premature)
                phaseReports.append(["phase":phase.0,"start":[phase.2.x,phase.2.y],"events":rows,"maximumChordDeviation":deviation,"segmentsCompliant":compliant])
            }
            trajectoryReports.append(["case":mode,"start":[current.x,current.y],"anchor":[target.x,target.y],"phases":phaseReports,"allowed":[allowed.minX,allowed.minY,allowed.width,allowed.height],"blocked":[blocked.minX,blocked.minY,blocked.width,blocked.height]])
        }
        // Neither a current-pointer conflict nor a return conflict may trigger a
        // prohibited excursion. Ordinary clicking stays independent of the boxes.
        var s=ClickSettings();s.emergencyCode=emergency.emergencyCode;s.emergencyModifiers=emergency.emergencyModifiers
        s.smallMovementEnabled=false;s.largeMovementEnabled=true;s.largeMovementProbability=1;s.breaksEnabled=false
        s.regularClickingEnabled=false;s.minInterval=100;s.maxInterval=100
        s.movementRegions=[MovementRegionProfile(displayIdentity:display.identity,referenceSize:bounds.size,boxes:[MovementBox(rect:bounds.offsetBy(dx:-bounds.minX,dy:-bounds.minY),blocked:true)])]
        model.settings=s;await sleep(0.1);let began=model.clock;model.startButton();await sleep(0.35)
        check("Live impossible region skips without moving or pausing the session",model.engine.active && model.engine.movementNote?.contains("outside") == true && !events().contains { isMouseOutput($0) && ($0["time"] as? Double ?? 0)>=began })
        model.stop()
    }
    private struct TravelRun {
        var name: String
        var speed: Double
        var phases: [(String,Double)]
        var events: [[String:Any]]
        var returnedAt: Double
        var startedAt: Double
    }
    private func eventTime(_ row: [String:Any]) -> Double { row["eventTime"] as? Double ?? row["time"] as? Double ?? 0 }
    private func eventPoint(_ row: [String:Any]) -> CGPoint { CGPoint(x:row["x"] as? Double ?? -1,y:row["y"] as? Double ?? -1) }
    private func uniqueEvents(since time: Double) -> [[String:Any]] {
        var seen=Set<String>()
        return events().filter { row in
            guard isMouseOutput(row),eventTime(row)>=time else { return false }
            let key="\(row["tag"] ?? "")-\(row["type"] ?? "")"
            return seen.insert(key).inserted
        }
    }
    private func observeTravel(_ name: String, settings: ClickSettings) async throws -> TravelRun {
        model.stop();model.engine.clearTargets();model.settings=settings;await sleep(0.15)
        pad?.activate(options:[.activateAllWindows]);await sleep(0.12);try focusGuard()
        try model.mouse.move(to:target);await sleep(0.08)
        // Repeat exactly the same destination/control-point draws at both speeds.
        // This fixture exists only in --verify-external; normal launches stay random.
        model.verificationRandom={ $0.lowerBound+($0.upperBound-$0.lowerBound)*0.73 }
        let oldChanged=model.engine.changed,oldMonitor=model.monitor.onMouseEvent
        var phases:[(String,Double)]=[],returnedAt:Double?,finished=false
        model.engine.changed={ [weak model] in
            oldChanged?()
            guard let model else { return }
            if let phase=model.engine.movementPhase {
                if phases.last?.0 != phase { phases.append((phase,model.clock)) }
            } else if !phases.isEmpty && returnedAt == nil && model.engine.active { returnedAt=model.clock }
        }
        model.monitor.onMouseEvent={ [weak model] event,type in
            oldMonitor?(event,type)
            guard let model, returnedAt != nil, model.engine.movementPhase == nil,
                  type == .rightMouseUp, event.getIntegerValueField(.eventSourceUserData) & Int64(bitPattern:0xFFFF000000000000) == SystemMouse.marker else { return }
            finished=true;model.pause()
        }
        defer { model.stop();model.engine.changed=oldChanged;model.monitor.onMouseEvent=oldMonitor;model.verificationRandom=nil }
        let began=model.clock;model.engine.start(at:target,settings:settings)
        let timeout=model.clock+18
        while model.clock<timeout && model.engine.active && !finished {
            if returnedAt != nil && !settings.regularClickingEnabled { finished=true;break }
            await sleep(0.025)
        }
        model.pause();await sleep(0.15)
        guard finished,let returnedAt else { throw MouseFailure.unavailable("\(name) did not finish its trip: \(model.engine.detail) \(model.engine.movementNote ?? "")") }
        return TravelRun(name:name,speed:settings.largeMovementSpeed,phases:phases,events:uniqueEvents(since:began),returnedAt:returnedAt,startedAt:began)
    }
    private func travelPhase(_ row: [String:Any], run: TravelRun) -> String? {
        let time=eventTime(row)
        guard time<run.returnedAt else { return nil }
        return run.phases.last { $0.1<=time }?.0
    }
    private func verifyTravelClicking(emergency: ClickSettings) async throws {
        guard let display=model.mouse.movementDisplay(for:0) else { throw MouseFailure.unavailable("No active display") }
        let bounds=display.bounds,allowed=bounds.insetBy(dx:60,dy:60)
        let blocked=CGRect(x:target.x+45,y:target.y-80,width:1.5,height:160)
        let profile=MovementRegionProfile(displayIdentity:display.identity,referenceSize:bounds.size,boxes:[
            MovementBox(rect:allowed.offsetBy(dx:-bounds.minX,dy:-bounds.minY),blocked:false),
            MovementBox(rect:blocked.offsetBy(dx:-bounds.minX,dy:-bounds.minY),blocked:true)])
        let domain=profile.domain(for:display)!
        var base=ClickSettings();base.emergencyCode=emergency.emergencyCode;base.emergencyModifiers=emergency.emergencyModifiers
        base.smallMovementEnabled=true;base.largeMovementEnabled=true;base.movementProbability=1;base.largeMovementProbability=1
        base.movementRadius=50;base.minInterval=0.16;base.maxInterval=0.16;base.randomIntervalsEnabled=false;base.breaksEnabled=false
        base.movementDisplayIdentity=display.identity;base.movementRegions=[profile];base.button = .right
        func validate(_ run: TravelRun, settings: ClickSettings) {
            let downs=run.events.filter { ($0["type"] as? String)=="rightDown" }
            let small=downs.filter { travelPhase($0,run:run)?.hasPrefix("Small") == true }
            let large=downs.filter { travelPhase($0,run:run)?.hasPrefix("Large") == true }
            let expectedSmall=settings.regularClickingEnabled && settings.smallClickWhileMoving && settings.smallMovementEnabled
            let expectedLarge=settings.regularClickingEnabled && settings.largeClickWhileMoving && settings.largeMovementEnabled
            check("\(run.name): independent travel switches and main clicking gate",small.isEmpty != expectedSmall && large.isEmpty != expectedLarge && (settings.regularClickingEnabled || downs.isEmpty))
            if expectedSmall { check("\(run.name): small outward and return both receive clicks",Set(small.compactMap {travelPhase($0,run:run)}) == ["Small outward","Small return"]) }
            if expectedLarge { check("\(run.name): large outward and return both receive clicks",Set(large.compactMap {travelPhase($0,run:run)}) == ["Large outward","Large return"]) }
            var held:[String:Any]?,paired=true,noDragging=true,lastMove:CGPoint=target,atCursor=true,segments=true
            for row in run.events {
                let kind=row["type"] as? String ?? "",p=eventPoint(row)
                if kind=="move" {
                    if held != nil { noDragging=false }
                    if travelPhase(row,run:run)?.hasPrefix("Large") == true && !domain.permitsSegment(lastMove,p) { segments=false }
                    lastMove=p
                }
                if kind.hasSuffix("Drag") { noDragging=false }
                if kind=="rightDown" {
                    if held != nil { paired=false };held=row
                    if travelPhase(row,run:run) != nil && movementDistance(p,lastMove)>0.02 { atCursor=false }
                    if travelPhase(row,run:run)?.hasPrefix("Large") == true && !domain.contains(p) { segments=false }
                }
                if kind=="rightUp" {
                    if held == nil || eventPoint(held!) != p { paired=false };held=nil
                }
            }
            check("\(run.name): exact pairs, pointer held through up, no dragging",paired && held == nil && noDragging)
            check("\(run.name): travel clicks stay at actual path positions and obey regions",atCursor && segments && model.engine.target==target)
            let gaps=zip(downs,downs.dropFirst()).map {eventTime($1)-eventTime($0)}
            check("\(run.name): no duplicate arrival clicks or catch-up bursts",gaps.allSatisfy {$0>=0.135})
            var activeGaps=[Double]()
            for (a,b) in zip(downs,downs.dropFirst()) {
                if let pa=travelPhase(a,run:run),let pb=travelPhase(b,run:run),pa.hasPrefix("Large") && pb.hasPrefix("Large") { activeGaps.append(eventTime(b)-eventTime(a)) }
            }
            if expectedLarge { check("\(run.name): travel cadence follows 0.16-second setting",!activeGaps.isEmpty && activeGaps.allSatisfy {$0>=0.135 && $0<0.26},"Observed gaps: \(activeGaps)") }
            travelReports.append(["name":run.name,"speed":run.speed,"startedAt":run.startedAt,"returnedAt":run.returnedAt,"phases":run.phases.map {["name":$0.0,"time":$0.1]},"events":run.events,"allowed":[allowed.minX,allowed.minY,allowed.width,allowed.height],"blocked":[blocked.minX,blocked.minY,blocked.width,blocked.height],"largeClickGaps":activeGaps])
        }
        for (small,large) in [(false,false),(false,true),(true,false),(true,true)] {
            var settings=base;settings.smallClickWhileMoving=small;settings.largeClickWhileMoving=large
            let run=try await observeTravel("Travel switches small=\(small), large=\(large)",settings:settings)
            validate(run,settings:settings)
        }
        // Compare the identical path with no click holds obscuring its travel duration.
        var speedRuns=[TravelRun]()
        for speed in [1.0,10.0] {
            var settings=base;settings.smallMovementEnabled=false;settings.regularClickingEnabled=false
            settings.smallClickWhileMoving=true;settings.largeClickWhileMoving=true;settings.largeMovementSpeed=speed
            let run=try await observeTravel("Movement-only \(speed)x",settings:settings);speedRuns.append(run);validate(run,settings:settings)
        }
        let slow=speedRuns[0],fast=speedRuns[1]
        let slowPoints=slow.events.filter {($0["type"] as? String)=="move"}.map(eventPoint)
        let fastPoints=fast.events.filter {($0["type"] as? String)=="move"}.map(eventPoint)
        let slowDuration=slow.returnedAt-slow.phases[0].1,fastDuration=fast.returnedAt-fast.phases[0].1
        check("Identical externally recorded path at 1x and 10x, without skipped samples",slowPoints.count>20 && slowPoints==fastPoints,"\(slowPoints.count) / \(fastPoints.count) distinct posted movement events")
        check("10x substantially shortens the same path in the real external app",fastDuration<slowDuration/2,"1x: \(slowDuration) seconds; 10x: \(fastDuration) seconds; measured factor \(slowDuration/fastDuration). OS dispatch overhead is included.")
        for speed in [1.0,10.0] {
            var settings=base;settings.smallMovementEnabled=false;settings.largeClickWhileMoving=true;settings.largeMovementSpeed=speed
            let run=try await observeTravel("Travel cadence \(speed)x",settings:settings);validate(run,settings:settings)
        }
        // Intercept an actual observed down while the engine is holding the button.
        for pause in [true,false] {
            model.stop();var settings=base;settings.smallMovementEnabled=false;settings.largeClickWhileMoving=true
            model.settings=settings;await sleep(0.15);pad?.activate(options:[.activateAllWindows]);await sleep(0.1)
            try model.mouse.move(to:target);await sleep(0.08)
            let previous=model.monitor.onMouseEvent;var cancelledAt:Double?
            model.monitor.onMouseEvent={ [weak model] event,type in
                previous?(event,type)
                guard let model,type == .rightMouseDown,cancelledAt == nil,model.engine.movementPhase?.hasPrefix("Large") == true else {return}
                cancelledAt=model.clock
                if pause {model.pause()} else {model.stop()}
            }
            let began=model.clock;model.engine.start(at:target,settings:settings);await sleep(0.7)
            model.monitor.onMouseEvent=previous
            let rows=uniqueEvents(since:began),downs=rows.filter {($0["type"] as? String)=="rightDown"},ups=rows.filter {($0["type"] as? String)=="rightUp"}
            let later=rows.filter {eventTime($0) >= (cancelledAt ?? Double.infinity) && ["move","rightDown"].contains($0["type"] as? String ?? "")}
            check("\(pause ? "Pause" : "Stop") during a real travel down releases that exact pair immediately",cancelledAt != nil && !model.engine.active && downs.count==1 && ups.count==1 && eventPoint(downs[0])==eventPoint(ups[0]) && later.isEmpty)
            model.stop()
        }
        var timed=base;timed.smallMovementEnabled=false;timed.largeClickWhileMoving=true;timed.minInterval=0.85;timed.maxInterval=0.85
        timed.timerEnabled=true;timed.timerMinutes=0;timed.timerSeconds=1;timed.finalClickEnabled=true;timed.finalButton = .left
        model.settings=timed;await sleep(0.15);pad?.activate(options:[.activateAllWindows]);await sleep(0.1)
        try model.mouse.move(to:target);await sleep(0.08);let final=CGPoint(x:target.x-120,y:target.y+100)
        _=model.engine.captureFinalTarget(final);model.verificationRandom={ $0.lowerBound+($0.upperBound-$0.lowerBound)*0.73 }
        let began=model.clock;model.engine.start(at:target,settings:timed)
        let stopped=await awaitStatus(.stopped,timeout:2.5);await sleep(0.12);model.verificationRandom=nil
        let rows=uniqueEvents(since:began),finals=rows.filter {($0["type"] as? String)=="leftDown"},finalUps=rows.filter {($0["type"] as? String)=="leftUp"}
        let regular=rows.filter {($0["type"] as? String)=="rightDown"}
        check("Timer expiry cancels travel clicks and delivers one exact final pair",stopped && finals.count==1 && finalUps.count==1 && eventPoint(finals[0])==final && eventPoint(finalUps[0])==final && regular.allSatisfy {eventTime($0)<began+1},"\(regular.count) regular clicks; final at \(final)")
        model.stop()
    }
    private func verifySecondaryClicking(emergency: ClickSettings) async throws {
        guard let display = model.mouse.movementDisplay(for: 0) else { throw MouseFailure.unavailable("No secondary-area test display.") }
        model.stop(); model.engine.clearTargets()
        let area = CGRect(x: target.x + 120, y: target.y - 25, width: 50, height: 50)
        guard display.bounds.contains(area) else { throw MouseFailure.unavailable("Display is too small for the secondary-area test.") }
        var settings = ClickSettings()
        settings.emergencyCode = emergency.emergencyCode; settings.emergencyModifiers = emergency.emergencyModifiers
        settings.smallMovementEnabled = false; settings.largeMovementEnabled = false; settings.breaksEnabled = false
        settings.minInterval = 100; settings.maxInterval = 100; settings.button = .right
        settings.secondaryClickEnabled = true; settings.secondaryMinInterval = 1; settings.secondaryMaxInterval = 1
        settings.movementDisplayIdentity = display.identity
        settings.movementRegions = [MovementRegionProfile(displayIdentity: display.identity, referenceSize: display.bounds.size, boxes: [
            MovementBox(rect: area.offsetBy(dx: -display.bounds.minX, dy: -display.bounds.minY), blocked: false, secondaryClick: true)
        ])]
        model.settings = settings; await sleep(0.15)
        pad?.activate(options: [.activateAllWindows]); await sleep(0.1); try focusGuard()
        try model.mouse.move(to: target); await sleep(0.08)
        var phases: [(String, Double)] = []
        var returned = false
        let previousChanged = model.engine.changed
        model.engine.changed = { [weak model] in
            previousChanged?()
            guard let model else { return }
            if let phase = model.engine.movementPhase, phase.hasPrefix("Secondary"), phases.last?.0 != phase {
                phases.append((phase, model.clock))
            }
            if phases.last?.0 == "Secondary return", model.engine.movementPhase == nil { returned = true }
        }
        defer { model.engine.changed = previousChanged; model.verificationRandom = nil; model.stop() }
        model.verificationRandom = { $0.lowerBound + ($0.upperBound - $0.lowerBound) * 0.63 }
        let began = model.clock
        model.engine.start(at: target, settings: settings)
        while !returned && model.engine.active && model.clock < began + 12 { await sleep(0.02) }
        let ended = model.clock
        let returnPoint = model.mouse.currentPosition()
        model.stop(); await sleep(0.12)
        let rows = uniqueEvents(since: began)
        let downs = rows.filter { ($0["type"] as? String) == "rightDown" }
        let ups = rows.filter { ($0["type"] as? String) == "rightUp" }
        check("Secondary area: one original pair and one purple-area pair", returned && downs.count == 2 && ups.count == 2 && downs.filter { area.contains(eventPoint($0)) }.count == 1)
        check("Secondary area: preserves target and curves back before next regular click", model.target == target && returnPoint.map { movementDistance($0, target) < 0.01 } == true)
        check("Secondary timer wakes independently of a 100-second regular interval", phases.first.map { $0.1 >= began + 0.98 && $0.1 < began + 1.6 } == true)
        check("Secondary area: ordered outward, click, return phases", phases.map(\.0) == ["Secondary outward", "Secondary click", "Secondary return"])
        for index in phases.indices where phases[index].0 != "Secondary click" {
            let phase = phases[index]
            let until = index + 1 < phases.count ? phases[index + 1].1 : ended
            let segment = rows.filter { eventTime($0) >= phase.1 && eventTime($0) < until }
            let points = segment.filter { ($0["type"] as? String) == "move" }.map(eventPoint)
            let hasDown = segment.contains { ["rightDown", "leftDown"].contains($0["type"] as? String ?? "") }
            var deviation = 0.0
            if let first = points.first, let last = points.last {
                let dx = last.x - first.x, dy = last.y - first.y, length = max(0.001, movementDistance(first, last))
                deviation = points.map { abs(dx * ($0.y - first.y) - dy * ($0.x - first.x)) / length }.max() ?? 0
            }
            check("\(phase.0): curved samples and no travel click", points.count >= 8 && deviation > 0.03 && !hasDown)
        }
        let countAfterStop = mouseOutputCount(); await sleep(1.1)
        check("Secondary area: Stop cancels future visits", mouseOutputCount() == countAfterStop && model.status == .stopped)
    }
    private func run() async {
        let saved = model.settings
        model.stop(); model.refreshPermissions()
        guard model.ready else { write("blocked",reason:model.permissionReason); return }
        let outputDir = URL(fileURLWithPath:reportPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at:outputDir,withIntermediateDirectories:true)
        logURL = outputDir.appendingPathComponent("external-pad-\(UUID().uuidString).json")
        do {
            try await launchPad()
            var testSettings = ClickSettings()
            testSettings.emergencyCode=saved.emergencyCode;testSettings.emergencyModifiers=saved.emergencyModifiers
            testSettings.minInterval=0.25;testSettings.maxInterval=0.32;testSettings.breakProbability=0;testSettings.movementProbability=1;testSettings.movementRadius=8;testSettings.button = .right
            model.settings=testSettings;await sleep(0.1)
            try model.mouse.move(to:target)
            try await chord(); await sleep(1.8)
            guard let firstTarget = model.target else { throw MouseFailure.unavailable("The first shortcut did not save a target.") }
            check("Right clicks received by separate foreground application",count("right") >= 2 && model.status == .running,"\(count("right")) right button-down events recorded by external pad.")
            let taggedMoves=events().filter { ($0["type"] as? String)=="move" && ((($0["tag"] as? Int64) ?? 0) & Int64(bitPattern: 0xFFFF000000000000)) == SystemMouse.marker }
            // The user may move during the chord. Check the position actually saved
            // when its final key arrived, not the earlier pad-center setup position.
            let pathMoves = taggedMoves.dropFirst()
            let displaced=pathMoves.contains { hypot(($0["x"] as? Double ?? firstTarget.x)-firstTarget.x,($0["y"] as? Double ?? firstTarget.y)-firstTarget.y)>0.2 }
            let bounded=pathMoves.allSatisfy { hypot(($0["x"] as? Double ?? firstTarget.x)-firstTarget.x,($0["y"] as? Double ?? firstTarget.y)-firstTarget.y)<=testSettings.movementRadius+1 }
            let downs=events().filter { ["rightDown","leftDown"].contains($0["type"] as? String ?? "") }
            check("Movement leaves target then clicks only at saved target",displaced && bounded && !downs.isEmpty && downs.allSatisfy { abs(($0["x"] as? Double ?? -100)-firstTarget.x)<1 && abs(($0["y"] as? Double ?? -100)-firstTarget.y)<1 }, "Saved target: \(firstTarget.x), \(firstTarget.y); movement bounded to \(testSettings.movementRadius) points.")
            check("FGH reaches the external app without swallowing keys",events().filter { ($0["type"] as? String)=="keyDown" }.count>=3)
            try await chord();let paused=await awaitStatus(.paused);let n=total();await sleep(0.4)
            check("FGH pauses and cancels pending clicks",paused && total()==n)

            // Hold and repeat the same chord. All keys must be released to rearm.
            let keys=InputMonitor.letterKeyCodes()!.sorted()
            testSettings.movementProbability=0;model.settings=testSettings;await sleep(0.1)
            for k in keys { try key(k,down:true);await sleep(0.02) }
            for _ in 0..<8 { try key(keys[2],down:true,repeatKey:true);await sleep(0.035) }
            check("Holding and keyboard auto-repeat toggle only once",model.engine.active)
            for k in keys.prefix(2) { try key(k,down:false) }
            for k in keys.prefix(2) { try key(k,down:true) }
            await sleep(0.2);check("Partial key release does not rearm toggle",model.engine.active)
            for k in keys { try key(k,down:false) };await sleep(0.1)
            try await chord();check("All keys released permits next pause",model.status == .paused)
            guard let retainedTarget = model.target else { throw MouseFailure.unavailable("No saved target remained after pause.") }

            testSettings.button = .left;model.settings=testSettings;await sleep(0.1)
            // Use the Start-button handler while pointer is elsewhere: target must stay saved.
            let displacedPoint=CGPoint(x:target.x+65,y:target.y+25)
            try model.mouse.move(to:displacedPoint);let beforeLeft=count("left")
            model.startButton();await sleep(0.5)
            check("Start button reuses saved target and delivers left clicks",model.target==retainedTarget && count("left")>beforeLeft)
            let beforeManual=events().count
            if let manual=CGEvent(mouseEventSource:CGEventSource(stateID:.hidSystemState),mouseType:.mouseMoved,mouseCursorPosition:displacedPoint,mouseButton:.left) {
                manual.setIntegerValueField(.eventSourceUserData,value:0);manual.post(tap:.cghidEventTap)
            }
            await sleep(0.06)
            let movementDidNotPause=model.engine.active && model.target==retainedTarget
            await sleep(0.5)
            let afterManualDowns=events().dropFirst(beforeManual).filter { ($0["type"] as? String)=="leftDown" }
            check("Untagged pointer movement does not pause or replace target",movementDidNotPause && model.engine.active && model.target==retainedTarget && !afterManualDowns.isEmpty && afterManualDowns.allSatisfy { abs(($0["x"] as? Double ?? -100)-retainedTarget.x)<1 && abs(($0["y"] as? Double ?? -100)-retainedTarget.y)<1 },"Test-generated untagged movement; subsequent external clicks return to the saved target. Physical mouse not hand-tested.")
            let stopTime=model.clock;model.stop();await sleep(0.4)
            let postStop=events().filter { isMouseOutput($0) && ($0["eventTime"] as? Double ?? 0)>=stopTime && ["move","leftDown","rightDown"].contains($0["type"] as? String ?? "") }
            check("Stop cancels pending clicks",model.status == .stopped && postStop.isEmpty,"Checked event-creation times against Stop, allowing releases of an already-held button.")

            // Next shortcut samples a fresh pointer position.
            try model.mouse.move(to:displacedPoint);try await chord();await sleep(0.25)
            check("Shortcut resume captures a new target",model.target==displacedPoint)
            let flags:CGEventFlags = testSettings.emergencyModifiers==0 ? [] : [.maskControl,.maskAlternate]
            let emergencyBegan=model.clock
            try key(CGKeyCode(testSettings.emergencyCode),down:true,flags:flags)
            let emergency=await awaitStatus(.stopped,timeout:0.15)
            let emergencyLatency=model.clock-emergencyBegan
            try key(CGKeyCode(testSettings.emergencyCode),down:false,flags:flags)
            let afterEmergency=total();await sleep(0.4)
            check("Emergency stop works with external app focused",emergency && total()==afterEmergency,"Stopped within \(String(format: "%.3f", emergencyLatency)) seconds of key posting; no subsequent clicks.")

            testSettings.breakProbability=1;testSettings.minBreak=0.5;testSettings.maxBreak=0.7;model.settings=testSettings;await sleep(0.1)
            model.startButton();let enteredBreak=await awaitStatus(.takingBreak)
            let breakCount=total();await sleep(0.15);let quiet=total()==breakCount;await sleep(0.8)
            check("Random-duration break pauses then resumes automatically",enteredBreak && quiet && total()>breakCount)
            _ = await awaitStatus(.takingBreak);model.pause();let breakStopped=total();await sleep(1)
            check("Pause cancels a pending automatic break resume",model.status == .paused && total()==breakStopped)

            testSettings.breakProbability=0;testSettings.movementProbability=1;model.settings=testSettings;await sleep(0.1)
            let beforePath=total();model.startButton();await sleep(0.17);model.stop();await sleep(0.5)
            check("Stop cancels a real cursor path before its click",total()==beforePath && model.status == .stopped)
            // Covering the display keeps full-screen movement in a harmless separate app.
            testSettings.regularClickingEnabled=false;testSettings.largeMovementProbability=1;testSettings.movementMode = .fullScreen;testSettings.movementEnabled=true
            testSettings.movementProbability=1;testSettings.breaksEnabled=false;testSettings.minInterval=2;testSettings.maxInterval=2
            model.settings=testSettings;await sleep(0.1)
            let beforeWander=events().count, beforeWanderClicks=total(), wanderingAnchor=model.target
            model.startButton();await sleep(1.1)
            let wanderMoves=events().dropFirst(beforeWander).filter { isMouseOutput($0) && ($0["type"] as? String)=="move" }
            check("Full-screen movement-only session moves without a click or acknowledgement",model.status == .running && total()==beforeWanderClicks && wanderMoves.count>=20 && model.target==wanderingAnchor)
            model.pause();await sleep(0.05);let afterWanderStop=mouseOutputCount();await sleep(0.3)
            check("Pause cancels full-screen movement promptly",model.status == .paused && mouseOutputCount()==afterWanderStop)
            model.startButton();await sleep(0.25)
            try key(CGKeyCode(testSettings.emergencyCode),down:true,flags:flags);await sleep(0.05);try key(CGKeyCode(testSettings.emergencyCode),down:false,flags:flags)
            await sleep(0.05);let afterWanderEmergency=mouseOutputCount();await sleep(0.3)
            check("Emergency stop cancels movement-only session",model.status == .stopped && mouseOutputCount()==afterWanderEmergency)

            // Capture-only chord: independent latching and pass-through to the receiver.
            let finalPoint=CGPoint(x:target.x+150,y:target.y+90), alternateFinal=CGPoint(x:target.x+180,y:target.y+70)
            let beforeCapture=total(), regularBeforeCapture=model.target
            try model.mouse.move(to:finalPoint);await sleep(0.08)
            let captureKeys=InputMonitor.letterKeyCodes("iop")!.sorted()
            for k in captureKeys { try key(k,down:true);await sleep(0.025) }
            await sleep(0.08);let firstFinal=model.finalTarget
            try model.mouse.move(to:alternateFinal);await sleep(0.06)
            for _ in 0..<5 { try key(captureKeys[2],down:true,repeatKey:true) }
            for k in captureKeys.prefix(2) { try key(k,down:false);try key(k,down:true) }
            await sleep(0.1)
            check("IOP captures only the final target and ignores repeat or partial release",firstFinal==finalPoint && model.finalTarget==firstFinal && model.target==regularBeforeCapture && total()==beforeCapture && model.status == .stopped)
            for k in captureKeys { try key(k,down:false) };await sleep(0.08)
            try await chord("iop")
            check("All IOP releases rearm capture and the keys reach the external app",model.finalTarget==alternateFinal && events().filter { ($0["type"] as? String)=="keyDown" && captureKeys.contains(CGKeyCode($0["code"] as? Int ?? -1)) }.count>=6)
            guard let exactFinal=model.finalTarget else { throw MouseFailure.unavailable("Final target was not captured.") }

            testSettings.regularClickingEnabled=true;testSettings.movementEnabled=false;testSettings.randomIntervalsEnabled=true
            testSettings.clickVariationEnabled=true;testSettings.clickVariationRadius=2
            testSettings.minInterval=0.2;testSettings.maxInterval=0.25;testSettings.button = .right
            testSettings.timerEnabled=true;testSettings.timerHours=0;testSettings.timerMinutes=0;testSettings.timerSeconds=2
            testSettings.finalClickEnabled=true;testSettings.finalButton = .left
            model.settings=testSettings;await sleep(0.1)
            try model.mouse.move(to:target);await sleep(0.08);let timedStart=events().count
            try await chord();guard let timedAnchor=model.target else { throw MouseFailure.unavailable("Regular target was not captured.") }
            let timedStopped=await awaitStatus(.stopped,timeout:3.5);await sleep(0.08)
            let timedEvents=Array(events().dropFirst(timedStart)).filter(isMouseOutput)
            let regularDowns=timedEvents.filter { ($0["type"] as? String)=="rightDown" }
            let finalDowns=timedEvents.filter { ($0["type"] as? String)=="leftDown" }
            let finalUps=timedEvents.filter { ($0["type"] as? String)=="leftUp" }
            check("Regular click variation stays within two screen points of original target",regularDowns.count>=4 && regularDowns.allSatisfy { distance($0,timedAnchor)<=2.01 } && regularDowns.contains { distance($0,timedAnchor)>0.05 },"Regular anchor: \(timedAnchor.x), \(timedAnchor.y).")
            check("Timer sends exactly one separate final pair at the exact IOP coordinate",timedStopped && finalDowns.count==1 && finalUps.count==1 && distance(finalDowns[0],exactFinal)<0.0001 && distance(finalUps[0],exactFinal)<0.0001,"Exact final target: \(exactFinal.x), \(exactFinal.y).")
            let afterCompletion=mouseOutputCount();await sleep(0.5)
            check("No mouse actions follow natural timer completion",mouseOutputCount()==afterCompletion && model.status == .stopped)

            testSettings.regularClickingEnabled=false;testSettings.timerSeconds=1;testSettings.finalButton = .right
            model.settings=testSettings;await sleep(0.1);let independentBefore=total()
            model.startButton();let independentStopped=await awaitStatus(.stopped,timeout:2);await sleep(0.08)
            check("Final click is independent of disabled regular clicking and movement",independentStopped && total()==independentBefore+1)

            testSettings.timerSeconds=2;model.settings=testSettings;await sleep(0.1)
            model.startButton();await sleep(0.4);model.pause();let frozen=model.engine.remainingDuration
            let pauseCount=total();await sleep(1.9)
            check("Manual Pause freezes timer without emitting final click",model.status == .paused && model.engine.remainingDuration==frozen && total()==pauseCount)
            model.startButton();let resumedTimer=await awaitStatus(.stopped,timeout:2.5);await sleep(0.08)
            check("Resume continues remaining time and completes only once",resumedTimer && total()==pauseCount+1)

            testSettings.timerSeconds=1;model.settings=testSettings;await sleep(0.1)
            model.startButton();await sleep(0.2);model.stop();let manualStopCount=mouseOutputCount();await sleep(1.1)
            check("Manual Stop cancels timer without a final click",model.status == .stopped && mouseOutputCount()==manualStopCount)
            model.startButton();await sleep(0.2);model.settings.clickVariationRadius=3;await sleep(0.15)
            let settingsCount=mouseOutputCount();await sleep(1.1)
            check("Changing a setting pauses the live session and suppresses final click",model.status == .paused && mouseOutputCount()==settingsCount)
            model.stop()

            testSettings.regularClickingEnabled=true;testSettings.breaksEnabled=true;testSettings.breakProbability=1
            testSettings.minBreak=5;testSettings.maxBreak=5;testSettings.button = .right;testSettings.finalButton = .left
            model.settings=testSettings;await sleep(0.1);let beforeExpiryBreak=events().count
            model.startButton();let timerBreak=await awaitStatus(.takingBreak,timeout:1)
            let breakExpired=await awaitStatus(.stopped,timeout:2);await sleep(0.08)
            let breakFinals=events().dropFirst(beforeExpiryBreak).filter { isMouseOutput($0) && ($0["type"] as? String)=="leftDown" }
            check("Timer expiry interrupts a long break and sends the exact final click",timerBreak && breakExpired && breakFinals.count==1 && distance(breakFinals[0],exactFinal)<0.0001)

            testSettings.regularClickingEnabled=false;testSettings.breaksEnabled=false;testSettings.movementEnabled=true
            testSettings.minInterval=0.08;testSettings.maxInterval=0.08;testSettings.largeMovementProbability=1;testSettings.movementMode = .fullScreen
            model.settings=testSettings;await sleep(0.1);let beforeMotionExpiry=events().count
            model.startButton();let motionExpired=await awaitStatus(.stopped,timeout:2);await sleep(0.08)
            let motionFinals=events().dropFirst(beforeMotionExpiry).filter { isMouseOutput($0) && ($0["type"] as? String)=="leftDown" }
            let motionDone=mouseOutputCount();await sleep(0.3)
            check("Timer expiry cancels wandering before one exact final click",motionExpired && motionFinals.count==1 && distance(motionFinals[0],exactFinal)<0.0001 && mouseOutputCount()==motionDone)
            try await verifyMovementTrajectories(emergency: saved)
            try await verifyTravelClicking(emergency: saved)
            try await verifySecondaryClicking(emergency: saved)
            let buttonEvents=events().filter { ["leftDown","leftUp","rightDown","rightUp"].contains($0["type"] as? String ?? "") }
            check("Posted button-down events have matching button-up events",buttonEvents.filter { ($0["type"] as? String)?.hasSuffix("Down")==true }.count == buttonEvents.filter { ($0["type"] as? String)?.hasSuffix("Up")==true }.count)
        } catch { check("External verification completed",false,error.localizedDescription) }
        model.stop()
        for k in heldKeys { if let e=CGEvent(keyboardEventSource:keyboard,virtualKey:k,keyDown:false) { e.post(tap:.cghidEventTap) } }
        heldKeys.removeAll();model.verificationRandom=nil;model.mouse.verificationProcess=nil;model.settings=saved;model.persist();model.engine.clearTargets()
        write(checks.allSatisfy { $0["passed"] as? Bool == true } ? "passed" : "failed")
        pad?.terminate();NSApp.activate(ignoringOtherApps:true)
    }
}
