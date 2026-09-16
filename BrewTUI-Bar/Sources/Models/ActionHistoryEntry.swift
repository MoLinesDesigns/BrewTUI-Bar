import Foundation

/// One row of `~/.brewtui-bar/history.json`, written by the CLI after every
/// action it performs.
///
/// The app has been shipping a "Action History" bullet in the Pro funnel while
/// having no way to show it — the data was on disk the whole time. Field names
/// mirror the CLI's history writer; see CLAUDE.md § Cross-process contract.
struct ActionHistoryEntry: Identifiable, Sendable, Decodable, Equatable {
    let id: String
    let action: String
    /// Null for batch actions (`upgrade-all`, `cleanup`).
    let packageName: String?
    let timestamp: Date
    let success: Bool
    let error: String?

    /// Localized verb for the row. Unknown actions fall back to the raw token
    /// rather than being hidden — a new CLI verb should still show up here.
    var actionLabel: String {
        switch action {
        case "install":     String(localized: "Installed")
        case "uninstall":   String(localized: "Uninstalled")
        case "upgrade":     String(localized: "Upgraded")
        case "upgrade-all": String(localized: "Upgraded everything")
        case "cleanup":     String(localized: "Cleaned up")
        case "pin":         String(localized: "Pinned")
        case "unpin":       String(localized: "Unpinned package")
        default:            action
        }
    }

    var systemImage: String {
        switch action {
        case "install":                 "arrow.down.circle"
        case "uninstall":               "trash"
        case "upgrade", "upgrade-all":  "arrow.up.circle"
        case "cleanup":                 "sparkles"
        case "pin", "unpin":            "pin"
        default:                        "clock"
        }
    }

    /// `Upgraded git` / `Upgraded everything`, ready for a row label.
    var summary: String {
        guard let packageName, !packageName.isEmpty else { return actionLabel }
        return "\(actionLabel) \(packageName)"
    }
}

/// Envelope the CLI writes: `{ "version": 1, "entries": [...] }`.
struct ActionHistoryFile: Sendable, Decodable {
    let version: Int
    let entries: [ActionHistoryEntry]
}
