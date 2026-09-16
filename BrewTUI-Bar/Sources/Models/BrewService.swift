import Foundation

struct BrewService: Identifiable, Codable, Sendable {
    var id: String { name }
    let name: String
    let status: String
    let user: String?
    let file: String?
    let exitCode: Int?

    enum CodingKeys: String, CodingKey {
        case name, status, user, file
        case exitCode = "exit_code"
    }

    var hasError: Bool { status == "error" }
    var isRunning: Bool { status == "started" }
    /// `brew services` reports `none` for a formula that ships a plist but has
    /// never been started, and `stopped`/`unknown` once it has.
    var isStopped: Bool { !isRunning && !hasError }

    /// Localized, human-facing status. `brew services list` emits raw English
    /// tokens; the popover used to only ever show `error`, so they were never
    /// translated.
    var statusLabel: String {
        switch status {
        case "started":  String(localized: "Running")
        case "scheduled": String(localized: "Scheduled")
        case "error":    String(localized: "Error")
        case "stopped":  String(localized: "Stopped")
        case "none":     String(localized: "Not started")
        default:         status
        }
    }
}

/// The three mutating verbs `brew services` accepts. Kept as a model type so
/// the command string exists in exactly one place — the UI, the confirmation
/// copy and the Terminal handoff all derive from it.
enum BrewServiceAction: String, Sendable, CaseIterable {
    case start
    case stop
    case restart

    var label: String {
        switch self {
        case .start:   String(localized: "Start")
        case .stop:    String(localized: "Stop")
        case .restart: String(localized: "Restart")
        }
    }

    var systemImage: String {
        switch self {
        case .start:   "play.fill"
        case .stop:    "stop.fill"
        case .restart: "arrow.clockwise"
        }
    }
}
