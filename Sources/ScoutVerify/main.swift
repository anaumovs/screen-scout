import Foundation
import ScoutCore
import ScoutVision

let args = CommandLine.arguments
let output = URL(fileURLWithPath: args.count > 1 ? args[1] : "artifacts/offline-verification", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var failures: [String] = []
var reports: [[String: Any]] = []
var id: UInt64 = 0
for scale in [0.65, 1.0, 2.0] {
    for scene in MockScene.allCases {
        id += 1
        let image = MockRenderer.image(scene: scene, scale: scale, variant: Int(id))
        let name = "\(scene.rawValue.replacingOccurrences(of: " ", with: "-"))-\(scale)x.png"
        try MockRenderer.writePNG(image, to: output.appendingPathComponent(name))
        let o = try ImageAnalyzer.analyze(image, id: id, capturedAt: Double(id))
        let passed = o.state == scene.expected
        if !passed {
            failures.append("\(name): expected \(scene.expected.rawValue), got \(o.state.rawValue)")
            o.text.forEach { print("  OCR \($0.confidence): \($0.text) [y=\($0.bounds.y)]") }
        }
        reports.append(["file": name, "expected": scene.expected.rawValue, "detected": o.state.rawValue, "pass": passed, "confidence": o.confidence, "reason": o.reason, "text": o.text.map(\.text), "reelColumns": o.visuals.reelColumns, "spinRing": o.visuals.spinRing, "turquoise": o.visuals.turquoise])
        print("\(passed ? "PASS" : "FAIL") \(name) → \(o.state.rawValue) (columns \(o.visuals.reelColumns), ring \(o.visuals.spinRing))")
    }
}

// Replay a recorded synthetic scenario through OCR and the isolated mock controller.
// Each image is persisted with a timestamp manifest; no live application is controlled.
var settings = ScoutSettings()
settings.countdown = 1; settings.minInterval = 0.5; settings.maxInterval = 0.5
settings.pauseProbability = 0; settings.movementProbability = 0
var engine = MockController(); engine.start(now: 0, settings: settings)
var sequence: [[String: Any]] = []
var taps = 0, dismissals = 0
var current = MockScene.ready
var actionAt: Double?
var dismissedAt: Double?
let sequenceDir = output.appendingPathComponent("recorded-sequence", isDirectory: true)
try FileManager.default.createDirectory(at: sequenceDir, withIntermediateDirectories: true)
for index in 0..<44 {
    let now = Double(index) * 0.5
    if let dismissedAt {
        current = now - dismissedAt < 2 ? .animation : .ready
    } else if let actionAt {
        let elapsed = now - actionAt
        if elapsed < 2 { current = .animation }
        else if elapsed < 4 { current = .purple }
        else if elapsed < 6 { current = .green }
        else if elapsed < 8 { current = .zero }
        else { current = .results }
    }
    let frame = MockRenderer.image(scene: current, variant: index)
    let filename = String(format: "%03d-%@.png", index, current.rawValue.replacingOccurrences(of: " ", with: "-"))
    try MockRenderer.writePNG(frame, to: sequenceDir.appendingPathComponent(filename))
    let observation = try ImageAnalyzer.analyze(frame, id: UInt64(index + 1), capturedAt: now)
    let intent = engine.ingest(observation, now: now)
    var intentText = "none"
    if let intent {
        switch intent {
        case .tap: taps += 1; intentText = "mock tap"; if actionAt == nil { actionAt = now }
        case .dismiss: dismissals += 1; dismissedAt = now; intentText = "mock dismiss"
        case .move: intentText = "mock move"
        }
    }
    sequence.append(["file": filename, "timestamp": now, "state": observation.state.rawValue, "phase": engine.phase.rawValue, "intent": intentText, "reason": engine.reason])
    if taps >= 2 { break }
}
if dismissals != 1 { failures.append("Recorded sequence expected one dismissal, got \(dismissals)") }
if taps != 2 { failures.append("Recorded sequence expected two taps separated by bonus/results/ready, got \(taps)") }
try JSONSerialization.data(withJSONObject: sequence, options: [.prettyPrinted, .sortedKeys]).write(to: sequenceDir.appendingPathComponent("manifest.json"))
let summary: [String: Any] = ["syntheticOnly": true, "actualGameReferencesProvided": false, "redActualGameVerified": false, "fixtures": reports, "sequenceTapCount": taps, "sequenceDismissCount": dismissals, "failures": failures]
try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("report.json"))
print("\(reports.count) screenshot checks; recorded sequence: \(taps) taps / \(dismissals) dismissal(s).")
if !failures.isEmpty { failures.forEach { print("FAIL: \($0)") }; exit(1) }
print("PASS — synthetic screenshots and recorded sequence. Actual game remains unverified.")
