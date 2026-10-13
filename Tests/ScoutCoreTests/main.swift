import Foundation

var failed = 0
var checks = 0
var currentName = ""
class CheckSuite { func setUp() {} }
func fail(_ message: String = "Assertion failed", file: StaticString = #filePath, line: UInt = #line) {
    failed += 1; print("FAIL \(currentName): \(message) [\(file):\(line)]")
}
func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { if !value { fail("Expected true", file: file, line: line) } }
func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value != nil { fail("Expected nil", file: file, line: line) } }
func expectNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { if value == nil { fail("Expected non-nil", file: file, line: line) } }
func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a != b { fail("Expected \(b), got \(a)", file: file, line: line) } }
func expectGreaterThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { if a <= b { fail("Expected \(a) > \(b)", file: file, line: line) } }
func run(_ name: String, _ action: () -> Void) { currentName = name; checks += 1; let before = failed; action(); if before == failed { print("PASS \(name)") } }

run("RecognitionTests.testReadyNeedsTextAndVisualStructure") { let suite = RecognitionTests(); suite.setUp(); suite.testReadyNeedsTextAndVisualStructure() }
run("RecognitionTests.testColourCannotAuthorizeAction") { let suite = RecognitionTests(); suite.setUp(); suite.testColourCannotAuthorizeAction() }
run("RecognitionTests.testBonusIndependentOfCounterAndColour") { let suite = RecognitionTests(); suite.setUp(); suite.testBonusIndependentOfCounterAndColour() }
run("RecognitionTests.testBonusWinsOverReady") { let suite = RecognitionTests(); suite.setUp(); suite.testBonusWinsOverReady() }
run("RecognitionTests.testBlockerWinsOverKnownStates") { let suite = RecognitionTests(); suite.setUp(); suite.testBlockerWinsOverKnownStates() }
run("RecognitionTests.testResultsRequiresPromptAndLayout") { let suite = RecognitionTests(); suite.setUp(); suite.testResultsRequiresPromptAndLayout() }
run("RecognitionTests.testUncertainOCRDoesNotRecognizeReady") { let suite = RecognitionTests(); suite.setUp(); suite.testUncertainOCRDoesNotRecognizeReady() }
run("RecognitionTests.testUnknownBonusEntry") { let suite = RecognitionTests(); suite.setUp(); suite.testUnknownBonusEntry() }
run("ControllerTests.testCountdownAndSeveralObservationsRequired") { let suite = ControllerTests(); suite.setUp(); suite.testCountdownAndSeveralObservationsRequired() }
run("ControllerTests.testBonusPreemptsExpiredTimerIncludingZero") { let suite = ControllerTests(); suite.setUp(); suite.testBonusPreemptsExpiredTimerIncludingZero() }
run("ControllerTests.testAfterTapUnchangedReadyTimesOutWithoutSecondTap") { let suite = ControllerTests(); suite.setUp(); suite.testAfterTapUnchangedReadyTimesOutWithoutSecondTap() }
run("ControllerTests.testUnknownAfterTapDoesNotCountAsTransition") { let suite = ControllerTests(); suite.setUp(); suite.testUnknownAfterTapDoesNotCountAsTransition() }
run("ControllerTests.testConfirmedTransitionAndReadyPermitNextTap") { let suite = ControllerTests(); suite.setUp(); suite.testConfirmedTransitionAndReadyPermitNextTap() }
run("ControllerTests.testResultsReceivesAtMostOneAttemptEvenAfterRestart") { let suite = ControllerTests(); suite.setUp(); suite.testResultsReceivesAtMostOneAttemptEvenAfterRestart() }
run("ControllerTests.testBonusToResultsToReady") { let suite = ControllerTests(); suite.setUp(); suite.testBonusToResultsToReady() }
run("ControllerTests.testStaleCapturePauses") { let suite = ControllerTests(); suite.setUp(); suite.testStaleCapturePauses() }
run("ControllerTests.testLowConfidenceReadyPauses") { let suite = ControllerTests(); suite.setUp(); suite.testLowConfidenceReadyPauses() }
run("ControllerTests.testStopCancelsPendingTap") { let suite = ControllerTests(); suite.setUp(); suite.testStopCancelsPendingTap() }
run("ControllerTests.testManualPauseCancelsPendingTapAndDoesNotResume") { let suite = ControllerTests(); suite.setUp(); suite.testManualPauseCancelsPendingTapAndDoesNotResume() }
run("ControllerTests.testFocusLossCancelsPendingTap") { let suite = ControllerTests(); suite.setUp(); suite.testFocusLossCancelsPendingTap() }
run("ControllerTests.testGeometryInvalidationCancelsPendingTap") { let suite = ControllerTests(); suite.setUp(); suite.testGeometryInvalidationCancelsPendingTap() }
run("ControllerTests.testDuplicateFramesCannotBuildConfidence") { let suite = ControllerTests(); suite.setUp(); suite.testDuplicateFramesCannotBuildConfidence() }
run("ControllerTests.testStreamGapPausesAndNeverCatchesUp") { let suite = ControllerTests(); suite.setUp(); suite.testStreamGapPausesAndNeverCatchesUp() }
run("ControllerTests.testInvalidRegionCannotStart") { let suite = ControllerTests(); suite.setUp(); suite.testInvalidRegionCannotStart() }
run("ControllerTests.testMovementStaysInsideApprovedRegions") { let suite = ControllerTests(); suite.setUp(); suite.testMovementStaysInsideApprovedRegions() }
run("ControllerTests.testTapAndDismissPointsAreInsideRegions") { let suite = ControllerTests(); suite.setUp(); suite.testTapAndDismissPointsAreInsideRegions() }
run("ControllerTests.testGuaranteedRandomRestProducesNoTap") { let suite = ControllerTests(); suite.setUp(); suite.testGuaranteedRandomRestProducesNoTap() }
print("\(checks) checks, \(failed) failures.")
if failed > 0 { exit(1) }
