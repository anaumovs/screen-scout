import Foundation

public enum ClickButton: String, Codable, CaseIterable, Sendable {
    case left = "Left click", right = "Right click"
}
public enum MovementMode: String, Codable, CaseIterable, Sendable {
    case local = "Existing local movement", fullScreen = "Full-screen random movement"
}

public struct ClickSettings: Codable, Equatable, Sendable {
    public var minInterval = 1.4
    public var maxInterval = 2.8
    public var movementProbability = 0.15
    public var movementRadius = 4.0
    public var breakProbability = 0.08
    public var minBreak = 5.0
    public var maxBreak = 10.0
    public var button: ClickButton = .right
    public var emergencyCode: UInt32 = 100 // F8, independent of F+G+H
    public var emergencyModifiers: UInt32 = 0
    // Existing features stay enabled on migration; newly added behavior is opt-in.
    public var regularClickingEnabled = true
    public var randomIntervalsEnabled = true
    public var smallMovementEnabled = true
    public var largeMovementEnabled = false
    public var largeMovementProbability = 0.15
    public var largeMovementSpeed = 1.0
    public var smallClickWhileMoving = false
    public var largeClickWhileMoving = false
    public var movementDisplayIdentity: String?
    public var movementRegions: [MovementRegionProfile] = []
    public var secondaryClickEnabled = false
    public var secondaryMinInterval = 5.0
    public var secondaryMaxInterval = 10.0
    public var breaksEnabled = true
    public var clickVariationEnabled = false
    public var clickVariationRadius = 2.0
    public var movementDisplayID: UInt32 = 0 // Main display until explicitly selected.
    public var timerEnabled = false
    public var timerHours = 0
    public var timerMinutes = 30
    public var timerSeconds = 0
    public var finalClickEnabled = false
    public var finalButton: ClickButton = .right
    public var basicInterval: Double { (minInterval + maxInterval) / 2 }
    public var timerDuration: Double { Double(timerHours) * 3600 + Double(timerMinutes) * 60 + Double(timerSeconds) }
    public var finalClickEffective: Bool { timerEnabled && finalClickEnabled }
    public var needsRegularTarget: Bool { regularClickingEnabled }
    // Compatibility accessors for callers of the previous settings API. The UI
    // and engine use the independent switches; persistence writes only those.
    public var movementEnabled: Bool {
        get { smallMovementEnabled || largeMovementEnabled }
        set { if !newValue { smallMovementEnabled=false; largeMovementEnabled=false }
              else if !movementEnabled { smallMovementEnabled=true } }
    }
    public var movementMode: MovementMode {
        get { largeMovementEnabled && !smallMovementEnabled ? .fullScreen : .local }
        set { let enabled=movementEnabled; smallMovementEnabled=enabled && newValue == .local; largeMovementEnabled=enabled && newValue == .fullScreen }
    }
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case minInterval, maxInterval, movementProbability, movementRadius, breakProbability, minBreak, maxBreak, button, emergencyCode, emergencyModifiers
        case regularClickingEnabled, randomIntervalsEnabled, movementEnabled, breaksEnabled, clickVariationEnabled, clickVariationRadius, movementMode, movementDisplayID
        case largeMovementSpeed, smallClickWhileMoving, largeClickWhileMoving
        case smallMovementEnabled, largeMovementEnabled, largeMovementProbability, movementDisplayIdentity, movementRegions
        case secondaryClickEnabled, secondaryMinInterval, secondaryMaxInterval
        case timerEnabled, timerHours, timerMinutes, timerSeconds, finalClickEnabled, finalButton
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        minInterval = try c.decodeIfPresent(Double.self, forKey: .minInterval) ?? minInterval
        maxInterval = try c.decodeIfPresent(Double.self, forKey: .maxInterval) ?? maxInterval
        movementProbability = try c.decodeIfPresent(Double.self, forKey: .movementProbability) ?? movementProbability
        movementRadius = try c.decodeIfPresent(Double.self, forKey: .movementRadius) ?? movementRadius
        breakProbability = try c.decodeIfPresent(Double.self, forKey: .breakProbability) ?? breakProbability
        minBreak = try c.decodeIfPresent(Double.self, forKey: .minBreak) ?? minBreak
        maxBreak = try c.decodeIfPresent(Double.self, forKey: .maxBreak) ?? maxBreak
        button = try c.decodeIfPresent(ClickButton.self, forKey: .button) ?? button
        emergencyCode = try c.decodeIfPresent(UInt32.self, forKey: .emergencyCode) ?? emergencyCode
        emergencyModifiers = try c.decodeIfPresent(UInt32.self, forKey: .emergencyModifiers) ?? emergencyModifiers
        regularClickingEnabled = try c.decodeIfPresent(Bool.self, forKey: .regularClickingEnabled) ?? true
        randomIntervalsEnabled = try c.decodeIfPresent(Bool.self, forKey: .randomIntervalsEnabled) ?? true
        let oldEnabled = try c.decodeIfPresent(Bool.self, forKey: .movementEnabled) ?? true
        breaksEnabled = try c.decodeIfPresent(Bool.self, forKey: .breaksEnabled) ?? true
        clickVariationEnabled = try c.decodeIfPresent(Bool.self, forKey: .clickVariationEnabled) ?? false
        clickVariationRadius = try c.decodeIfPresent(Double.self, forKey: .clickVariationRadius) ?? clickVariationRadius
        let oldMode = try c.decodeIfPresent(MovementMode.self, forKey: .movementMode) ?? .local
        smallMovementEnabled = try c.decodeIfPresent(Bool.self, forKey: .smallMovementEnabled) ?? (oldEnabled && oldMode == .local)
        largeMovementEnabled = try c.decodeIfPresent(Bool.self, forKey: .largeMovementEnabled) ?? (oldEnabled && oldMode == .fullScreen)
        largeMovementProbability = try c.decodeIfPresent(Double.self, forKey: .largeMovementProbability) ?? movementProbability
        largeMovementSpeed = try c.decodeIfPresent(Double.self, forKey: .largeMovementSpeed) ?? 1
        smallClickWhileMoving = try c.decodeIfPresent(Bool.self, forKey: .smallClickWhileMoving) ?? false
        largeClickWhileMoving = try c.decodeIfPresent(Bool.self, forKey: .largeClickWhileMoving) ?? false
        movementDisplayIdentity = try c.decodeIfPresent(String.self, forKey: .movementDisplayIdentity)
        movementRegions = try c.decodeIfPresent([MovementRegionProfile].self, forKey: .movementRegions) ?? []
        secondaryClickEnabled = try c.decodeIfPresent(Bool.self, forKey: .secondaryClickEnabled) ?? false
        secondaryMinInterval = try c.decodeIfPresent(Double.self, forKey: .secondaryMinInterval) ?? 5
        secondaryMaxInterval = try c.decodeIfPresent(Double.self, forKey: .secondaryMaxInterval) ?? 10
        movementDisplayID = try c.decodeIfPresent(UInt32.self, forKey: .movementDisplayID) ?? 0
        timerEnabled = try c.decodeIfPresent(Bool.self, forKey: .timerEnabled) ?? false
        timerHours = try c.decodeIfPresent(Int.self, forKey: .timerHours) ?? timerHours
        timerMinutes = try c.decodeIfPresent(Int.self, forKey: .timerMinutes) ?? timerMinutes
        timerSeconds = try c.decodeIfPresent(Int.self, forKey: .timerSeconds) ?? timerSeconds
        finalClickEnabled = try c.decodeIfPresent(Bool.self, forKey: .finalClickEnabled) ?? false
        finalButton = try c.decodeIfPresent(ClickButton.self, forKey: .finalButton) ?? button
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(minInterval, forKey: .minInterval)
        try c.encode(maxInterval, forKey: .maxInterval)
        try c.encode(movementProbability, forKey: .movementProbability)
        try c.encode(movementRadius, forKey: .movementRadius)
        try c.encode(breakProbability, forKey: .breakProbability)
        try c.encode(minBreak, forKey: .minBreak)
        try c.encode(maxBreak, forKey: .maxBreak)
        try c.encode(button, forKey: .button)
        try c.encode(emergencyCode, forKey: .emergencyCode)
        try c.encode(emergencyModifiers, forKey: .emergencyModifiers)
        try c.encode(regularClickingEnabled, forKey: .regularClickingEnabled)
        try c.encode(randomIntervalsEnabled, forKey: .randomIntervalsEnabled)
        try c.encode(smallMovementEnabled, forKey: .smallMovementEnabled)
        try c.encode(largeMovementEnabled, forKey: .largeMovementEnabled)
        try c.encode(largeMovementSpeed, forKey: .largeMovementSpeed)
        try c.encode(smallClickWhileMoving, forKey: .smallClickWhileMoving)
        try c.encode(largeClickWhileMoving, forKey: .largeClickWhileMoving)
        try c.encode(largeMovementProbability, forKey: .largeMovementProbability)
        try c.encode(movementRegions, forKey: .movementRegions)
        try c.encode(secondaryClickEnabled, forKey: .secondaryClickEnabled)
        try c.encode(secondaryMinInterval, forKey: .secondaryMinInterval)
        try c.encode(secondaryMaxInterval, forKey: .secondaryMaxInterval)
        try c.encode(breaksEnabled, forKey: .breaksEnabled)
        try c.encode(clickVariationEnabled, forKey: .clickVariationEnabled)
        try c.encode(clickVariationRadius, forKey: .clickVariationRadius)
        try c.encode(movementDisplayID, forKey: .movementDisplayID)
        try c.encode(timerEnabled, forKey: .timerEnabled)
        try c.encode(timerHours, forKey: .timerHours)
        try c.encode(timerMinutes, forKey: .timerMinutes)
        try c.encode(timerSeconds, forKey: .timerSeconds)
        try c.encode(finalClickEnabled, forKey: .finalClickEnabled)
        try c.encode(finalButton, forKey: .finalButton)
        try c.encode(movementDisplayIdentity, forKey: .movementDisplayIdentity)
    }
    public var validationError: String? {
        guard [minInterval, maxInterval, movementProbability, movementRadius, breakProbability, minBreak, maxBreak, clickVariationRadius, largeMovementProbability, largeMovementSpeed, secondaryMinInterval, secondaryMaxInterval].allSatisfy(\.isFinite) else { return "Use finite numbers for all settings." }
        guard secondaryMinInterval >= 0.2, secondaryMaxInterval >= secondaryMinInterval, secondaryMaxInterval <= 3600 else { return "Secondary-area intervals must be 0.2–3600 seconds, with maximum at least minimum." }
        guard minInterval >= 0.08, maxInterval >= minInterval, maxInterval <= 3600 else { return "Click intervals must be 0.08–3600 seconds, with maximum at least minimum." }
        guard (0...1).contains(movementProbability), (0...1).contains(largeMovementProbability), (0...1).contains(breakProbability) else { return "Frequencies must be between 0 and 100%." }
        guard (1...10).contains(largeMovementSpeed) else { return "Large-movement speed must be 1×–10×." }
        guard (0...50).contains(movementRadius) else { return "Movement distance must be 0–50 screen points." }
        guard (0...10).contains(clickVariationRadius) else { return "Click variation must be 0–10 screen points." }
        guard (0...999).contains(timerHours), (0...59).contains(timerMinutes), (0...59).contains(timerSeconds), !timerEnabled || timerDuration > 0 else { return "Set a positive timer: hours 0–999, minutes and seconds 0–59." }
        guard minBreak >= 0.2, maxBreak >= minBreak, maxBreak <= 3600 else { return "Breaks must be 0.2–3600 seconds, with maximum at least minimum." }
        guard [UInt32(100), 101, 109, 53].contains(emergencyCode), [UInt32(0), 6144].contains(emergencyModifiers) else { return "Choose an available emergency-stop shortcut." }
        return nil
    }
    public static func load(current: Data?, legacy: Data?) -> ClickSettings {
        if let current, let value = try? JSONDecoder().decode(Self.self, from: current), value.validationError == nil { return value }
        var value = Self()
        if let legacy, let object = (try? JSONSerialization.jsonObject(with: legacy)) as? [String: Any] {
            if let v = object["minInterval"] as? Double { value.minInterval = v }
            if let v = object["maxInterval"] as? Double { value.maxInterval = v }
            if let v = object["movementProbability"] as? Double { value.movementProbability = v }
            if let v = object["pauseProbability"] as? Double { value.breakProbability = v }
            if let v = object["hotkeyCode"] as? UInt32 { value.emergencyCode = v }
            if let v = object["hotkeyModifiers"] as? UInt32 { value.emergencyModifiers = v }
        }
        return value.validationError == nil ? value : Self()
    }
}

public struct ChordLatch {
    public private(set) var pressed: Set<UInt16> = []
    public private(set) var latched = false
    public private(set) var armed = true
    public var keys: Set<UInt16>
    public init(keys: Set<UInt16> = [3, 5, 4]) { self.keys = keys }
    /// Never consumes keys. Rearm only after every chord key is released.
    public mutating func update(code: UInt16, down: Bool, repeated: Bool = false) -> Bool {
        guard keys.contains(code) else { return false }
        if down { pressed.insert(code) } else { pressed.remove(code) }
        if pressed.isEmpty { latched = false; armed = true }
        guard down, !repeated, armed, !latched, pressed == keys else { return false }
        latched = true; return true
    }
    public mutating func requireRelease(currentlyDown: Set<UInt16> = []) {
        pressed = currentlyDown.intersection(keys); latched = false; armed = pressed.isEmpty
    }
}
