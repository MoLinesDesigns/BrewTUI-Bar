import Foundation

/// A point-in-time capture of everything installed, written by the CLI into
/// `~/.brewtui-bar/snapshots/<timestamp>-auto.json` before it changes anything.
struct BrewSnapshot: Identifiable, Sendable, Decodable, Equatable {
    struct Entry: Sendable, Decodable, Equatable {
        let name: String
        let version: String
        /// Absent for casks — Homebrew cannot pin them.
        let pinned: Bool?
    }

    /// Filename, which is also the natural sort key and unique per capture.
    var id: String { fileName }
    var fileName: String = ""
    let capturedAt: Date
    let formulae: [Entry]
    let casks: [Entry]
    let taps: [String]

    enum CodingKeys: String, CodingKey {
        case capturedAt, formulae, casks, taps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        // Older CLI snapshots predate the cask/tap arrays; treat their absence
        // as empty rather than failing the decode and losing the whole file.
        formulae = try container.decodeIfPresent([Entry].self, forKey: .formulae) ?? []
        casks = try container.decodeIfPresent([Entry].self, forKey: .casks) ?? []
        taps = try container.decodeIfPresent([String].self, forKey: .taps) ?? []
    }

    var packageCount: Int { formulae.count + casks.count }

    /// Flat `name → version` map used by the diff.
    var versionsByName: [String: String] {
        var result: [String: String] = [:]
        for entry in formulae + casks { result[entry.name] = entry.version }
        return result
    }
}

/// What changed between two capture points (or between a capture and the
/// machine right now).
struct SnapshotDiff: Sendable, Equatable {
    struct Change: Identifiable, Sendable, Equatable {
        var id: String { name }
        let name: String
        let from: String
        let to: String
    }

    var added: [String] = []
    var removed: [String] = []
    var changed: [Change] = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
    var totalCount: Int { added.count + removed.count + changed.count }
}
