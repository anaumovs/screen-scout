import Foundation
import CoreGraphics
import ScoutClicker

private struct SecondaryRecord {
    let kind: String
    let point: CGPoint
    let time: Double
    let phase: String?
}

@MainActor private final class SecondaryRig {
    let mouse = FakeMouse(), clock = Clock()
    var engine: ClickEngine!
    var settings = ClickSettings()
    var records: [SecondaryRecord] = []
    let area = CGRect(x: 540, y: 340, width: 40, height: 40)
    let anchor = CGPoint(x: 200, y: 200)
    init(regular: Bool = false) {
        settings.regularClickingEnabled = regular
        settings.smallMovementEnabled = false; settings.largeMovementEnabled = false
        settings.breaksEnabled = false; settings.randomIntervalsEnabled = false
        settings.minInterval = 100; settings.maxInterval = 100
        settings.secondaryClickEnabled = true
        settings.secondaryMinInterval = 5; settings.secondaryMaxInterval = 5
        settings.movementDisplayIdentity = "test-display"
        settings.movementRegions = [MovementRegionProfile(displayIdentity: "test-display", referenceSize: CGSize(width: 800, height: 600), boxes: [MovementBox(rect: area, blocked: false, secondaryClick: true)])]
        engine = ClickEngine(output: mouse, scheduler: clock, random: { ($0.lowerBound + $0.upperBound) / 2 })
        mouse.observe = { [weak self] kind, point in
            guard let self else { return }
            self.records.append(SecondaryRecord(kind: kind, point: point, time: self.clock.now, phase: self.engine.movementPhase))
        }
    }
    func start() { engine.start(at: settings.regularClickingEnabled ? anchor : nil, settings: settings) }
    var secondaryDowns: [SecondaryRecord] { records.filter { $0.kind.hasPrefix("down") && area.contains($0.point) } }
    func untilReturn() {
        for _ in 0..<1500 {
            clock.advance(0.01)
            if !secondaryDowns.isEmpty && mouse.position == anchor && engine.movementPhase == nil && mouse.held == nil { return }
        }
    }
    func untilHeld() -> Bool {
        for _ in 0..<12000 {
            clock.advance(0.001)
            if mouse.held != nil && area.contains(mouse.heldPoint ?? .zero) { return true }
        }
        return false
    }
    func pairedWithoutDragging() -> Bool {
        var held: SecondaryRecord?
        for record in records {
            if record.kind == "move" && held != nil { return false }
            if record.kind.hasPrefix("down") { if held != nil { return false }; held = record }
            if record.kind.hasPrefix("up") || record.kind.hasPrefix("release") {
                guard let down = held, down.point == record.point else { return false }
                let prefix = record.kind.hasPrefix("up") ? 3 : 8
                guard down.kind.dropFirst(5) == record.kind.dropFirst(prefix) else { return false }
                held = nil
            }
        }
        return held == nil
    }
}

