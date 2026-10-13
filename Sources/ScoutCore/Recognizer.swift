import Foundation

public enum Recognizer {
    public static func classify(id: UInt64, capturedAt: TimeInterval, text: [TextEvidence], visuals: VisualEvidence) -> Observation {
        let lines = text.filter { $0.confidence >= 0.65 }.sorted { $0.bounds.y < $1.bounds.y }
        func normalized(_ value: String) -> String {
            value.uppercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let joined = lines.map { normalized($0.text) }.joined(separator: " ")
        func line(_ phrase: String) -> TextEvidence? { lines.first { normalized($0.text).contains(phrase) } }
        func result(_ state: ScreenState, _ confidence: Double, _ reason: String) -> Observation {
            Observation(id: id, capturedAt: capturedAt, state: state, confidence: confidence, reason: reason, text: text, visuals: visuals)
        }
        let blocked = ["CONNECTION", "DISCONNECTED", "ERROR", "SESSION EXPIRED", "RECONNECT", "UNAVAILABLE", "PLEASE WAIT", "LOADING", "SIGN IN", "LOG IN"]
        if blocked.contains(where: joined.contains) { return result(.unknown, 0, "Blocked or loading text detected. Manual review required.") }
        // Bonus evidence has priority over readiness, including a zero counter.
        // Recognition never relies on the counter value or the screen colour.
        if joined.contains("FREE SPINS LEFT") {
            let phrase = line("FREE SPINS LEFT")
            return result(.bonus, phrase?.confidence ?? 0.85, "FREE SPINS LEFT detected. Colour and counter value do not establish completion.")
        }
        if joined.contains("FREE SPINS") && !joined.contains("PRESS ANYWHERE TO CONTINUE") {
            return result(.unknown, 0, "Possible bonus entry. An active-bonus or results state is not confirmed.")
        }
        if let congratulations = line("CONGRATULATIONS"), let won = line("YOU HAVE WON"),
           let total = text.first(where: { $0.confidence >= 0.5 && normalized($0.text).hasPrefix("IN ") && normalized($0.text).contains("FREE SPINS") }),
           let prompt = line("PRESS ANYWHERE TO CONTINUE") {
            let ordered = congratulations.bounds.y < won.bounds.y && won.bounds.y < total.bounds.y && total.bounds.y < prompt.bounds.y
            let centered = [congratulations, won, total, prompt].allSatisfy { abs(($0.bounds.x + $0.bounds.width / 2) - 0.5) < 0.24 }
            let separated = prompt.bounds.y - congratulations.bounds.y > 0.3
            if ordered && centered && separated {
                // Number-bearing text often gets lower OCR confidence. It supports the
                // layout, while all three nonnumeric anchors remain mandatory.
                let confidence = min(congratulations.confidence, won.confidence, prompt.confidence) * 0.85 + total.confidence * 0.15
                return result(.results, confidence, "Known text hierarchy and centered results layout confirmed.")
            }
            return result(.unknown, 0, "Results text found, but its layout is unconfirmed.")
        }
        if joined.contains("CONGRATULATIONS") || joined.contains("PRESS ANYWHERE TO CONTINUE") {
            return result(.unknown, 0, "Incomplete results evidence.")
        }
        if let ready = line("PLACE YOUR BETS"), ready.bounds.y > 0.65,
           visuals.turquoise >= 0.12, visuals.reelColumns >= 3, visuals.spinRing >= 0.5 {
            return result(.ready, min(ready.confidence, 0.94), "Ready text, three reel-like columns, turquoise field, and spin-ring feature agree.")
        }
        // This explicit marker is used only by the bundled synthetic fixture.
        if line("DEMO TRANSITION") != nil {
            return result(.animation, 0.96, "Synthetic transition marker detected.")
        }
        return result(.unknown, 0, "No complete known state. Stillness or colour alone cannot authorize an action.")
    }
}
