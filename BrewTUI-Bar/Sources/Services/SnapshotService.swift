import Foundation
import os

private let snapshotLogger = Logger(subsystem: "com.molinesdesigns.brewtuibar", category: "SnapshotService")

/// Lists and diffs the CLI's snapshots.
///
/// Rolling *back* stays with the CLI — it is a destructive, long-running
/// operation that wants a terminal. What the app adds is the part that was
/// missing: being able to see what changed, and when, without reading JSON by
/// hand.
enum SnapshotService {
    static func decode(_ data: Data, fileName: String) throws -> BrewSnapshot {
        var snapshot = try DataDirectory.makeDecoder().decode(BrewSnapshot.self, from: data)
        snapshot.fileName = fileName
        return snapshot
    }

    /// Newest first. Missing directory → empty list, same reasoning as history.
    static func list(in directory: URL = DataDirectory.snapshots) async throws -> [BrewSnapshot] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        var snapshots: [BrewSnapshot] = []
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                snapshots.append(try decode(data, fileName: file.lastPathComponent))
            } catch {
                // One corrupt snapshot must not hide the other forty.
                snapshotLogger.warning("Skipping unreadable snapshot \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return snapshots.sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Pure diff between two `name → version` maps. `base` is the older side.
    static func diff(base: [String: String], target: [String: String]) -> SnapshotDiff {
        var result = SnapshotDiff()
        for (name, version) in target {
            guard let previous = base[name] else {
                result.added.append(name)
                continue
            }
            if previous != version {
                result.changed.append(SnapshotDiff.Change(name: name, from: previous, to: version))
            }
        }
        result.removed = base.keys.filter { target[$0] == nil }
        result.added.sort()
        result.removed.sort()
        result.changed.sort { $0.name < $1.name }
        return result
    }

    static func diff(from base: BrewSnapshot, to target: BrewSnapshot) -> SnapshotDiff {
        diff(base: base.versionsByName, target: target.versionsByName)
    }

    /// Diff of a snapshot against what is installed right now. This is the one
    /// users actually ask for ("what changed since Friday?"), and it is why the
    /// inventory had to exist first.
    static func diff(from base: BrewSnapshot, toInstalled installed: [InstalledPackage]) -> SnapshotDiff {
        var current: [String: String] = [:]
        for package in installed { current[package.name] = package.displayVersion }
        return diff(base: base.versionsByName, target: current)
    }
}
