import CoreLocation
import Foundation

/// What the person needs to know about whether their miles are being captured, in one of three
/// states: ready, recording, or something needing their action.
enum RecordingStatus: Equatable {
    case ready
    case recording
    case actionNeeded(Reason)

    enum Reason: Equatable {
        /// Location is off, denied or restricted: nothing can be detected.
        case locationOff
        /// "While Using" only: drives are missed when the app isn't open.
        case locationNotAlways
        /// Location hasn't been asked for yet.
        case setupIncomplete
        /// The free period ended and there is no plan, so new drives aren't recorded.
        case planExpired
    }

    static func resolve(
        authorization: CLAuthorizationStatus, planAllowsRecording: Bool, isRecording: Bool
    ) -> RecordingStatus {
        switch authorization {
        case .denied, .restricted: return .actionNeeded(.locationOff)
        case .notDetermined: return .actionNeeded(.setupIncomplete)
        default: break
        }
        guard planAllowsRecording else { return .actionNeeded(.planExpired) }
        if authorization == .authorizedWhenInUse { return .actionNeeded(.locationNotAlways) }
        return isRecording ? .recording : .ready
    }

    var title: String {
        switch self {
        case .ready: "Ready to record"
        case .recording: "Recording"
        case .actionNeeded: "Action needed"
        }
    }

    /// One sentence saying why, and what to do about it.
    var explanation: String {
        switch self {
        case .ready:
            "Your drives are logged automatically. Nothing to do."
        case .recording:
            "Your drive is being captured. It finishes by itself when you stop."
        case .actionNeeded(.locationOff):
            "Location is off, so no drives are being recorded. Turn it on to start capturing miles."
        case .actionNeeded(.locationNotAlways):
            "Location is set to While Using, so drives are missed when the app is closed. Choose Always."
        case .actionNeeded(.setupIncomplete):
            "Allow location so drives can be detected automatically."
        case .actionNeeded(.planExpired):
            "Your free period has ended, so new drives aren't being recorded. Subscribe to continue."
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .recording: "record.circle.fill"
        case .actionNeeded: "exclamationmark.triangle.fill"
        }
    }
}
