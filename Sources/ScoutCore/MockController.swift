import Foundation

/// Produces in-memory simulation intents only. There is deliberately no OS event sink.
public enum MockIntent: Equatable, Sendable {
    case tap(UnitPoint)
    case dismiss(UnitPoint)
    case move(UnitPoint, returnTo: UnitPoint)
}

public enum RunPhase: String, Sendable {
    case stopped = "Stopped", countdown = "Countdown", watching = "Observing", ready = "Ready"
    case transition = "Waiting for change", bonus = "Watching bonus", results = "Results confirmed"
    case randomPause = "Random rest", paused = "Paused"
}

public struct MockController: Sendable {
    public private(set) var phase: RunPhase = .stopped
    public private(set) var reason = "Start the mock to simulate actions."
    public private(set) var settings = ScoutSettings()
    public private(set) var actionCount = 0
    public private(set) var dismissCount = 0
    public private(set) var lastIntent: MockIntent?
    private var countdownUntil = 0.0
    private var due: TimeInterval?
    private var restUntil: TimeInterval?
    private var lastID: UInt64?
    private var lastCapture: TimeInterval?
    private var historyState: ScreenState?
    private var historyCount = 0
    private var stateSince = 0.0
    private var pending: (kind: ScreenState, at: TimeInterval)?
    private var transitionSeen = false
    // Persists through stop/start; clear only after a confirmed ready state.
    private var resultsAttempted = false
    public init() {}
    public var isRunning: Bool { phase != .stopped && phase != .paused }

    public mutating func start(now: TimeInterval, settings: ScoutSettings) {
        self.settings = settings
        guard let error = settings.validationError else {
            clearPending()
            countdownUntil = now + settings.countdown
            phase = .countdown; reason = "Mock simulation begins after the countdown."
            return
        }
        pause(error)
    }
    public mutating func stop() {
        clearPending(); phase = .stopped; reason = "Stopped. Pending simulation intents cancelled."
    }
    public mutating func pause(_ why: String = "Paused by you. Press Start to restart with fresh evidence.") {
        clearPending(); phase = .paused; reason = why
    }
    private mutating func clearPending() {
        due = nil; restUntil = nil; pending = nil; transitionSeen = false
        lastID = nil; lastCapture = nil; historyState = nil; historyCount = 0; lastIntent = nil
    }
    public mutating func ingest(_ observation: Observation, now: TimeInterval, calibrated: Bool = true, focused: Bool = true) -> MockIntent? {
        lastIntent = nil
        guard isRunning else { return nil }
        guard calibrated else { pause("Geometry changed. Recalibrate before restarting."); return nil }
        guard focused else { pause("Focus lost. Start again explicitly."); return nil }
        guard now >= observation.capturedAt, now - observation.capturedAt <= settings.freshnessLimit else { pause("Observation is stale or has an invalid timestamp."); return nil }
        guard observation.id != lastID else { return nil }
        if let previous = lastCapture, observation.capturedAt <= previous || observation.capturedAt - previous > settings.observationGapLimit {
            pause("Observation stream interrupted. Start again with fresh evidence."); return nil
        }
        lastID = observation.id; lastCapture = observation.capturedAt
        if phase == .countdown {
            guard now >= countdownUntil else { return nil }
            phase = .watching; historyState = nil; historyCount = 0
        }
        let trusted = observation.confidence >= settings.confidenceThreshold
        let state = trusted ? observation.state : .unknown
        if state == historyState { historyCount += 1 } else {
            historyState = state; historyCount = 1; stateSince = now
        }
        let confirmed = historyCount >= settings.confirmations

        if let wait = pending {
            if now - wait.at > settings.transitionTimeout {
                pause("The previous mock action produced no confirmed transition."); return nil
            }
            // An unknown frame never proves that the action succeeded.
            if state == .unknown { pause(observation.reason); return nil }
            if wait.kind == .results && state == .results {
                phase = .transition; reason = "One results dismissal attempted. Waiting for a different state."
                return nil
            }
            if wait.kind == .ready && state == .ready && !transitionSeen {
                phase = .transition; reason = "Waiting for evidence that the mock tap changed the screen."
                return nil
            }
            if state != wait.kind { transitionSeen = true }
            if !confirmed { phase = .transition; reason = "Confirming the transition across observations."; return nil }
            pending = nil; due = nil
        }

        if state == .unknown { pause(observation.reason); return nil }
        if state == .bonus {
            due = nil; restUntil = nil; phase = .bonus
            reason = "Normal simulation suspended. A zero counter is still an active bonus."
            return nil
        }
        if state == .animation {
            due = nil; phase = .transition; reason = "Observing the mock transition."
            if now - stateSince > settings.transitionTimeout { pause("Transition timed out.") }
            return nil
        }
        guard confirmed else { phase = .watching; reason = "Confirming \(state.rawValue.lowercased()) (\(historyCount)/\(settings.confirmations))."; return nil }
        if state == .results {
            due = nil; restUntil = nil; phase = .results
            if resultsAttempted { reason = "This results episode already received its single mock dismissal."; return nil }
            reason = "Results stable. Waiting for the confirmation delay."
            guard now - stateSince >= settings.resultsDelay else { return nil }
            resultsAttempted = true; dismissCount += 1
            pending = (.results, now); transitionSeen = false; historyState = nil; historyCount = 0
            phase = .transition
            return emit(.dismiss(settings.resultsRegion.randomPoint()))
        }
        guard state == .ready else { return nil }
        resultsAttempted = false
        if let until = restUntil {
            if now < until { phase = .randomPause; reason = "Taking a random 5–10 second rest."; return nil }
            restUntil = nil; due = now + Double.random(in: settings.minInterval...settings.maxInterval)
        }
        phase = .ready
        if due == nil {
            due = now + Double.random(in: settings.minInterval...settings.maxInterval)
            reason = "Ready confirmed. A fresh interval was selected."
            return nil
        }
        guard now >= due! else { reason = "Ready confirmed. Waiting for the next eligible mock tap."; return nil }
        if Double.random(in: 0..<1) < settings.pauseProbability {
            restUntil = now + Double.random(in: 5...10); due = nil; phase = .randomPause
            reason = "Taking a random 5–10 second rest."; return nil
        }
        if Double.random(in: 0..<1) < settings.movementProbability {
            // The mock displays a path; the system cursor is never touched.
            due = now + Double.random(in: settings.minInterval...settings.maxInterval)
            return emit(.move(settings.movementRegion.randomPoint(), returnTo: settings.clickRegion.randomPoint()))
        }
        actionCount += 1; due = nil; pending = (.ready, now); transitionSeen = false
        historyState = nil; historyCount = 0; phase = .transition
        return emit(.tap(settings.clickRegion.randomPoint()))
    }
    private mutating func emit(_ intent: MockIntent) -> MockIntent { lastIntent = intent; return intent }
}
