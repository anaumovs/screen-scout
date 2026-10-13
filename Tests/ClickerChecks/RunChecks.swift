import Foundation
import CoreGraphics
import ScoutClicker

@MainActor final class FakeMouse: MouseOutput {
    var available = true
    var failureReason = "Permission denied"
    var position = CGPoint(x: 200, y: 200)
    var events: [(String, CGPoint)] = []
    var held: ClickButton?
    var heldPoint: CGPoint?
    var forbidden: [CGRect] = []
    var failDown = false
    var observe: ((String, CGPoint) -> Void)?
    private func record(_ kind: String, _ point: CGPoint) { events.append((kind, point)); observe?(kind, point) }
    func currentPosition() -> CGPoint? { position }
    func movementDisplay(for id: UInt32) -> MovementDisplay? { displayBounds(for: id).map { MovementDisplay(identity: "test-display", bounds: $0) } }
    func displayBounds(for id: UInt32) -> CGRect? { [0,42].contains(id) ? CGRect(x:0,y:0,width:800,height:600) : nil }
    func displayBounds(containing point: CGPoint) -> CGRect? { let r = CGRect(x:0,y:0,width:800,height:600); return r.contains(point) ? r : nil }
    func allows(_ p: CGPoint) -> Bool { p.x >= 0 && p.x < 800 && p.y >= 0 && p.y < 600 && !forbidden.contains(where: { $0.contains(p) }) }
    func move(to p: CGPoint) throws { position = p; record("move", p) }
    func down(_ b: ClickButton, at p: CGPoint) throws { if failDown { throw MouseFailure.unavailable("Test posting failure") }; held = b; heldPoint = p; record("down-" + b.rawValue, p) }
    func up(_ b: ClickButton, at p: CGPoint) throws { held = nil; record("up-" + b.rawValue, p) }
    func release() { if let held { record("release-" + held.rawValue, heldPoint ?? position) }; held = nil }
    var downs: [(String, CGPoint)] { events.filter { $0.0.hasPrefix("down") } }
}
@MainActor final class Clock: ActionScheduler {
    final class Token: PendingAction { var cancelled = false; func cancel() { cancelled = true } }
    var now = 0.0
    var queued: [(Double, Token, @MainActor () -> Void)] = []
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PendingAction {
        let token = Token(); queued.append((now + delay, token, action)); return token
    }
    func advance(_ interval: Double, forceCancelled: Bool = false) {
        let until = now + interval
        var limit = 20000
        while let index = queued.indices.filter({ queued[$0].0 <= until }).min(by: { queued[$0].0 < queued[$1].0 }) {
            let task = queued.remove(at: index); now = task.0
            if forceCancelled || !task.1.cancelled { task.2() }
            limit -= 1; if limit == 0 { fatalError("Scheduler loop") }
        }
        now = until
    }
    func deliverLate(by interval: Double) {
        now += interval
        let ready = queued.filter { $0.0 <= now }; queued.removeAll { $0.0 <= now }
        for task in ready where !task.1.cancelled { task.2() }
    }
}
@main struct Checks {
    @MainActor static func main() {
        var count = 0, failures = 0
        func test(_ name: String, _ check: () -> Bool) {
            count += 1
            if check() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }
        func setup(_ mutate: (inout ClickSettings) -> Void = { _ in }, random: @escaping (ClosedRange<Double>) -> Double = { ($0.lowerBound + $0.upperBound) / 2 }) -> (ClickEngine, FakeMouse, Clock, ClickSettings) {
            let mouse = FakeMouse(), clock = Clock(); var s = ClickSettings()
            s.minInterval = 0.3; s.maxInterval = 0.6; s.movementProbability = 0; s.breakProbability = 0; mutate(&s)
            let engine = ClickEngine(output: mouse, scheduler: clock, random: random)
            return (engine, mouse, clock, s)
        }
        test("Defaults use right-click and valid variation") { let s = ClickSettings(); return s.button == .right && s.validationError == nil && s.maxInterval > s.minInterval }
        test("Legacy timing, movement, breaks and emergency key migrate") {
            let data = try! JSONSerialization.data(withJSONObject: ["minInterval": 0.8, "maxInterval": 1.7, "pauseProbability": 0.22, "movementProbability": 0.3, "hotkeyCode": 101, "hotkeyModifiers": 0])
            let s = ClickSettings.load(current: nil, legacy: data)
            return s.minInterval == 0.8 && s.maxInterval == 1.7 && s.breakProbability == 0.22 && s.movementProbability == 0.3 && s.emergencyCode == 101 && s.button == .right
        }
        test("Invalid persisted settings recover to safe defaults") { var s = ClickSettings(); s.maxInterval = -3; let d = try! JSONEncoder().encode(s); return ClickSettings.load(current: d, legacy: nil).validationError == nil }
        test("FGH toggles once, even with repeat and a held key") {
            var l = ChordLatch(); var toggles = 0
            for k: UInt16 in [3,5,4] { if l.update(code: k, down: true) { toggles += 1 } }
            for _ in 0..<20 { if l.update(code: 4, down: true, repeated: true) { toggles += 1 } }
            _ = l.update(code: 3, down: false); _ = l.update(code: 5, down: false)
            for k: UInt16 in [3,5] { if l.update(code: k, down: true) { toggles += 1 } }
            return toggles == 1
        }
        test("All three releases rearm; order does not matter") {
            var l = ChordLatch(); for k: UInt16 in [4,3,5] { _ = l.update(code: k, down: true) }
            for k: UInt16 in [3,5,4] { _ = l.update(code: k, down: false) }
            _ = l.update(code: 4, down: true); _ = l.update(code: 5, down: true)
            return l.update(code: 3, down: true)
        }
        test("Ordinary individual keys do not toggle") {
            var l = ChordLatch(); var toggles = 0
            for k: UInt16 in [3,5,4,0,1,2] { if l.update(code: k, down: true) { toggles += 1 }; _ = l.update(code: k, down: false) }
            return toggles == 0
        }
        test("Reconnecting monitor requires release of held chord keys") {
            var l = ChordLatch(); l.requireRelease(currentlyDown: [3,5])
            let first = l.update(code: 4, down: true)
            for k: UInt16 in [3,5,4] { _ = l.update(code: k, down: false) }
            _ = l.update(code: 3, down: true); _ = l.update(code: 4, down: true)
            return !first && l.update(code: 5, down: true)
        }
        test("Launch stopped; no target and no scheduled work") { let (e,m,c,_) = setup(); c.advance(100); return e.status == .stopped && e.target == nil && m.events.isEmpty }
        test("Missing permission sends no events and cannot say Running") { let (e,m,c,s) = setup(); m.available = false; e.start(at: m.position, settings:s); c.advance(20); return e.status == .paused && m.events.isEmpty }
        test("Running is withheld until OS event acknowledgement") { let (e,m,c,s) = setup(); e.start(at:m.position,settings:s); c.advance(0.2); let awaiting = e.status == .starting; e.confirmDelivery(); return awaiting && e.status == .running }
        test("Real-output contract receives selected left and right button pairs") {
            for button in ClickButton.allCases {
                let (e,m,c,s) = setup({ $0.button = button }); e.start(at:m.position,settings:s); c.advance(0.2)
                if !m.events.contains(where: { $0.0 == "down-"+button.rawValue }) || !m.events.contains(where: { $0.0 == "up-"+button.rawValue }) { return false }
            }; return true
        }
        test("Manual pointer movement does not pause or replace saved target") { let (e,m,c,s) = setup(); e.start(at:m.position,settings:s); c.advance(0.2); m.position = CGPoint(x:600,y:400); c.advance(0.6); return e.active && e.target == CGPoint(x:200,y:200) && m.downs.allSatisfy { $0.1 == e.target } && m.downs.count >= 2 }
        test("Start button path reuses target; chord path replaces it") { let (e,m,c,s) = setup(); e.start(at:m.position,settings:s); e.pause(); m.position = CGPoint(x:600,y:400); e.start(settings:s); let old = e.target; e.pause(); e.start(at:m.position,settings:s); c.advance(0.2); return old == CGPoint(x:200,y:200) && e.target == CGPoint(x:600,y:400) }
        test("One loop across repeated Start requests") { let (e,m,c,s) = setup(); for _ in 0..<10 { e.start(at:m.position,settings:s) }; c.advance(0.2,forceCancelled:true); return m.downs.count == 1 }
        test("Stop cancels callbacks even if cancelled work is dequeued") { let (e,m,c,s) = setup(); e.start(at:m.position,settings:s); e.stop(); c.advance(20,forceCancelled:true); return m.downs.isEmpty && e.status == .stopped }
        test("Stop releases a pressed button immediately") { let (e,m,c,s) = setup(); e.start(at:m.position,settings:s); c.advance(0.14); guard m.held != nil else { return false }; e.stop(); let n = m.events.count; c.advance(10,forceCancelled:true); return m.held == nil && m.events.count == n && m.events.last?.0 == "release-Right click" }
        test("Pause cancels a movement path before any click") { let (e,m,c,s) = setup({ $0.movementProbability = 1 }); e.start(at:m.position,settings:s); c.advance(0.16); e.pause(); let n = m.events.count; c.advance(10,forceCancelled:true); return m.downs.isEmpty && m.events.count == n }
        test("Movement stays within radius and returns before button-down") {
            let (e,m,c,s) = setup({ $0.movementProbability = 1; $0.movementRadius = 10 }); let p = m.position
            e.start(at:p,settings:s); c.advance(0.8)
            guard let index = m.events.firstIndex(where: { $0.0.hasPrefix("down") }), index > 0 else { return false }
            return m.events[index-1].0 == "move" && m.events[index-1].1 == p && m.events[index].1 == p && m.events.filter { $0.0 == "move" }.allSatisfy { hypot($0.1.x-p.x,$0.1.y-p.y) <= 10.001 }
        }
        test("Random breaks suspend clicks and resume automatically") { let (e,m,c,s) = setup({ $0.breakProbability = 1; $0.minBreak = 1; $0.maxBreak = 2 }); e.start(at:m.position,settings:s); c.advance(0.7); let rest = e.status == .takingBreak; let n = m.downs.count; c.advance(0.8); let quiet = m.downs.count == n; c.advance(0.7); return rest && quiet && m.downs.count == n+1 }
        test("Pause immediately cancels an in-progress break") { let (e,m,c,s) = setup({ $0.breakProbability = 1 }); e.start(at:m.position,settings:s); c.advance(0.7); e.pause(); let n = m.downs.count; c.advance(30,forceCancelled:true); return e.status == .paused && m.downs.count == n }
        test("Permission loss cancels next action and releases button") { let (e,m,c,s) = setup(); e.start(at:m.position,settings:s); c.advance(0.14); m.available = false; c.advance(0.1); return e.status == .paused && m.held == nil }
        test("Off-display target cannot start") { let (e,m,c,s) = setup(); e.start(at:CGPoint(x:-20,y:200),settings:s); c.advance(10); return e.status == .paused && m.events.isEmpty }
        test("System overlays do not hide the Start-button target guard") {
            let bounds = CGRect(x:0,y:0,width:800,height:600)
            let windows = [WindowDescriptor(pid:99,layer:20,bounds:bounds),WindowDescriptor(pid:1,layer:0,bounds:bounds)]
            return !SystemMouse.windowAllows(CGPoint(x:100,y:100),windows:windows,ownPID:1)
        }
        test("Foreground external window stays eligible over background Screen Scout") {
            let bounds = CGRect(x:0,y:0,width:800,height:600)
            let windows = [WindowDescriptor(pid:99,layer:20,bounds:bounds),WindowDescriptor(pid:2,layer:0,bounds:bounds),WindowDescriptor(pid:1,layer:0,bounds:bounds)]
            return SystemMouse.windowAllows(CGPoint(x:100,y:100),windows:windows,ownPID:1,testPID:2)
        }
        test("External verification cannot click another process or empty desktop") {
            let windows = [WindowDescriptor(pid:3,layer:0,bounds:CGRect(x:0,y:0,width:800,height:600))]
            return !SystemMouse.windowAllows(CGPoint(x:100,y:100),windows:windows,ownPID:1,testPID:2) && !SystemMouse.windowAllows(.zero,windows:[],ownPID:1,testPID:2)
        }
        test("Fresh random interval is sampled each click") {
            var draws = 0
            let (e,m,c,s) = setup(random: { range in if range.lowerBound == 0.3 { draws += 1 }; return range.upperBound })
            e.start(at:m.position,settings:s); c.advance(3); return draws >= 4 && m.downs.count >= 4
        }
        test("V2 preferences retain values and effective behavior; additions start off") {
            let d = try! JSONSerialization.data(withJSONObject: ["minInterval":0.7,"maxInterval":1.9,"movementProbability":0.42,"movementRadius":7,"breakProbability":0.2,"minBreak":6,"maxBreak":13,"button":"Left click","emergencyCode":109,"emergencyModifiers":6144])
            let s = ClickSettings.load(current:d,legacy:nil)
            return s.minInterval == 0.7 && s.maxInterval == 1.9 && s.movementRadius == 7 && s.movementProbability == 0.42 && s.minBreak == 6 && s.maxBreak == 13 && s.button == .left && s.finalButton == .left && s.emergencyCode == 109 && s.regularClickingEnabled && s.randomIntervalsEnabled && s.movementEnabled && s.breaksEnabled && !s.clickVariationEnabled && !s.timerEnabled && !s.finalClickEnabled && s.movementMode == .local
        }
        test("All switches round-trip without discarding their configurations") {
            var s = ClickSettings(); s.regularClickingEnabled=false;s.randomIntervalsEnabled=false;s.movementEnabled=false;s.breaksEnabled=false;s.clickVariationEnabled=false;s.timerEnabled=false;s.finalClickEnabled=true
            s.clickVariationRadius=3;s.movementMode = .fullScreen;s.movementDisplayID=42;s.timerMinutes=31;s.timerSeconds=26;s.finalButton = .left
            let data=try! JSONEncoder().encode(s)
            return (try! JSONDecoder().decode(ClickSettings.self,from:data)) == s && !String(data:data,encoding:.utf8)!.contains("Target")
        }
        test("00:31:26 is exactly 1886 seconds; invalid timer fields are rejected") {
            var s=ClickSettings();s.timerMinutes=31;s.timerSeconds=26;s.timerEnabled=true
            guard s.timerDuration == 1886 && s.validationError == nil else { return false }
            s.timerMinutes=60;return s.validationError != nil
        }
        test("Fixed intervals use the existing basic interval without random timing draws") {
            var timingDraws=0
            let (e,m,c,s)=setup({ $0.randomIntervalsEnabled=false },random:{ r in if r.lowerBound == 0.3 { timingDraws += 1 };return (r.lowerBound+r.upperBound)/2 })
            e.start(at:m.position,settings:s);c.advance(0.59);let first=m.downs.count;c.advance(0.03)
            return first == 1 && m.downs.count == 2 && timingDraws == 0
        }
        test("Movement switch skips stored 100 percent movement") {
            let (e,m,c,s)=setup({ $0.movementEnabled=false;$0.movementProbability=1 })
            let target=m.position;e.start(at:target,settings:s);c.advance(2)
            return m.downs.count>2 && m.events.allSatisfy { $0.1 == target }
        }
        test("Break switch skips stored 100 percent breaks") {
            let (e,m,c,s)=setup({ $0.breaksEnabled=false;$0.breakProbability=1 })
            e.start(at:m.position,settings:s);c.advance(3);return e.active && e.status != .takingBreak && m.downs.count>4
        }
        test("Movement-only local session runs without click acknowledgement") {
            let (e,m,c,s)=setup({ $0.regularClickingEnabled=false;$0.movementProbability=1 })
            e.start(at:m.position,settings:s);c.advance(1)
            return e.status == .running && m.downs.isEmpty && m.events.count>11
        }
        test("Full-screen movement-only respects selected display, target and cycle pacing") {
            let (e,m,c,s)=setup({ $0.regularClickingEnabled=false;$0.movementMode = .fullScreen;$0.largeMovementProbability=1;$0.movementDisplayID=42;$0.movementProbability=1;$0.minInterval=2;$0.maxInterval=2 })
            let anchor=m.position;e.start(at:anchor,settings:s);c.advance(2.05);let n=m.events.count;c.advance(0.05)
            return e.status == .running && m.downs.isEmpty && e.target == anchor && m.events.count == n && n >= 40 && m.position == anchor && m.events.allSatisfy { m.displayBounds(for:42)!.contains($0.1) }
        }
        test("Full-screen movement returns to saved target before regular click") {
            let (e,m,c,s)=setup({ $0.movementMode = .fullScreen;$0.largeMovementProbability=1;$0.movementProbability=1 })
            let anchor=m.position;e.start(at:anchor,settings:s);c.advance(2.1)
            guard let i=m.events.firstIndex(where: { $0.0.hasPrefix("down") }) else { return false }
            return m.events[i-1].0 == "move" && m.events[i-1].1 == anchor && m.events[i].1 == anchor && e.target == anchor
        }
        test("Unavailable selected display prevents a session") {
            let (e,m,c,s)=setup({ $0.movementMode = .fullScreen;$0.largeMovementProbability=1;$0.movementDisplayID=999 })
            e.start(at:m.position,settings:s);c.advance(5);return !e.active && m.events.isEmpty
        }
        test("Full-screen motion halts at protected path with no click") {
            let (e,m,c,s)=setup({ $0.movementMode = .fullScreen;$0.largeMovementProbability=1;$0.movementProbability=1 })
            m.forbidden=[CGRect(x:290,y:0,width:10,height:600)]
            e.start(at:m.position,settings:s);c.advance(5)
            return e.status == .paused && m.downs.isEmpty && m.events.allSatisfy { m.allows($0.1) }
        }
        test("Variation stays around original target and pairs exact down/up coordinates") {
            var draw=0
            let (e,m,c,s)=setup({ $0.clickVariationEnabled=true;$0.clickVariationRadius=2 },random:{ r in draw += 1;return r.lowerBound+(r.upperBound-r.lowerBound)*Double(draw%11)/11 })
            let anchor=m.position;e.start(at:anchor,settings:s);c.advance(10);e.stop()
            var held:CGPoint?;var paired=0
            for event in m.events {
                if event.0.hasPrefix("down") { held=event.1 }
                if event.0.hasPrefix("up") || event.0.hasPrefix("release") { if held != event.1 { return false };held=nil;paired += 1 }
            }
            return paired>10 && e.target == anchor && Set(m.downs.map { "\($0.1.x),\($0.1.y)" }).count>3 && m.downs.allSatisfy { hypot($0.1.x-anchor.x,$0.1.y-anchor.y)<=2.00001 }
        }
        test("Zero radius and disabled variation both produce exact original clicks") {
            for enabled in [false,true] {
                let (e,m,c,s)=setup({ $0.clickVariationEnabled=enabled;$0.clickVariationRadius=enabled ? 0 : 7 })
                let p=m.position;e.start(at:p,settings:s);c.advance(2)
                if !m.downs.allSatisfy({ $0.1 == p }) { return false }
            };return true
        }
        test("Variation cannot escape display bounds or protected targets") {
            let (e,m,c,s)=setup({ $0.clickVariationEnabled=true;$0.clickVariationRadius=10 })
            m.position=CGPoint(x:0.1,y:0.1);m.forbidden=[CGRect(x:1,y:0,width:20,height:20)]
            e.start(at:m.position,settings:s);c.advance(2)
            return m.downs.count>2 && m.downs.allSatisfy { m.allows($0.1) && m.displayBounds(containing:$0.1) != nil }
        }
        test("IOP latch independently suppresses repeat and requires all releases") {
            var capture=ChordLatch(keys:[34,31,35]),session=ChordLatch();var captures=0;var toggles=0
            for key:UInt16 in [34,31,35] { if capture.update(code:key,down:true) { captures += 1 };if session.update(code:key,down:true) { toggles += 1 } }
            for _ in 0..<5 { if capture.update(code:35,down:true,repeated:true) { captures += 1 } }
            _=capture.update(code:34,down:false);if capture.update(code:34,down:true) { captures += 1 }
            for key:UInt16 in [34,31,35] { _=capture.update(code:key,down:false) }
            for key:UInt16 in [35,31,34] { if capture.update(code:key,down:true) { captures += 1 } }
            return captures == 2 && toggles == 0
        }
        test("Final target capture never clicks, starts, or overwrites regular target") {
            let (e,m,c,s)=setup();let p=m.position;e.start(at:p,settings:s);e.stop();let n=m.events.count
            let saved=e.captureFinalTarget(CGPoint(x:600,y:400));c.advance(5)
            return saved && e.target == p && e.finalTarget == CGPoint(x:600,y:400) && e.status == .stopped && m.events.count == n
        }
        test("Capturing a final target during a run pauses and freezes the timer") {
            let (e,m,c,s)=setup({ $0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=2 })
            e.start(at:m.position,settings:s);c.advance(0.4);_=e.captureFinalTarget(CGPoint(x:600,y:400));let remaining=e.remainingDuration;c.advance(5)
            return e.status == .paused && e.remainingDuration == remaining
        }
        test("Enabled final click requires a valid final target before starting") {
            let (e,m,c,s)=setup({ $0.timerEnabled=true;$0.finalClickEnabled=true })
            e.start(at:m.position,settings:s);c.advance(5);return e.status == .stopped && m.events.isEmpty
        }
        test("Timer-only session needs no regular target or click acknowledgement") {
            let (e,m,c,s)=setup({ $0.regularClickingEnabled=false;$0.movementEnabled=false;$0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1 })
            e.start(settings:s);let running=e.status == .running;c.advance(1.1)
            return running && e.status == .stopped && e.remainingDuration == 0 && m.events.isEmpty
        }
        test("Pause freezes monotonic countdown; resume retains remaining time") {
            let (e,m,c,s)=setup({ $0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=2 })
            e.start(at:m.position,settings:s);c.advance(0.4);e.pause();let remaining=e.remainingDuration!;c.advance(30)
            guard abs(remaining-1.6)<0.0001 && e.remainingDuration == remaining else { return false }
            e.start(at:CGPoint(x:300,y:250),settings:s);c.advance(1.59);let running=e.active;c.advance(0.02)
            return running && e.status == .stopped
        }
        test("Manual Stop resets the next timer session to its full duration") {
            let (e,m,c,s)=setup({ $0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=2 })
            e.start(at:m.position,settings:s);c.advance(1.5);e.stop();e.start(settings:s);c.advance(1)
            return e.active && abs(e.remainingDuration!-1)<0.0001
        }
        test("Changing timer duration while paused starts the new full duration") {
            let (e,m,c,original)=setup({ $0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=2 });var s=original
            e.start(at:m.position,settings:s);c.advance(1);e.pause();s.timerSeconds=4;e.start(settings:s)
            return e.remainingDuration == 4
        }
        test("Disabled timer ignores retained final-click switch and runs indefinitely") {
            let (e,m,c,s)=setup({ $0.timerEnabled=false;$0.finalClickEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1 })
            e.start(at:m.position,settings:s);c.advance(8);return e.active && e.remainingDuration == nil && m.downs.count>10
        }
        test("Expiry interrupts a long interval and sends exactly one exact final pair") {
            let (e,m,c,s)=setup({ $0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.finalClickEnabled=true;$0.finalButton = .left;$0.clickVariationEnabled=true;$0.clickVariationRadius=10;$0.minInterval=100;$0.maxInterval=100 })
            let final=CGPoint(x:650,y:450);_=e.captureFinalTarget(final);e.start(at:m.position,settings:s);c.advance(1.1);e.confirmDelivery();let n=m.events.count;c.advance(200,forceCancelled:true)
            return e.status == .stopped && m.events.count == n && m.downs.filter { $0.0 == "down-Left click" }.map { $0.1 } == [final] && m.events.filter { $0.0 == "up-Left click" }.map { $0.1 } == [final]
        }
        test("Final click works independently with regular clicking and movement off") {
            let (e,m,c,s)=setup({ $0.regularClickingEnabled=false;$0.movementEnabled=false;$0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.finalClickEnabled=true })
            let final=CGPoint(x:650,y:450);_=e.captureFinalTarget(final);e.start(settings:s);c.advance(1.1);e.confirmDelivery();c.advance(20)
            return e.status == .stopped && m.downs.count == 1 && m.downs[0].1 == final
        }
        test("Automatic breaks count toward timer expiry") {
            let (e,m,c,s)=setup({ $0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.breakProbability=1;$0.minBreak=60;$0.maxBreak=60 })
            e.start(at:m.position,settings:s);c.advance(0.7);let onBreak=e.status == .takingBreak;c.advance(0.4);let n=m.events.count;c.advance(100,forceCancelled:true)
            return onBreak && e.status == .stopped && m.events.count == n
        }
        test("Expiry cancels in-progress full-screen movement before final click") {
            let (e,m,c,s)=setup({ $0.regularClickingEnabled=false;$0.movementMode = .fullScreen;$0.largeMovementProbability=1;$0.movementProbability=1;$0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.finalClickEnabled=true })
            let final=CGPoint(x:650,y:450);_=e.captureFinalTarget(final);e.start(at:m.position,settings:s);c.advance(1);let n=m.events.count;c.advance(0.1);e.confirmDelivery()
            return e.status == .stopped && m.downs.count == 1 && m.downs[0].1 == final && m.events.dropFirst(n).allSatisfy { $0.1 == final }
        }
        test("Expiry releases a held regular button before the final pair") {
            let (e,m,c,s)=setup({ $0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.finalClickEnabled=true;$0.finalButton = .left;$0.minInterval=0.84;$0.maxInterval=0.84 })
            let final=CGPoint(x:650,y:450);_=e.captureFinalTarget(final);e.start(at:m.position,settings:s);c.advance(1.1);e.confirmDelivery()
            guard let release=m.events.firstIndex(where: { $0.0 == "release-Right click" }),let last=m.events.firstIndex(where: { $0.0 == "down-Left click" }) else { return false }
            return release<last && m.held == nil && e.status == .stopped
        }
        test("No new regular button-down can begin after expiry") {
            let (e,m,c,s)=setup({ $0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.minInterval=0.85;$0.maxInterval=0.85 })
            e.start(at:m.position,settings:s);c.advance(2,forceCancelled:true)
            return e.status == .stopped && m.downs.count == 1
        }
        test("Pause, Stop, interruption and display change never trigger final click") {
            for action in 0..<4 {
                let (e,m,c,s)=setup({ $0.regularClickingEnabled=false;$0.movementEnabled=false;$0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.finalClickEnabled=true })
                _=e.captureFinalTarget(CGPoint(x:650,y:450));e.start(settings:s);c.advance(0.3)
                if action == 0 { e.pause() };if action == 1 { e.stop() };if action == 2 { m.available=false;e.checkEnvironment() };if action == 3 { e.clearTargets() }
                c.advance(100,forceCancelled:true);if !m.downs.isEmpty || e.active { return false }
            };return true
        }
        test("Invalidated final target stops with no substitution or retry") {
            let (e,m,c,s)=setup({ $0.regularClickingEnabled=false;$0.movementEnabled=false;$0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.finalClickEnabled=true })
            _=e.captureFinalTarget(CGPoint(x:650,y:450));e.start(settings:s);m.forbidden=[CGRect(x:600,y:400,width:100,height:100)];e.checkEnvironment();c.advance(100,forceCancelled:true)
            return e.status == .stopped && m.downs.isEmpty && e.detail.contains("final target")
        }
        test("A delayed timer wake cannot emit an unexpected final click") {
            let (e,m,c,s)=setup({ $0.regularClickingEnabled=false;$0.movementEnabled=false;$0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.finalClickEnabled=true })
            _=e.captureFinalTarget(CGPoint(x:650,y:450));e.start(settings:s);c.deliverLate(by:10);c.advance(100)
            return e.status == .stopped && m.events.isEmpty
        }
        test("Unconfirmed final delivery stops without retrying") {
            let (e,m,c,s)=setup({ $0.regularClickingEnabled=false;$0.movementEnabled=false;$0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.finalClickEnabled=true })
            _=e.captureFinalTarget(CGPoint(x:650,y:450));e.start(settings:s);c.advance(50)
            return e.status == .stopped && m.downs.count == 1 && e.detail.contains("unconfirmed")
        }
        test("Final posting error cancels all work without retry") {
            let (e,m,c,s)=setup({ $0.regularClickingEnabled=false;$0.movementEnabled=false;$0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.finalClickEnabled=true })
            _=e.captureFinalTarget(CGPoint(x:650,y:450));e.start(settings:s);m.failDown=true;c.advance(50)
            return e.status == .stopped && m.downs.isEmpty && e.detail.contains("not be retried")
        }
        test("Stop between final move and final down prevents the final click") {
            let (e,m,c,s)=setup({ $0.regularClickingEnabled=false;$0.movementEnabled=false;$0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.finalClickEnabled=true })
            _=e.captureFinalTarget(CGPoint(x:650,y:450));e.start(settings:s);c.advance(1.005);e.stop();c.advance(100,forceCancelled:true)
            return e.status == .stopped && m.downs.isEmpty
        }
        test("Stop during final hold releases it and leaves no pending actions") {
            let (e,m,c,s)=setup({ $0.regularClickingEnabled=false;$0.movementEnabled=false;$0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.finalClickEnabled=true })
            _=e.captureFinalTarget(CGPoint(x:650,y:450));e.start(settings:s);c.advance(1.025);e.stop();let n=m.events.count;c.advance(100,forceCancelled:true)
            return e.status == .stopped && m.downs.count == 1 && m.held == nil && m.events.count == n
        }
        test("Timer and motion keep only one scheduled continuation") {
            let (e,m,c,s)=setup({ $0.movementMode = .fullScreen;$0.largeMovementProbability=1;$0.movementProbability=1;$0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=3 })
            e.start(at:m.position,settings:s)
            for _ in 0..<300 { c.advance(0.01);if c.queued.filter({ !$0.1.cancelled }).count>1 { return false } }
            return true
        }
        movementChecks(test)
        travelClickChecks(test)
        print("\(count) checks, \(failures) failures.")
        if failures > 0 { exit(1) }
    }
}
