import Foundation
import os

private let inventoryLogger = Logger(subsystem: "com.molinesdesigns.brewtuibar", category: "InventoryService")

/// Reads the full set of installed formulae and casks.
///
/// `SecurityMonitor` already shelled out to `brew list --versions` for its CVE
/// matching, but nothing surfaced that list to the user: the app could tell you
/// what was *outdated* and nothing about what you actually had installed.
enum InventoryService {
    /// `brew list` on a large machine is fast (it reads the Cellar directory)
    /// but not instant; give it more room than the default.
    private static let listTimeout: TimeInterval = 90

    /// Result of an inventory read. `warning` is non-nil when one of the two
    /// listings failed but the other worked — on a machine with a third-party
    /// tap, `brew list --versions --cask` can exit 1 with
    /// "Refusing to load cask … from untrusted tap" while formulae list fine.
    /// Failing the whole load there would have shown an empty window and an
    /// error, hiding two hundred perfectly readable formulae.
    struct Result: Sendable {
        let packages: [InstalledPackage]
        let warning: String?
    }

    static func load() async throws -> Result {
        async let formulaResult = BrewProcess.runResult(["list", "--versions", "--formula"], timeout: listTimeout)
        async let caskResult = BrewProcess.runResult(["list", "--versions", "--cask"], timeout: listTimeout)
        // `brew leaves` fails outright on a machine with no formulae; a missing
        // leaf list only costs the "safe to remove" hint, so it must not take
        // the whole inventory down with it.
        async let leavesOutput = optionalRun(["leaves"])

        let formulaOutcome = try await formulaResult
        let caskOutcome = try await caskResult
        guard formulaOutcome.isSuccess || caskOutcome.isSuccess else {
            throw BrewProcessError.commandFailed(formulaOutcome.failureReason)
        }

        let leaves = Set(parseNames(await leavesOutput ?? ""))
        let formulae = formulaOutcome.isSuccess
            ? parseVersions(formulaOutcome.outputString).map { entry in
                InstalledPackage(
                    name: entry.name,
                    versions: entry.versions,
                    kind: .formula,
                    isLeaf: leaves.contains(entry.name),
                    sizeBytes: nil
                )
            }
            : []
        // Casks have no dependents, so "leaf" is vacuously true for them;
        // marking them otherwise would make the "safe to remove" filter lie.
        let casks = caskOutcome.isSuccess
            ? parseVersions(caskOutcome.outputString).map { entry in
                InstalledPackage(name: entry.name, versions: entry.versions, kind: .cask, isLeaf: true, sizeBytes: nil)
            }
            : []

        var warning: String?
        if !formulaOutcome.isSuccess {
            warning = String(format: String(localized: "Could not list formulae: %@"), formulaOutcome.failureReason)
        } else if !caskOutcome.isSuccess {
            warning = String(format: String(localized: "Could not list casks: %@"), caskOutcome.failureReason)
        }

        inventoryLogger.info("Inventory: \(formulae.count) formulae, \(casks.count) casks")
        return Result(
            packages: (formulae + casks).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            warning: warning
        )
    }

    private static func optionalRun(_ arguments: [String]) async -> String? {
        try? await BrewProcess.runString(arguments, timeout: listTimeout)
    }

    /// Parses `brew list --versions` output: `name version [version…]`, one per
    /// line. Pure so the format can be pinned in a test without spawning brew.
    static func parseVersions(_ output: String) -> [(name: String, versions: [String])] {
        output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: " ").map(String.init)
                guard let name = parts.first, !name.isEmpty else { return nil }
                return (name: name, versions: Array(parts.dropFirst()))
            }
    }

    static func parseNames(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Disk usage

    /// Root directories Homebrew keeps packages in. Resolved once per call
    /// through brew itself so a non-default prefix (Intel, Linuxbrew, a custom
    /// `HOMEBREW_PREFIX`) is honoured instead of hardcoded.
    static func roots() async -> (cellar: URL?, caskroom: URL?) {
        async let cellar = try? BrewProcess.runString(["--cellar"])
        async let caskroom = try? BrewProcess.runString(["--caskroom"])
        func url(_ raw: String?) -> URL? {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        return (url(await cellar), url(await caskroom))
    }

    /// Sums the allocated size of `directory`. Runs off the main actor; a
    /// 200-package Cellar means walking hundreds of thousands of files, which
    /// is why size is an explicit user action and not part of `load()`.
    static func directorySize(at directory: URL) -> Int64? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return nil }
        guard let enumerator = manager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.totalFileAllocatedSize
            else { continue }
            total += Int64(size)
        }
        return total
    }
}
