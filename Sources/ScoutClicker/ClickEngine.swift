import Foundation
import CoreGraphics

public enum ClickStatus: String { case stopped = "Stopped", paused = "Paused", starting = "Starting…", running = "Running", takingBreak = "Taking a break", finishing = "Final click…" }

@MainActor public protocol MouseOutput: AnyObject {
    var available: Bool { get }
    var failureReason: String { get }
    func currentPosition() -> CGPoint?
    func movementDisplay(for id: UInt32) -> MovementDisplay?
    func displayBounds(for id: UInt32) -> CGRect?
    func displayBounds(containing point: CGPoint) -> CGRect?
    func allows(_ point: CGPoint) -> Bool
    func move(to point: CGPoint) throws
    func down(_ button: ClickButton, at point: CGPoint) throws
    func up(_ button: ClickButton, at point: CGPoint) throws
    func release()
}
@MainActor public protocol PendingAction: AnyObject { func cancel() }
@MainActor public protocol ActionScheduler: AnyObject {
    var now: TimeInterval { get }
    func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PendingAction
}
@MainActor public final class MainScheduler: ActionScheduler {
    private final class Token: PendingAction {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> PendingAction {
        let item = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return Token(item)
    }
}

/// One serialized mouse chain, with timer expiry as a deadline on that same chain.
/// Every continuation checks the deadline before emitting more regular input.
@MainActor public final class ClickEngine {
    public private(set) var status: ClickStatus = .stopped
    public private(set) var target: CGPoint?
    public private(set) var finalTarget: CGPoint?
    public private(set) var detail = "Position your mouse over the target, then press F + G + H."
    public private(set) var settings = ClickSettings()
    public private(set) var clicksPosted = 0
    public private(set) var breakEndsAt: TimeInterval?
    public var changed: (() -> Void)?
    private let output: MouseOutput
    private let scheduler: ActionScheduler
    private let random: (ClosedRange<Double>) -> Double
    private var pending: PendingAction?
    private var generation: UInt64 = 0
    private var delivered = false
    private var clickBegan = 0.0
    private var cycleBegan = 0.0
    private var clickPoint: CGPoint?
    private var nextRegularClickAt: TimeInterval?
    private var nextSecondaryAt: TimeInterval?
    private var frozenSecondaryRemaining: TimeInterval?
    private var usesTravelCadence: Bool {
        settings.regularClickingEnabled && ((settings.smallMovementEnabled && settings.smallClickWhileMoving) ||
            (settings.largeMovementEnabled && settings.largeClickWhileMoving))
    }
    public private(set) var movementNote: String?
    public private(set) var movementPhase: String?
    private var deadline: TimeInterval?
    private var frozenRemaining: TimeInterval?
    private var finalAttempted = false
    private var awaitingFinalDelivery = false
    public var active: Bool { [.starting, .running, .takingBreak, .finishing].contains(status) }
    public var remainingDuration: TimeInterval? {
        if let deadline { return max(0, deadline - scheduler.now) }
        return frozenRemaining
    }
    public init(output: MouseOutput, scheduler: ActionScheduler, random: @escaping (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) {
        self.output = output; self.scheduler = scheduler; self.random = random
    }
    @discardableResult public func captureFinalTarget(_ point: CGPoint) -> Bool {
        guard output.allows(point) else {
            if active { pause("Final target is invalid. Session paused; set it outside Screen Scout with I + O + P.") }
            else { detail = "Final target is invalid. Set it outside Screen Scout with I + O + P."; changed?() }
            return false
        }
        if active { pause("Final target changed. Resume explicitly to continue.") }
        finalTarget = point; changed?(); return true
    }
    public func start(at position: CGPoint? = nil, settings: ClickSettings) {
        let resume = status == .paused && settings.timerEnabled && self.settings.timerEnabled && settings.timerDuration == self.settings.timerDuration
        let remaining = resume ? frozenRemaining : nil
        let resumeSecondary = status == .paused && settings.secondaryClickEnabled && self.settings.secondaryClickEnabled &&
            settings.secondaryMinInterval == self.settings.secondaryMinInterval && settings.secondaryMaxInterval == self.settings.secondaryMaxInterval &&
            settings.movementDisplayIdentity == self.settings.movementDisplayIdentity && settings.movementRegions == self.settings.movementRegions
        let secondaryRemaining = resumeSecondary ? frozenSecondaryRemaining : nil
        cancelPending(); output.release(); deadline = nil; delivered = false
        nextSecondaryAt = nil; frozenSecondaryRemaining = nil
        guard settings.validationError == nil else { stop(settings.validationError!); return }
        guard output.available else { pause(output.failureReason); return }
        guard settings.regularClickingEnabled || settings.movementEnabled || settings.timerEnabled || settings.secondaryClickEnabled else { stop("Enable clicking, movement, or the session timer before starting."); return }
        let candidate = position ?? target
        if settings.needsRegularTarget || position != nil {
            guard let candidate, output.allows(candidate) else { pause("Set a target on an active display, outside Screen Scout's visible controls."); return }
        }
        if settings.finalClickEffective {
            guard let finalTarget, output.allows(finalTarget) else { stop("Set a valid final target with I + O + P before starting."); return }
        }
        if settings.largeMovementEnabled && output.displayBounds(for: settings.movementDisplayID) == nil {
            stop("The selected movement display is unavailable. Choose an active display."); return
        }
        if settings.secondaryClickEnabled {
            guard let display = output.movementDisplay(for: settings.movementDisplayID),
                  settings.movementDisplayIdentity == nil || settings.movementDisplayIdentity == display.identity,
                  let profile = settings.movementRegions.first(where: { $0.displayIdentity == display.identity }),
                  profile.secondaryDomain(for: display) != nil else {
                stop("Draw a valid purple secondary click area on the selected display before starting."); return
            }
        }
        self.settings = settings; target = candidate; breakEndsAt = nil
        finalAttempted = false; awaitingFinalDelivery = false; clickPoint = nil
        nextRegularClickAt = usesTravelCadence ? scheduler.now + 0.135 : nil
        if settings.secondaryClickEnabled { nextSecondaryAt = scheduler.now + (secondaryRemaining ?? random(settings.secondaryMinInterval...settings.secondaryMaxInterval)) }
        frozenRemaining = settings.timerEnabled ? (remaining ?? settings.timerDuration) : nil
        if let frozenRemaining { deadline = scheduler.now + frozenRemaining }
        status = settings.regularClickingEnabled ? .starting : .running
        detail = settings.regularClickingEnabled ? "Waiting for macOS to confirm the first click in its event stream." : "Session running. Regular clicking is off."
        changed?()
        schedule(0.12) { $0.prepareCycle(allowBreak: false) }
    }
    public func pause(_ reason: String = "Paused. F + G + H captures a new regular target and resumes.") {
        if status == .finishing { stop("Final click interrupted; it will not be retried."); return }
        frozenRemaining = remainingDuration; deadline = nil
        frozenSecondaryRemaining = nextSecondaryAt.map { max(0, $0 - scheduler.now) }; nextSecondaryAt = nil
        cancelPending(); output.release(); breakEndsAt = nil; clickPoint = nil
        status = .paused; detail = reason; changed?()
    }
    public func stop(_ reason: String = "Stopped. No clicks, movement, timer, or breaks are queued.") {
        cancelPending(); output.release(); deadline = nil; frozenRemaining = nil
        nextSecondaryAt = nil; frozenSecondaryRemaining = nil
        breakEndsAt = nil; clickPoint = nil; awaitingFinalDelivery = false
        status = .stopped; detail = reason; changed?()
    }
    public func confirmDelivery() {
        guard active else { return }
        if status == .finishing {
            if awaitingFinalDelivery { complete("Timer complete. One exact final click delivered; session stopped.") }
            return
        }
        delivered = true
        if status == .starting { status = .running; detail = usesTravelCadence ? "Clicking along enabled movement paths and at the saved target. Manual mouse movement does not pause." : "Clicking near the saved target. Manual mouse movement does not pause."; changed?() }
    }
    public func clearTarget() { stop(); target = nil; changed?() }
    public func clearTargets() { clearTarget(); finalTarget = nil; changed?() }
    /// Also called by the UI's heartbeat, including during long intervals/breaks.
    public func checkEnvironment() {
        guard active else { return }
        if !output.available { pause(output.failureReason); return }
        if settings.finalClickEffective && (finalTarget == nil || !output.allows(finalTarget!)) {
            stop("The final target is no longer valid. No final click will be sent; set it again with I + O + P."); return
        }
        if settings.needsRegularTarget && (target == nil || !output.allows(target!)) {
            pause("The regular target is unavailable or covered by Screen Scout. Reposition and restart.")
        }
    }
    private func cancelPending() { nextRegularClickAt = nil; movementPhase = nil; generation &+= 1; pending?.cancel(); pending = nil }
    private func schedule(_ delay: Double, _ action: @escaping (ClickEngine) -> Void) {
        let token = generation
        let wait = deadline.map { min(max(0, delay), max(0, $0 - scheduler.now)) } ?? max(0, delay)
        pending?.cancel()
        pending = scheduler.schedule(after: wait) { [weak self] in
            guard let self, self.generation == token, self.active else { return }
            self.pending = nil
            self.checkEnvironment()
            guard self.active else { return }
            if let deadline = self.deadline, self.scheduler.now >= deadline {
                // A suspended/stalled app must never fire a late final action on wake.
                guard self.scheduler.now - deadline < 0.75 else { self.stop("Timer completion was interrupted. Final click skipped; restart explicitly."); return }
                self.expire(); return
            }
            action(self)
        }
    }
    private func prepareCycle(allowBreak: Bool) {
        if settings.secondaryClickEnabled, let nextSecondaryAt, scheduler.now >= nextSecondaryAt {
            secondaryVisit { $0.prepareCycle(allowBreak: allowBreak) }; return
        }
        if allowBreak && settings.breaksEnabled && random(0...1) < settings.breakProbability {
            let duration = random(settings.minBreak...settings.maxBreak)
            status = .takingBreak; breakEndsAt = scheduler.now + duration
            detail = "Resuming automatically after a \(String(format: "%.1f", duration))-second break."; changed?()
            schedule(duration) { engine in
                engine.breakEndsAt = nil
                engine.status = (!engine.settings.regularClickingEnabled || engine.delivered) ? .running : .starting
                engine.changed?(); engine.prepareCycle(allowBreak: false)
            }
            return
        }
        cycleBegan = scheduler.now
        movementNote = nil; movementPhase = nil
        clickPoint = sampleClickPoint()
        let small = settings.smallMovementEnabled && random(0...1) < settings.movementProbability
        let large = settings.largeMovementEnabled && random(0...1) < settings.largeMovementProbability
        if small && settings.movementRadius > 0 {
            smallExcursion { engine in
                if large { engine.largeExcursion() } else { engine.afterMovement() }
            }
        } else if large { largeExcursion() } else { afterMovement() }
    }
    private func sampleClickPoint() -> CGPoint? {
        guard settings.regularClickingEnabled, let target else { return nil }
        if settings.clickVariationEnabled && settings.clickVariationRadius > 0,
           let bounds = output.displayBounds(containing: target) {
            // Exactly one fresh area-uniform coordinate for this entire cycle.
            for _ in 0..<24 {
                let angle = random(0...(2 * .pi)), radius = sqrt(random(0...1)) * settings.clickVariationRadius
                let candidate = CGPoint(x: target.x + cos(angle) * radius, y: target.y + sin(angle) * radius)
                if bounds.contains(candidate) && output.allows(candidate) { return candidate }
            }
        }
        return target
    }
    private func skipMovement(_ reason: String, completion: (ClickEngine) -> Void) {
        movementNote = reason; movementPhase = nil; changed?(); completion(self)
    }
    private func smallExcursion(completion: @escaping (ClickEngine) -> Void) {
        guard let start = output.currentPosition(), let bounds = output.displayBounds(containing: start) else {
            skipMovement("Small movement skipped: pointer is off-display.", completion: completion); return
        }
        let anchor = target ?? start, back = clickPoint ?? target ?? start
        let domain = MovementDomain(bounds: bounds.insetBy(dx: 0.001, dy: 0.001))
        for _ in 0..<12 {
            let angle = random(0...(2 * .pi)), radius = random(0...settings.movementRadius)
            let destination = CGPoint(x: anchor.x + cos(angle)*radius, y: anchor.y + sin(angle)*radius)
            guard output.allows(destination), let outward = CurvedMovement.plan(from: start, to: destination, domain: domain, random: random),
                  let inward = CurvedMovement.plan(from: destination, to: back, domain: domain, random: random) else { continue }
            movementPhase = "Small outward"; changed?()
            schedule(0) { $0.movePath(outward.points, index: 0, domain: nil, expected: outward.curves[0].a, permitClicks: $0.settings.smallClickWhileMoving, completion: { engine in
                engine.movementPhase = "Small return"; engine.changed?()
                engine.movePath(inward.points, index: 0, domain: nil, expected: inward.curves[0].a, permitClicks: engine.settings.smallClickWhileMoving, completion: completion)
            }) }; return
        }
        skipMovement("Small movement skipped: no valid curved path on the current display.", completion: completion)
    }
    private func largeExcursion() {
        guard let display = output.movementDisplay(for: settings.movementDisplayID) else {
            skipMovement("Large movement skipped: selected display is unavailable.") { $0.afterMovement() }; return
        }
        if let identity = settings.movementDisplayIdentity, identity != display.identity {
            skipMovement("Large movement skipped: display identity changed. Select the intended display and edit its regions.") { $0.afterMovement() }; return
        }
        let profile = settings.movementRegions.first { $0.displayIdentity == display.identity }
        let domain: MovementDomain
        if let profile {
            guard let valid = profile.domain(for: display) else {
                skipMovement("Large movement skipped: display size or region data changed. Correct and save its regions.") { $0.afterMovement() }; return
            }
            domain = valid
        } else { domain = MovementDomain(bounds: display.bounds.insetBy(dx: 0.001, dy: 0.001)) }
        guard let start = output.currentPosition(), domain.contains(start) else {
            skipMovement("Large movement skipped: current pointer is outside the permitted regions.") { $0.afterMovement() }; return
        }
        let back = clickPoint ?? target ?? start
        guard domain.contains(back) else {
            skipMovement("Large movement skipped: required return position is outside the permitted regions.") { $0.afterMovement() }; return
        }
        let planningLimit = ProcessInfo.processInfo.systemUptime + 0.06
        let areas = domain.allowed.isEmpty ? [domain.bounds] : domain.allowed
        for _ in 0..<12 {
            if ProcessInfo.processInfo.systemUptime > planningLimit { break }
            let area = areas[min(areas.count-1, Int(random(0...Double(areas.count))))]
            let destination = CGPoint(x: random(area.minX...area.maxX), y: random(area.minY...area.maxY))
            guard domain.contains(destination), output.allows(destination),
                  let outward = CurvedMovement.plan(from: start, to: destination, domain: domain, random: random),
                  let inward = CurvedMovement.plan(from: destination, to: back, domain: domain, random: random) else { continue }
            movementPhase = "Large outward"; changed?()
            schedule(0) { $0.movePath(outward.points, index: 0, domain: domain, expected: outward.curves[0].a, stepInterval: 0.018 / $0.settings.largeMovementSpeed, permitClicks: $0.settings.largeClickWhileMoving, completion: { engine in
                engine.movementPhase = "Large return"; engine.changed?()
                engine.movePath(inward.points, index: 0, domain: domain, expected: inward.curves[0].a, stepInterval: 0.018 / engine.settings.largeMovementSpeed, permitClicks: engine.settings.largeClickWhileMoving) { $0.afterMovement() }
            }) }; return
        }
        skipMovement("Large movement skipped: no connected, certifiable curved route after bounded planning attempts.") { $0.afterMovement() }
    }
    /// Animation and click deadlines compete for the SAME pending continuation.
    /// Every spatial sample is retained at every speed; a click freezes playback
    /// until its matching up, then shifts only animation time by the hold duration.
    private func movePath(_ path: [CGPoint], index: Int, domain: MovementDomain?, expected: CGPoint,
                          stepInterval: Double = 0.018, permitClicks: Bool, frameDue: TimeInterval? = nil,
                          completion: @escaping (ClickEngine) -> Void) {
        let due = frameDue ?? scheduler.now
        if index >= path.count && scheduler.now >= due { completion(self); return }
        guard let current = output.currentPosition() else {
            skipMovement("Movement skipped: the current pointer position is unavailable.") { $0.afterMovement() }; return
        }
        let nextPoint = index < path.count ? path[index] : expected
        if let domain, !domain.permitsSegment(current, nextPoint) {
            skipMovement("Large movement skipped: pointer moved across a region boundary. Saved targets are unchanged.") { $0.afterMovement() }; return
        }
        let clicksAllowed = permitClicks && settings.regularClickingEnabled
        if clicksAllowed, let clickDue = nextRegularClickAt, clickDue <= scheduler.now,
           movementDistance(current, expected) > 0.01 {
            // Do not outrun an overdue click while WindowServer is processing a
            // fast move. Rejoin the last certified sample after manual movement,
            // then let macOS settle there before rereading the actual coordinate.
            if let domain, !domain.permitsSegment(current, expected) {
                skipMovement("Large movement skipped: the actual pointer cannot safely rejoin its path.") { $0.afterMovement() }; return
            }
            do { try output.move(to: expected) }
            catch { pause(error.localizedDescription); return }
            schedule(0.004) {
                $0.movePath(path, index: index, domain: domain, expected: expected,
                            stepInterval: stepInterval, permitClicks: permitClicks, frameDue: due, completion: completion)
            }
            return
        }
        if clicksAllowed, let clickDue = nextRegularClickAt, clickDue <= scheduler.now,
           movementDistance(current, expected) <= 0.01, output.allows(current), domain?.contains(current) != false {
            // Read the actual cursor immediately before down. A manually displaced
            // cursor must first rejoin a checked path sample; it is never a travel target.
            let heldSince = scheduler.now
            regularClick(at: current) { engine in
                let heldFor = engine.scheduler.now - heldSince
                engine.movePath(path, index: index, domain: domain, expected: expected,
                                stepInterval: stepInterval, permitClicks: permitClicks,
                                frameDue: due + heldFor, completion: completion)
            }
            return
        }
        if scheduler.now < due {
            var wake = due
            if clicksAllowed, let clickDue = nextRegularClickAt, clickDue > scheduler.now { wake = min(wake, clickDue) }
            schedule(wake - scheduler.now) {
                $0.movePath(path, index: index, domain: domain, expected: expected,
                            stepInterval: stepInterval, permitClicks: permitClicks, frameDue: due, completion: completion)
            }
            return
        }
        guard index < path.count else { completion(self); return }
        guard output.allows(nextPoint) else {
            pause("Movement path crossed an unavailable or protected area. No click was sent."); return
        }
        do { try output.move(to: nextPoint) }
        catch { pause(error.localizedDescription); return }
        let nextFrame = scheduler.now + stepInterval
        var wake = nextFrame
        if clicksAllowed, let clickDue = nextRegularClickAt {
            // An overdue deadline after manual displacement waits one animation
            // step, allowing the posted position to reach macOS before revalidation.
            if clickDue > scheduler.now { wake = min(wake, clickDue) }
        }
        schedule(wake - scheduler.now) {
            $0.movePath(path, index: index + 1, domain: domain, expected: nextPoint,
                        stepInterval: stepInterval, permitClicks: permitClicks, frameDue: nextFrame, completion: completion)
        }
    }
    private func afterMovement() {
        movementPhase = nil; changed?()
        guard settings.regularClickingEnabled else { nextCycle(since: cycleBegan); return }
        guard let point = clickPoint else { stop("No regular target is saved."); return }
        do { try output.move(to: point) }
        catch { pause(error.localizedDescription); return }
        let wait = usesTravelCadence ? max(0, (nextRegularClickAt ?? scheduler.now + 0.015) - scheduler.now) : 0.015
        schedule(wait) { engine in
            // No arrival/turnaround bonus click: the same deadline follows a trip.
            engine.regularClick(at: point) { engine in
                engine.clickPoint = nil
                engine.nextCycle(since: engine.clickBegan)
            }
        }
    }
    private func clickInterval() -> Double {
        settings.randomIntervalsEnabled ? random(settings.minInterval...settings.maxInterval) : settings.basicInterval
    }
    private func regularClick(at point: CGPoint, completion: @escaping (ClickEngine) -> Void) {
        if let deadline, scheduler.now >= deadline { expire(); return }
        do {
            clickBegan = scheduler.now
            try output.down(settings.button, at: point)
            if usesTravelCadence { nextRegularClickAt = clickBegan + clickInterval() }
            schedule(0.028) { engine in
                do { try engine.output.up(engine.settings.button, at: point) }
                catch { engine.pause(error.localizedDescription); return }
                engine.clicksPosted += 1; engine.changed?()
                guard engine.active else { return }
                completion(engine)
            }
        } catch { pause(error.localizedDescription) }
    }
    private func nextCycle(since began: TimeInterval) {
        let wait: Double
        if usesTravelCadence, let nextRegularClickAt { wait = nextRegularClickAt - scheduler.now }
        else { wait = clickInterval() - (scheduler.now - began) }
        // Travel clicks never call this: movement decisions and breaks are sampled
        // once per action cycle, with no backlog of suppressed or delayed clicks.
        waitForCycle(until: scheduler.now + max(0.02, wait))
    }
    private func waitForCycle(until cycleDue: TimeInterval) {
        if settings.secondaryClickEnabled, let nextSecondaryAt, nextSecondaryAt <= cycleDue {
            schedule(max(0, nextSecondaryAt - scheduler.now)) { engine in
                engine.secondaryVisit { $0.waitForCycle(until: cycleDue) }
            }
        } else {
            schedule(max(0, cycleDue - scheduler.now)) { $0.prepareCycle(allowBreak: true) }
        }
    }
    private func finishSecondaryVisit(note: String? = nil, completion: (ClickEngine) -> Void) {
        movementPhase = nil
        if let note { movementNote = note }
        nextSecondaryAt = scheduler.now + random(settings.secondaryMinInterval...settings.secondaryMaxInterval)
        changed?()
        guard active else { return }
        completion(self)
    }
    private func secondaryVisit(completion: @escaping (ClickEngine) -> Void) {
        guard let display = output.movementDisplay(for: settings.movementDisplayID),
              settings.movementDisplayIdentity == nil || settings.movementDisplayIdentity == display.identity,
              let profile = settings.movementRegions.first(where: { $0.displayIdentity == display.identity }),
              let domain = profile.secondaryDomain(for: display), let area = profile.secondaryClickArea(for: display),
              let start = output.currentPosition(), domain.contains(start) else {
            finishSecondaryVisit(note: "Secondary click skipped: the display, purple area, or current pointer is unavailable.", completion: completion); return
        }
        let back = settings.regularClickingEnabled ? (target ?? start) : start
        guard domain.contains(back), output.allows(back) else {
            finishSecondaryVisit(note: "Secondary click skipped: the return position is outside the permitted display or inside a blocked area.", completion: completion); return
        }
        let planningLimit = ProcessInfo.processInfo.systemUptime + 0.08
        for _ in 0..<12 {
            if ProcessInfo.processInfo.systemUptime > planningLimit { break }
            let destination = CGPoint(x: random(area.minX...area.maxX), y: random(area.minY...area.maxY))
            guard domain.contains(destination), output.allows(destination),
                  let outward = CurvedMovement.plan(from: start, to: destination, domain: domain, random: random),
                  let inward = CurvedMovement.plan(from: destination, to: back, domain: domain, random: random) else { continue }
            movementNote = nil; movementPhase = "Secondary outward"; changed?()
            secondaryMovePath(outward.points, index: 0, domain: domain, expected: start) { engine in
                engine.movementPhase = "Secondary click"; engine.changed?()
                guard engine.active else { return }
                if let deadline = engine.deadline, engine.scheduler.now >= deadline { engine.expire(); return }
                // Never click a stale planned coordinate after manual displacement.
                guard let actual = engine.output.currentPosition(), movementDistance(actual, destination) <= 1,
                      area.contains(actual), domain.contains(actual), engine.output.allows(actual) else {
                    engine.pause("Secondary click interrupted: the pointer did not arrive in the purple area."); return
                }
                do {
                    try engine.output.down(engine.settings.button, at: actual)
                    guard engine.active else { return }
                    engine.schedule(0.028) { engine in
                        do { try engine.output.up(engine.settings.button, at: actual) }
                        catch { engine.pause(error.localizedDescription); return }
                        engine.clicksPosted += 1
                        guard engine.active else { return }
                        engine.movementPhase = "Secondary return"; engine.changed?()
                        guard engine.active else { return }
                        engine.secondaryMovePath(inward.points, index: 0, domain: domain, expected: destination) {
                            $0.finishSecondaryVisit(completion: completion)
                        }
                    }
                } catch { engine.pause(error.localizedDescription) }
            }
            return
        }
        finishSecondaryVisit(note: "Secondary click skipped: no safe curved route to the purple area and back was found.", completion: completion)
    }
    /// Secondary trips reuse certified curves but have no en-route clicks. A
    /// displaced pointer pauses the trip instead of jumping back onto its path.
    private func secondaryMovePath(_ path: [CGPoint], index: Int, domain: MovementDomain, expected: CGPoint,
                                   completion: @escaping (ClickEngine) -> Void) {
        guard active else { return }
        if let deadline, scheduler.now >= deadline { expire(); return }
        guard let current = output.currentPosition(), movementDistance(current, expected) <= 1 else {
            pause("Secondary movement interrupted by pointer movement. Resume explicitly to continue."); return
        }
        guard index < path.count else { completion(self); return }
        let point = path[index]
        guard domain.permitsSegment(current, point), output.allows(point) else {
            pause("Secondary movement interrupted: the route is blocked or unavailable."); return
        }
        do { try output.move(to: point) }
        catch { pause(error.localizedDescription); return }
        guard active else { return }
        schedule(0.018) { $0.secondaryMovePath(path, index: index + 1, domain: domain, expected: point, completion: completion) }
    }
    private func expire() {
        cancelPending(); output.release(); deadline = nil; frozenRemaining = 0
        nextSecondaryAt = nil; frozenSecondaryRemaining = nil
        breakEndsAt = nil; clickPoint = nil
        guard settings.finalClickEffective else { complete("Timer complete. Session stopped."); return }
        guard !finalAttempted, let finalTarget, output.available, output.allows(finalTarget) else {
            stop("Final target or permission is unavailable. Final click skipped."); return
        }
        finalAttempted = true; status = .finishing; detail = "Sending one exact final click."; changed?()
        do { try output.move(to: finalTarget) }
        catch { stop("Final click failed and will not be retried: " + error.localizedDescription); return }
        schedule(0.015) { engine in
            do {
                try engine.output.down(engine.settings.finalButton, at: finalTarget)
                engine.schedule(0.028) { engine in
                    do { try engine.output.up(engine.settings.finalButton, at: finalTarget) }
                    catch { engine.stop("Final click delivery is uncertain; it will not be retried."); return }
                    engine.awaitingFinalDelivery = true
                    engine.schedule(0.8) { $0.stop("Final click was sent once, but delivery is unconfirmed. It will not be retried.") }
                }
            } catch { engine.stop("Final click failed and will not be retried: " + error.localizedDescription) }
        }
    }
    private func complete(_ message: String) {
        stop(message); frozenRemaining = 0; changed?()
    }
}
