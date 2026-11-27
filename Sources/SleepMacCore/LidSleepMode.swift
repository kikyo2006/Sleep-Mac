import Foundation

/// How "Sleep When Lid Closes" finds out that the lid is shut. Only one way is active at a time.
///
/// The choice is stored in the two guards' own settings (`LidSleepGuard.isEnabled` and
/// `DarkLidGuard.isEnabled`); this type keeps them mutually exclusive.
public enum LidSleepMode: Int, CaseIterable {
    case off
    /// The lid switch reported by macOS (`LidSleepGuard`).
    case lidSensor
    /// The ambient light sensor going dark, for a lid switch that never reports a closed lid (`DarkLidGuard`).
    case lightSensor

    public var title: String {
        switch self {
        case .off: return "Off"
        case .lidSensor: return "Lid Sensor"
        case .lightSensor: return "Light Sensor"
        }
    }

    /// The mode the two stored settings describe. When both are on (possible with settings saved before
    /// there was a single choice), the light sensor wins: it was turned on on purpose, the lid sensor is on by default.
    public static func from(lidEnabled: Bool, lightEnabled: Bool) -> LidSleepMode {
        if lightEnabled { return .lightSensor }
        if lidEnabled { return .lidSensor }
        return .off
    }

    public var enablesLidSensor: Bool { self == .lidSensor }
    public var enablesLightSensor: Bool { self == .lightSensor }
}
