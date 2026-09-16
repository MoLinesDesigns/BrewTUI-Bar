import Foundation

/// Single place that resolves the cross-process data directory shared with the
/// `brewtui-bar` CLI. The path used to be re-derived in every reader
/// (LastActionMonitor, SecurityMonitor, SyncMonitor, SettingsView); the
/// history / snapshots / profiles readers would have made that seven copies.
///
/// Layout and field names mirror the CLI's `src/lib/data-dir.ts` — see
/// CLAUDE.md § Cross-process contract. Everything here is read-only from the
/// app's side: the CLI owns these files.
enum DataDirectory {
    static var root: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".brewtui-bar", isDirectory: true)
    }

    static var history: URL { root.appendingPathComponent("history.json") }
    static var snapshots: URL { root.appendingPathComponent("snapshots", isDirectory: true) }
    static var profiles: URL { root.appendingPathComponent("profiles", isDirectory: true) }
    static var brewfile: URL { root.appendingPathComponent("brewfile.yaml") }
    static var lastAction: URL { root.appendingPathComponent("last-action.json") }
    static var syncConfig: URL { root.appendingPathComponent("sync-config.json") }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    /// Decoder for every payload the CLI writes. Timestamps are JavaScript
    /// `toISOString()` output — ISO-8601 *with* fractional seconds, which
    /// `.iso8601` rejects outright.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = isoDate(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognised ISO-8601 timestamp: \(raw)"
                )
            }
            return date
        }
        return decoder
    }

    /// Parses both `2026-06-25T22:24:42.191Z` and the fraction-less variant.
    static func isoDate(from raw: String) -> Date? {
        ISODateParser.shared.date(from: raw)
    }
}

/// `ISO8601DateFormatter` is not `Sendable` and the fractional-seconds option
/// has to be flipped per input, so the two formatters live behind a lock
/// instead of as free statics (same `@unchecked Sendable` + `NSLock` shape as
/// `BrewProcess`'s buffers).
private final class ISODateParser: @unchecked Sendable {
    static let shared = ISODateParser()

    private let lock = NSLock()
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(from raw: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }
}
