import Foundation

/// Lets App Intents reach the app's single running `TunnelManager`. There's no
/// daemon/NEPacketTunnelProvider owning tunnel state independently of the app, so
/// an intent can only act while WireTunnels is actually running — accepted
/// limitation, see AppIntentError.appNotReady.
@MainActor
enum AppIntentBridge {
    static var tunnelManager: TunnelManager?
}

enum AppIntentError: LocalizedError {
    case appNotReady

    var errorDescription: String? {
        switch self {
        case .appNotReady:
            return "WireTunnels is still starting — try again in a moment."
        }
    }
}
