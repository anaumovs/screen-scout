import Foundation

public struct UnitRect: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0.015 && height > 0.015 && x + width <= 1.001 && y + height <= 1.001
    }
    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)
    public static let spin = UnitRect(x: 0.84, y: 0.65, width: 0.05, height: 0.07)
    public static let dismiss = UnitRect(x: 0.37, y: 0.81, width: 0.25, height: 0.08)
    public static let movement = UnitRect(x: 0.82, y: 0.62, width: 0.10, height: 0.14)
    public func contains(_ point: UnitPoint) -> Bool {
        point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height
    }
    public func randomPoint() -> UnitPoint {
        UnitPoint(x: Double.random(in: x...(x + width)), y: Double.random(in: y...(y + height)))
    }
}

public struct UnitPoint: Codable, Equatable, Sendable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public enum ScreenState: String, Codable, CaseIterable, Sendable {
    case ready = "Ready"
    case bonus = "Bonus active"
    case results = "Results"
    case animation = "Transition"
    case unknown = "Unknown"
}

public struct TextEvidence: Codable, Sendable {
    public var text: String
    public var confidence: Double
    public var bounds: UnitRect
    public init(_ text: String, confidence: Double = 0.99, bounds: UnitRect = .full) {
        self.text = text; self.confidence = confidence; self.bounds = bounds
    }
}

public struct VisualEvidence: Codable, Sendable {
    public var turquoise: Double
    public var purple: Double
    public var green: Double
    public var red: Double
    public var reelColumns: Int
    public var spinRing: Double
    public init(turquoise: Double = 0, purple: Double = 0, green: Double = 0, red: Double = 0, reelColumns: Int = 0, spinRing: Double = 0) {
        self.turquoise = turquoise; self.purple = purple; self.green = green; self.red = red
        self.reelColumns = reelColumns; self.spinRing = spinRing
    }
}

public struct Observation: Codable, Sendable {
    public var id: UInt64
    public var capturedAt: TimeInterval
    public var state: ScreenState
    public var confidence: Double
    public var reason: String
    public var text: [TextEvidence]
    public var visuals: VisualEvidence
    public init(id: UInt64, capturedAt: TimeInterval, state: ScreenState, confidence: Double = 0.99, reason: String = "Test evidence", text: [TextEvidence] = [], visuals: VisualEvidence = .init()) {
        self.id = id; self.capturedAt = capturedAt; self.state = state; self.confidence = confidence
        self.reason = reason; self.text = text; self.visuals = visuals
    }
}

public struct ScoutSettings: Codable, Equatable, Sendable {
    public var minInterval = 1.4
    public var maxInterval = 2.8
    public var pauseProbability = 0.08
    public var movementProbability = 0.15
    public var resultsDelay = 1.5
    public var confidenceThreshold = 0.82
    public var confirmations = 3
    public var countdown = 3.0
    public var freshnessLimit = 1.5
    public var transitionTimeout = 7.0
    public var observationGapLimit = 2.0
    public var clickRegion = UnitRect.spin
    public var resultsRegion = UnitRect.dismiss
    public var movementRegion = UnitRect.movement
    public var hotkeyCode: UInt32 = 100 // F8
    public var hotkeyModifiers: UInt32 = 0
    public init() {}
    public var validationError: String? {
        let values = [minInterval, maxInterval, pauseProbability, movementProbability, resultsDelay, confidenceThreshold, countdown, freshnessLimit, transitionTimeout, observationGapLimit]
        guard values.allSatisfy(\.isFinite) else { return "Settings must be finite numbers." }
        guard minInterval >= 0.5 && maxInterval >= minInterval && maxInterval <= 120 else { return "Intervals must be 0.5–120 seconds, with maximum ≥ minimum." }
        guard (0...1).contains(pauseProbability) && (0...1).contains(movementProbability) else { return "Probabilities must be between zero and one." }
        guard resultsDelay >= 0.5 && resultsDelay <= 30 && (0.7...1).contains(confidenceThreshold) && (2...8).contains(confirmations) else { return "Use 2–8 confirmations, confidence ≥ 70%, and a 0.5–30 second results delay." }
        guard (1...10).contains(countdown) && (0.5...2).contains(freshnessLimit) && (2...30).contains(transitionTimeout) && (0.5...3).contains(observationGapLimit) else { return "Invalid timing limits." }
        guard clickRegion.isValid && resultsRegion.isValid && movementRegion.isValid else { return "Draw valid regions inside the mock image." }
        // A straight route between any two points is contained in this convex region.
        guard movementRegion.contains(.init(x: clickRegion.x, y: clickRegion.y)),
              movementRegion.contains(.init(x: clickRegion.x + clickRegion.width, y: clickRegion.y + clickRegion.height)) else { return "The movement region must fully contain the click region." }
        return nil
    }
}
