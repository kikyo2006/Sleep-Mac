import Foundation
import ServiceManagement

public enum LoginItemStatus: Equatable {
    case enabled
    case disabled
    /// Registered, but the user still has to allow it in System Settings → General → Login Items.
    case requiresApproval
    /// macOS cannot find the app to register (for example when it does not run from an app bundle).
    case unavailable
}

/// Seam over `SMAppService` so the toggle logic can be unit-tested without touching the user's Login Items.
public protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
}

public struct SystemLoginItemService: LoginItemService {
    public init() {}

    private var service: SMAppService { SMAppService.mainApp }

    public var status: LoginItemStatus {
        switch service.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    public func register() throws { try service.register() }
    public func unregister() throws { try service.unregister() }

    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// "Launch at Login" switch: one call flips it on or off.
public final class LaunchAtLogin {
    public enum Outcome: Equatable {
        case enabled
        case disabled
        /// The user has to switch Sleep Mac on in System Settings → General → Login Items.
        case requiresApproval
        case failed(String)
    }

    private let service: LoginItemService

    public init(service: LoginItemService = SystemLoginItemService()) {
        self.service = service
    }

    public var status: LoginItemStatus { service.status }
    public var isEnabled: Bool { status == .enabled }

    /// Enabled → disabled, disabled → enabled.
    public func toggle() -> Outcome {
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
                return .disabled
            case .requiresApproval:
                // Already registered; only the user can approve it in System Settings.
                return .requiresApproval
            case .disabled, .unavailable:
                try service.register()
                switch service.status {
                case .enabled:
                    return .enabled
                case .requiresApproval:
                    return .requiresApproval
                case .disabled, .unavailable:
                    return .failed("macOS did not register Sleep Mac as a login item. Move the app to the Applications folder and try again.")
                }
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