@MainActor func secondaryClickChecks(_ test: (String, () -> Bool) -> Void) {
    test("Secondary clicks default off with a five-to-ten-second interval; old settings retain their values") {
        var original = ClickSettings(); original.button = .left; original.minInterval = 0.9; original.maxInterval = 2.4
        original.largeMovementEnabled = true; original.largeMovementSpeed = 3; original.timerMinutes = 31
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        for key in ["secondaryClickEnabled", "secondaryMinInterval", "secondaryMaxInterval"] { object.removeValue(forKey: key) }
        let loaded = try! JSONDecoder().decode(ClickSettings.self, from: JSONSerialization.data(withJSONObject: object))
        return loaded == original && !loaded.secondaryClickEnabled && loaded.secondaryMinInterval == 5 && loaded.secondaryMaxInterval == 10
    }
    test("Existing red and green boxes decode without becoming secondary click areas") {
        for blocked in [false, true] {
            let original = MovementBox(rect: CGRect(x: 10, y: 20, width: 100, height: 80), blocked: blocked)
            var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
            object.removeValue(forKey: "secondaryClick")
            let loaded = try! JSONDecoder().decode(MovementBox.self, from: JSONSerialization.data(withJSONObject: object))
            if loaded != original || loaded.secondaryClick { return false }
        }
        return true
    }
    test("Secondary region, interval and disabled switch round-trip independently") {
        let r = SecondaryRig(); r.settings.secondaryClickEnabled = false
        r.settings.secondaryMinInterval = 8; r.settings.secondaryMaxInterval = 17
        return (try! JSONDecoder().decode(ClickSettings.self, from: JSONEncoder().encode(r.settings))) == r.settings
    }
    test("Secondary interval rejects zero, negative, reversed, excessive and nonfinite values") {
        for (low, high) in [(0.0, 10.0), (-1, 10), (10, 5), (5, 3601), (Double.infinity, Double.infinity), (Double.nan, 10)] {
            var s = ClickSettings(); s.secondaryMinInterval = low; s.secondaryMaxInterval = high
            if s.validationError == nil { return false }
        }
        return ClickSettings().validationError == nil
    }
    test("Purple boxes do not alter the original large-movement allowed domain") {
        let display = MovementDisplay(identity: "test-display", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let green = MovementBox(rect: CGRect(x: 100, y: 100, width: 200, height: 200), blocked: false)
        let purple = MovementBox(rect: CGRect(x: 540, y: 340, width: 40, height: 40), blocked: false, secondaryClick: true)
        let profile = MovementRegionProfile(displayIdentity: display.identity, referenceSize: display.bounds.size, boxes: [green, purple])
        return profile.domain(for: display)?.contains(CGPoint(x: 200, y: 200)) == true && profile.domain(for: display)?.contains(CGPoint(x: 560, y: 360)) == false && profile.secondaryDomain(for: display)?.contains(CGPoint(x: 400, y: 300)) == true && profile.secondaryClickArea(for: display) == purple.rect
    }
    test("Secondary display regions translate with display position and reject changed identity or size") {
        let r = SecondaryRig(), profile = r.settings.movementRegions[0]
        let shifted = MovementDisplay(identity: "test-display", bounds: CGRect(x: -800, y: 120, width: 800, height: 600))
        return profile.secondaryClickArea(for: shifted) == r.area.offsetBy(dx: -800, dy: 120) && profile.secondaryDomain(for: MovementDisplay(identity: "different", bounds: shifted.bounds)) == nil && profile.secondaryDomain(for: MovementDisplay(identity: "test-display", bounds: CGRect(x: 0, y: 0, width: 400, height: 300))) == nil
    }
    test("Disabled secondary feature leaves existing event sequence and timings unchanged") {
        var traces: [[SecondaryRecord]] = []
        for keepArea in [false, true] {
            let r = SecondaryRig(regular: true); r.settings.secondaryClickEnabled = false
            r.settings.minInterval = 0.4; r.settings.maxInterval = 0.4
            if !keepArea { r.settings.movementRegions = [] }
            r.start(); r.clock.advance(12); r.engine.stop(); traces.append(r.records)
        }
        return traces[0].count == traces[1].count && zip(traces[0], traces[1]).allSatisfy { $0.kind == $1.kind && $0.point == $1.point && abs($0.time - $1.time) < 0.000001 }
    }
    test("Secondary deadline wakes a long regular wait, clicks once in purple and returns to the unchanged FGH target") {
        let r = SecondaryRig(regular: true); r.start(); r.clock.advance(4.99)
        guard r.secondaryDowns.isEmpty && r.mouse.downs.count == 1 else { return false }
        r.untilReturn(); r.engine.stop()
        return r.secondaryDowns.count == 1 && r.secondaryDowns[0].time >= 5 && r.secondaryDowns[0].time < 9 && r.mouse.position == r.anchor && r.engine.target == r.anchor && r.pairedWithoutDragging()
    }
    test("Secondary-only session requires no FGH target and sends exactly one selected-button click per visit") {
        let r = SecondaryRig(); r.settings.button = .left; r.start(); r.untilReturn(); r.engine.stop()
        return r.engine.target == nil && r.secondaryDowns.count == 1 && r.mouse.downs.count == 1 && r.secondaryDowns[0].kind == "down-Left click" && r.mouse.position == r.anchor && r.pairedWithoutDragging()
    }
    test("Secondary outbound and return use many curved samples with no direct position jump") {
        let r = SecondaryRig(); r.start(); r.untilReturn(); r.engine.stop()
        let moves = r.records.filter { $0.kind == "move" }
        guard let down = r.secondaryDowns.first, moves.count > 30 else { return false }
        var previous = r.anchor
        for move in moves { if movementDistance(previous, move.point) > 15 { return false }; previous = move.point }
        let dx = down.point.x - r.anchor.x, dy = down.point.y - r.anchor.y, length = movementDistance(r.anchor, down.point)
        func bends(_ samples: [SecondaryRecord]) -> Bool {
            samples.contains { abs(dy * ($0.point.x - r.anchor.x) - dx * ($0.point.y - r.anchor.y)) / length > 5 }
        }
        return bends(moves.filter { $0.time < down.time }) && bends(moves.filter { $0.time > down.time }) && previous == r.anchor && r.mouse.downs.count == 1 && r.pairedWithoutDragging()
    }
    test("Secondary paths route around red blocks without green boxes restricting transit") {
        let r = SecondaryRig(), blocked = CGRect(x: 399, y: 100, width: 2, height: 350)
        r.settings.movementRegions[0].boxes.append(MovementBox(rect: blocked, blocked: true))
        r.settings.movementRegions[0].boxes.append(MovementBox(rect: CGRect(x: 100, y: 100, width: 200, height: 200), blocked: false))
        r.start(); r.untilReturn(); r.engine.stop()
        let domain = MovementDomain(bounds: CGRect(x: 0, y: 0, width: 800, height: 600), blocked: [blocked])
        var previous = r.anchor
        for record in r.records where record.kind == "move" {
            if !domain.permitsSegment(previous, record.point) { return false }; previous = record.point
        }
        return r.secondaryDowns.count == 1 && previous == r.anchor && r.pairedWithoutDragging()
    }
    test("An unreachable purple area never causes a teleport or click across a solid red barrier") {
        let r = SecondaryRig(); r.settings.movementRegions[0].boxes.append(MovementBox(rect: CGRect(x: 399, y: 0, width: 2, height: 600), blocked: true))
        r.start(); r.clock.advance(20); r.engine.stop()
        return r.records.isEmpty && r.mouse.position == r.anchor
    }
    test("A purple area fully covered by red cannot receive a click or cause movement") {
        let r = SecondaryRig(); r.settings.movementRegions[0].boxes.append(MovementBox(rect: r.area, blocked: true))
        r.start(); r.clock.advance(20); r.engine.stop()
        return r.records.isEmpty && r.mouse.position == r.anchor
    }
    test("Missing, stale or unavailable secondary region cannot send secondary-only input") {
        for scenario in 0..<4 {
            let r = SecondaryRig()
            if scenario == 0 { r.settings.movementRegions = [] }
            if scenario == 1 { r.settings.movementRegions[0].displayIdentity = "stale" }
            if scenario == 2 { r.settings.movementRegions[0].referenceSize = CGSize(width: 400, height: 300) }
            if scenario == 3 { r.settings.movementDisplayID = 999 }
            r.start(); r.clock.advance(20); r.engine.stop()
            if !r.records.isEmpty { return false }
        }
        return true
    }
    test("Pause freezes the remaining secondary interval instead of counting paused time") {
        let r = SecondaryRig(); r.start(); r.clock.advance(4); r.engine.pause()
        r.clock.advance(100, forceCancelled: true); guard r.records.isEmpty else { return false }
        r.engine.start(settings: r.settings); r.clock.advance(0.8)
        guard r.records.isEmpty else { return false }
        r.clock.advance(0.4)
        return !r.records.isEmpty && r.secondaryDowns.isEmpty
    }
    test("Stop resets the secondary interval for a fresh start") {
        let r = SecondaryRig(); r.start(); r.clock.advance(4); r.engine.stop(); r.start(); r.clock.advance(4.8)
        guard r.records.isEmpty else { return false }
        r.clock.advance(0.4)
        return !r.records.isEmpty
    }
    test("Secondary visits wait until an existing break completes") {
        let r = SecondaryRig(regular: true)
        r.settings.minInterval = 0.5; r.settings.maxInterval = 0.5
        r.settings.breaksEnabled = true; r.settings.breakProbability = 1
        r.settings.minBreak = 10; r.settings.maxBreak = 10
        r.start(); r.clock.advance(6)
        guard r.engine.status == .takingBreak && r.secondaryDowns.isEmpty && !r.records.contains(where: { $0.phase?.hasPrefix("Secondary") == true }) else { return false }
        r.untilReturn(); r.engine.stop()
        return r.secondaryDowns.count == 1 && r.secondaryDowns[0].time >= 10.5 && r.pairedWithoutDragging()
    }
    test("Pause and Stop during secondary outward movement prevent all later input") {
        for shouldStop in [false, true] {
            let r = SecondaryRig(); r.start(); r.clock.advance(5.25)
            guard r.engine.movementPhase == "Secondary outward" && !r.records.isEmpty && r.secondaryDowns.isEmpty else { return false }
            if shouldStop { r.engine.stop() } else { r.engine.pause() }
            let count = r.records.count; r.clock.advance(100, forceCancelled: true)
            if r.engine.active || r.records.count != count || !r.mouse.downs.isEmpty { return false }
        }
        return true
    }
    test("Manual displacement during a secondary trip pauses without jumping back or clicking") {
        let r = SecondaryRig(); r.start(); r.clock.advance(5.25)
        guard r.engine.movementPhase == "Secondary outward" && !r.records.isEmpty else { return false }
        let manual = CGPoint(x: 100, y: 500)
        r.mouse.position = manual
        let count = r.records.count; r.clock.advance(10, forceCancelled: true)
        return r.engine.status == .paused && r.mouse.position == manual && r.records.count == count && r.mouse.downs.isEmpty
    }
    test("Stop from the arrival callback prevents secondary button-down") {
        let r = SecondaryRig(); var stopped = false
        r.engine.changed = {
            if !stopped && r.engine.movementPhase == "Secondary click" {
                stopped = true; r.engine.stop()
            }
        }
        r.start(); r.clock.advance(10, forceCancelled: true)
        return stopped && r.engine.status == .stopped && r.mouse.downs.isEmpty && r.mouse.held == nil && r.clock.queued.filter({ !$0.1.cancelled }).isEmpty
    }
    test("Stop from the completed-return callback cannot queue another continuation") {
        let r = SecondaryRig(); var sawReturn = false, stopped = false
        r.engine.changed = {
            if r.engine.movementPhase == "Secondary return" { sawReturn = true }
            if sawReturn && !stopped && r.engine.movementPhase == nil {
                stopped = true; r.engine.stop()
            }
        }
        r.start()
        for _ in 0..<1500 { r.clock.advance(0.01); if stopped { break } }
        guard stopped && r.clock.queued.filter({ !$0.1.cancelled }).isEmpty else { return false }
        let count = r.records.count; r.clock.advance(100, forceCancelled: true)
        return r.engine.status == .stopped && r.records.count == count && r.secondaryDowns.count == 1 && r.mouse.position == r.anchor && r.pairedWithoutDragging()
    }
    test("Pause, Stop and permission loss release a secondary hold and cancel stale continuations") {
        for action in 0..<3 {
            let r = SecondaryRig(); r.start(); guard r.untilHeld() else { return false }
            if action == 0 { r.engine.pause() }
            if action == 1 { r.engine.stop() }
            if action == 2 { r.mouse.available = false; r.engine.checkEnvironment() }
            let count = r.records.count; r.clock.advance(100, forceCancelled: true)
            if r.engine.active || r.mouse.held != nil || r.records.count != count || !r.pairedWithoutDragging() { return false }
        }
        return true
    }
    test("Session timer expiry during secondary travel cancels movement before its click") {
        let r = SecondaryRig(); r.settings.timerEnabled = true; r.settings.timerMinutes = 0; r.settings.timerSeconds = 6
        r.settings.movementRegions[0].boxes[0].rect = CGRect(x: 700, y: 500, width: 40, height: 40)
        r.start(); r.clock.advance(6.1); let count = r.records.count; r.clock.advance(100, forceCancelled: true)
        return r.engine.status == .stopped && r.mouse.downs.isEmpty && count > 5 && r.records.count == count && r.mouse.held == nil
    }
    test("Secondary visits share one scheduled continuation and never replay a backlog after a delayed wake") {
        let r = SecondaryRig(); r.start(); r.clock.advance(4.9); r.clock.deliverLate(by: 30)
        for _ in 0..<1200 {
            r.clock.advance(0.01)
            if r.clock.queued.filter({ !$0.1.cancelled }).count > 1 { return false }
        }
        r.engine.stop()
        let downs = r.secondaryDowns
        return downs.count >= 1 && downs.count <= 2 && zip(downs, downs.dropFirst()).allSatisfy { $1.time - $0.time >= 5 } && r.pairedWithoutDragging()
    }
}
