import Foundation
import ScoutCore

final class ControllerTests: CheckSuite {
    var engine = MockController()
    var now = 0.0
    var id: UInt64 = 0
    var settings: ScoutSettings {
        var s = ScoutSettings(); s.countdown = 1; s.minInterval = 0.5; s.maxInterval = 0.5
        s.pauseProbability = 0; s.movementProbability = 0; return s
    }
    override func setUp() {
        super.setUp(); engine = MockController(); now = 0; id = 0
        engine.start(now: now, settings: settings)
    }
    @discardableResult func step(_ state: ScreenState, confidence: Double = 0.99, calibrated: Bool = true, focused: Bool = true) -> MockIntent? {
        now += 0.5; id += 1
        return engine.ingest(.init(id: id, capturedAt: now, state: state, confidence: confidence), now: now, calibrated: calibrated, focused: focused)
    }
    func firstTap() -> MockIntent? {
        for _ in 0..<8 { if let action = step(.ready) { return action } }
        fail("Expected mock tap"); return nil
    }
    func testCountdownAndSeveralObservationsRequired() {
        expectNil(step(.ready)); expectNil(step(.ready)); expectNil(step(.ready)); expectNil(step(.ready))
        guard case .tap = step(.ready) else { return fail("Expected tap after countdown and confirmations") }
    }
    func testBonusPreemptsExpiredTimerIncludingZero() {
        for _ in 0..<4 { expectNil(step(.ready)) }
        for _ in 0..<30 { expectNil(step(.bonus)) }
        expectEqual(engine.phase, .bonus); expectEqual(engine.actionCount, 0)
    }
    func testAfterTapUnchangedReadyTimesOutWithoutSecondTap() {
        expectNotNil(firstTap())
        for _ in 0..<20 { expectNil(step(.ready)) }
        expectEqual(engine.phase, .paused); expectEqual(engine.actionCount, 1)
    }
    func testUnknownAfterTapDoesNotCountAsTransition() {
        expectNotNil(firstTap()); expectNil(step(.unknown)); expectEqual(engine.phase, .paused)
        for _ in 0..<20 { expectNil(step(.ready)) }
    }
    func testConfirmedTransitionAndReadyPermitNextTap() {
        expectNotNil(firstTap())
        for _ in 0..<4 { expectNil(step(.animation)) }
        expectNil(step(.ready)); expectNil(step(.ready)); expectNil(step(.ready))
        guard case .tap = step(.ready) else { return fail("Expected a new tap") }
    }
    func testResultsReceivesAtMostOneAttemptEvenAfterRestart() {
        var intents = 0
        for _ in 0..<14 { if step(.results) != nil { intents += 1 } }
        expectEqual(intents, 1)
        engine.stop(); engine.start(now: now, settings: settings)
        for _ in 0..<20 { expectNil(step(.results)) }
        expectEqual(engine.dismissCount, 1)
    }
    func testBonusToResultsToReady() {
        for _ in 0..<6 { expectNil(step(.bonus)) }
        var dismissals = 0
        for _ in 0..<6 { if case .dismiss = step(.results) { dismissals += 1 } }
        expectEqual(dismissals, 1); expectEqual(engine.actionCount, 0)
        for _ in 0..<3 { expectNil(step(.animation)) }
        expectNil(step(.ready)); expectNil(step(.ready)); expectNil(step(.ready))
        guard case .tap = step(.ready) else { return fail("Expected tap only after confirmed ready") }
    }
    func testStaleCapturePauses() {
        now = 4
        expectNil(engine.ingest(.init(id: 1, capturedAt: 0, state: .ready), now: now))
        expectEqual(engine.phase, .paused)
    }
    func testLowConfidenceReadyPauses() {
        step(.ready); expectNil(step(.ready, confidence: 0.75)); expectEqual(engine.phase, .paused)
    }
    func testStopCancelsPendingTap() {
        for _ in 0..<4 { step(.ready) }
        engine.stop()
        for _ in 0..<20 { expectNil(step(.ready)) }
        expectEqual(engine.actionCount, 0)
    }
    func testManualPauseCancelsPendingTapAndDoesNotResume() {
        for _ in 0..<4 { step(.ready) }
        engine.pause("Manual interaction")
        for _ in 0..<20 { expectNil(step(.ready)) }
        expectEqual(engine.actionCount, 0); expectEqual(engine.phase, .paused)
    }
    func testFocusLossCancelsPendingTap() {
        for _ in 0..<4 { step(.ready) }
        expectNil(step(.ready, focused: false)); expectEqual(engine.phase, .paused)
    }
    func testGeometryInvalidationCancelsPendingTap() {
        for _ in 0..<4 { step(.ready) }
        expectNil(step(.ready, calibrated: false)); expectEqual(engine.phase, .paused)
    }
    func testDuplicateFramesCannotBuildConfidence() {
        let o = Observation(id: 1, capturedAt: 1, state: .ready)
        for _ in 0..<10 { expectNil(engine.ingest(o, now: 1)) }
        expectEqual(engine.actionCount, 0)
    }
    func testStreamGapPausesAndNeverCatchesUp() {
        for _ in 0..<4 { step(.ready) }; now += 10
        expectNil(step(.ready)); expectEqual(engine.phase, .paused); expectEqual(engine.actionCount, 0)
    }
    func testInvalidRegionCannotStart() {
        var invalid = settings; invalid.clickRegion.x = 0.1
        engine.start(now: now, settings: invalid)
        expectEqual(engine.phase, .paused)
    }
    func testMovementStaysInsideApprovedRegions() {
        var s = settings; s.movementProbability = 1
        engine.start(now: now, settings: s)
        var moves = 0
        for _ in 0..<50 {
            if case .move(let p, let back) = step(.ready) {
                moves += 1; expectTrue(s.movementRegion.contains(p)); expectTrue(s.clickRegion.contains(back))
            }
        }
        expectGreaterThan(moves, 5); expectEqual(engine.actionCount, 0)
    }
    func testTapAndDismissPointsAreInsideRegions() {
        guard case .tap(let point) = firstTap() else { return fail() }
        expectTrue(settings.clickRegion.contains(point))
        engine.stop(); engine.start(now: now, settings: settings)
        for _ in 0..<8 {
            if case .dismiss(let point) = step(.results) { expectTrue(settings.resultsRegion.contains(point)); return }
        }
        fail("Expected dismissal")
    }
    func testGuaranteedRandomRestProducesNoTap() {
        var s = settings; s.pauseProbability = 1
        engine.start(now: now, settings: s)
        for _ in 0..<50 { expectNil(step(.ready)) }
        expectEqual(engine.actionCount, 0)
    }
}
