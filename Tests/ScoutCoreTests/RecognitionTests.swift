import Foundation
import ScoutCore

final class RecognitionTests: CheckSuite {
    func line(_ text: String, y: Double, confidence: Double = 0.99) -> TextEvidence {
        TextEvidence(text, confidence: confidence, bounds: .init(x: 0.25, y: y, width: 0.5, height: 0.05))
    }
    func classify(_ lines: [TextEvidence], visuals: VisualEvidence = .init()) -> Observation {
        Recognizer.classify(id: 1, capturedAt: 0, text: lines, visuals: visuals)
    }
    let normalVisuals = VisualEvidence(turquoise: 0.5, reelColumns: 3, spinRing: 0.9)
    func testReadyNeedsTextAndVisualStructure() {
        expectEqual(classify([line("PLACE YOUR BETS!", y: 0.9)], visuals: normalVisuals).state, .ready)
        expectEqual(classify([line("PLACE YOUR BETS!", y: 0.9)]).state, .unknown)
        expectEqual(classify([], visuals: normalVisuals).state, .unknown)
        expectEqual(classify([line("PLACE YOUR BETS!", y: 0.2)], visuals: normalVisuals).state, .unknown)
    }
    func testColourCannotAuthorizeAction() {
        for visuals in [VisualEvidence(turquoise: 1), .init(purple: 1), .init(green: 1), .init(red: 1)] {
            expectEqual(classify([], visuals: visuals).state, .unknown)
        }
    }
    func testBonusIndependentOfCounterAndColour() {
        for count in [0, 2, 5, 100] {
            expectEqual(classify([line("\(count) FREE SPINS LEFT", y: 0.85)]).state, .bonus)
        }
    }
    func testBonusWinsOverReady() {
        expectEqual(classify([line("PLACE YOUR BETS", y: 0.9), line("FREE SPINS LEFT", y: 0.8)], visuals: normalVisuals).state, .bonus)
    }
    func testBlockerWinsOverKnownStates() {
        expectEqual(classify([line("CONNECTION ERROR", y: 0.1), line("PLACE YOUR BETS", y: 0.9)], visuals: normalVisuals).state, .unknown)
    }
    func testResultsRequiresPromptAndLayout() {
        let lines = [line("CONGRATULATIONS!", y: 0.15), line("YOU HAVE WON", y: 0.3), line("IN 9 FREE SPINS", y: 0.6), line("PRESS ANYWHERE TO CONTINUE", y: 0.85)]
        expectEqual(classify(lines).state, .results)
        expectEqual(classify(Array(lines.dropLast())).state, .unknown)
        var wrong = lines; wrong[0].bounds.y = 0.95
        expectEqual(classify(wrong).state, .unknown)
        wrong = lines; wrong[3].bounds.x = 0.7
        expectEqual(classify(wrong).state, .unknown)
        var uncertainNumber = lines; uncertainNumber[2].confidence = 0.5
        expectEqual(classify(uncertainNumber).state, .results)
        expectGreaterThan(classify(uncertainNumber).confidence, 0.9)
        uncertainNumber[3].confidence = 0.5
        expectEqual(classify(uncertainNumber).state, .unknown)
    }
    func testUncertainOCRDoesNotRecognizeReady() {
        expectEqual(classify([line("PLACE YOUR BETS", y: 0.9, confidence: 0.4)], visuals: normalVisuals).state, .unknown)
    }
    func testUnknownBonusEntry() {
        expectEqual(classify([line("YOU GET 5 FREE SPINS", y: 0.4)]).state, .unknown)
    }
}
