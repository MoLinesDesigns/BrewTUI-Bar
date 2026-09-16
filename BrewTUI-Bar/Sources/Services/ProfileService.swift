import Foundation
import os

private let profileLogger = Logger(subsystem: "com.molinesdesigns.brewtuibar", category: "ProfileService")

/// Reads the CLI's saved profiles and the exported Brewfile.
enum ProfileService {
    static func decode(_ data: Data, fileName: String) throws -> BrewProfile {
        var profile = try DataDirectory.makeDecoder().decode(BrewProfile.self, from: data)
        profile.fileName = fileName
        return profile
    }

    static func list(in directory: URL = DataDirectory.profiles) async throws -> [BrewProfile] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }

        var profiles: [BrewProfile] = []
        for file in files {
            do {
                profiles.append(try decode(try Data(contentsOf: file), fileName: file.lastPathComponent))
            } catch {
                profileLogger.warning("Skipping unreadable profile \(file.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Metadata of the exported `brewfile.yaml`, if the CLI has written one.
    /// Deliberately not a YAML parse: the app only needs to say whether a
    /// Brewfile exists, how big it is and when it was written, and pulling in a
    /// YAML dependency to count list items would be the wrong trade.
    static func brewfileStatus(at url: URL = DataDirectory.brewfile) -> BrewfileStatus? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path),
              let attributes = try? manager.attributesOfItem(atPath: url.path)
        else { return nil }
        let entryCount = (try? String(contentsOf: url, encoding: .utf8))
            .map { text in
                text.split(separator: "\n").filter { $0.hasPrefix("  - name:") }.count
            }
        return BrewfileStatus(
            url: url,
            modifiedAt: attributes[.modificationDate] as? Date,
            entryCount: entryCount ?? 0
        )
    }
}

struct BrewfileStatus: Sendable, Equatable {
    let url: URL
    let modifiedAt: Date?
    let entryCount: Int
}
