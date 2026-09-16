import Foundation
import os

private let historyLogger = Logger(subsystem: "com.molinesdesigns.brewtuibar", category: "ActionHistoryService")

/// Reader for the CLI's action log. Read-only by design: the CLI owns the file
/// and the app must never race it with a write.
enum ActionHistoryService {
    /// Decodes an in-memory payload. Pure, so the on-disk contract can be
    /// pinned in a test without a real `~/.brewtui-bar`.
    static func decode(_ data: Data) throws -> [ActionHistoryEntry] {
        let file = try DataDirectory.makeDecoder().decode(ActionHistoryFile.self, from: data)
        return file.entries.sorted { $0.timestamp > $1.timestamp }
    }

    /// Loads the history, newest first. A missing file is not an error — it
    /// just means the CLI has not run an action yet.
    static func load(from url: URL = DataDirectory.history) async throws -> [ActionHistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let entries = try decode(data)
        historyLogger.info("Loaded \(entries.count) history entries")
        return entries
    }
}
