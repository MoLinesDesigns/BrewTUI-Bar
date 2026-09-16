import Foundation
import os

private let maintenanceLogger = Logger(subsystem: "com.molinesdesigns.brewtuibar", category: "MaintenanceService")

/// One `Would remove:` / `Removing:` line of `brew cleanup`.
struct CleanupEntry: Identifiable, Sendable, Equatable {
    var id: String { path }
    let path: String
    let bytes: Int64
    let fileCount: Int?

    /// Last path component — the full Cellar path is too long for a row and
    /// the interesting part is always the tail.
    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var formattedSize: String { ByteFormat.string(from: bytes) }
}

struct CleanupReport: Sendable, Equatable {
    var entries: [CleanupEntry] = []
    /// Sum of the per-entry sizes. This is the number the UI shows.
    var totalBytes: Int64 = 0
    /// What brew's own summary line claimed, when it printed one. Kept only as
    /// a cross-check: the summary wording has changed between brew versions
    /// ("would free" / "has freed"), so trusting it as the single source would
    /// silently read 0 after an upgrade.
    var summaryBytes: Int64?
    var isEmpty: Bool { entries.isEmpty && totalBytes == 0 }

    var formattedTotal: String { ByteFormat.string(from: totalBytes) }
}

/// `brew cleanup`, `brew autoremove` and `brew doctor`.
///
/// None of these had a surface in the app, so reclaiming disk space meant
/// opening a terminal — while the popover was advertising "Smart Cleanup" as a
/// Pro feature of the CLI.
enum MaintenanceService {
    /// Cleanup walks the whole Cellar and the download cache; on a large
    /// machine the dry run alone takes a while.
    private static let cleanupTimeout: TimeInterval = 10 * 60
    private static let doctorTimeout: TimeInterval = 5 * 60

    // MARK: - Cleanup

    static func previewCleanup() async throws -> CleanupReport {
        let result = try await BrewProcess.runResult(["cleanup", "-n"], timeout: cleanupTimeout)
        guard result.isSuccess else {
            throw BrewProcessError.commandFailed(result.failureReason)
        }
        return parseCleanup(result.outputString + "\n" + result.errorOutput)
    }

    static func runCleanup() async throws -> CleanupReport {
        let result = try await BrewProcess.runResult(["cleanup"], timeout: cleanupTimeout)
        guard result.isSuccess else {
            if result.needsAdminPassword {
                throw BrewProcessError.needsAdminPassword(command: "brew cleanup")
            }
            throw BrewProcessError.commandFailed(result.failureReason)
        }
        return parseCleanup(result.outputString + "\n" + result.errorOutput)
    }

    // MARK: - Autoremove

    static func previewAutoremove() async throws -> [String] {
        let result = try await BrewProcess.runResult(["autoremove", "-n"], timeout: cleanupTimeout)
        guard result.isSuccess else {
            throw BrewProcessError.commandFailed(result.failureReason)
        }
        return parseAutoremove(result.outputString + "\n" + result.errorOutput)
    }

    static func runAutoremove() async throws -> [String] {
        let result = try await BrewProcess.runResult(["autoremove"], timeout: cleanupTimeout)
        guard result.isSuccess else {
            if result.needsAdminPassword {
                throw BrewProcessError.needsAdminPassword(command: "brew autoremove")
            }
            throw BrewProcessError.commandFailed(result.failureReason)
        }
        return parseAutoremove(result.outputString + "\n" + result.errorOutput)
    }

    // MARK: - Doctor

    /// `brew doctor` exits **non-zero whenever it has anything to say**, which
    /// is the normal case — treating that as a failure would show an error
    /// instead of the diagnostics the user asked for.
    static func doctor() async throws -> String {
        let result = try await BrewProcess.runResult(["doctor"], timeout: doctorTimeout)
        let combined = [result.outputString, result.errorOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if combined.isEmpty {
            return String(localized: "Your system is ready to brew.")
        }
        return combined
    }

    // MARK: - Brewfile

    /// `brew bundle dump` — a real Homebrew command, unlike a CLI subcommand
    /// for it (there is none). Writes a Brewfile the user can move between
    /// machines.
    static func dumpBrewfile(to url: URL) async throws {
        try await BrewProcess.runAction(
            ["bundle", "dump", "--force", "--file=\(url.path)"],
            terminalCommand: "brew bundle dump --force --file='\(url.path)'",
            timeout: cleanupTimeout
        )
    }

    // MARK: - Parsers (pure — pinned by tests)

    /// Parses `brew cleanup` output in both dry-run and real form.
    ///
    /// The per-entry sizes are summed rather than reading brew's summary line,
    /// because that line is the part most likely to change wording between
    /// versions. The summary is still captured so a future mismatch is
    /// visible instead of silent.
    static func parseCleanup(_ output: String) -> CleanupReport {
        var report = CleanupReport()
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = BrewUpgradeStream.stripANSI(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.contains("approximately") {
                // "==> This operation would free approximately 34.6MB of disk space."
                // "==> This operation has freed approximately 1.2GB of disk space."
                if let range = line.range(of: "approximately ") {
                    let tail = line[range.upperBound...]
                    let token = tail.split(separator: " ").first.map(String.init) ?? ""
                    report.summaryBytes = parseSize(token)
                }
                continue
            }

            guard let prefixRange = line.range(of: "Would remove: ") ?? line.range(of: "Removing: ") else { continue }
            let remainder = String(line[prefixRange.upperBound...])
            guard let openParen = remainder.lastIndex(of: "("),
                  let closeParen = remainder.lastIndex(of: ")"),
                  openParen < closeParen
            else {
                // No size in parentheses — record the path so the count is
                // still right, with zero bytes.
                report.entries.append(CleanupEntry(path: cleanPath(remainder), bytes: 0, fileCount: nil))
                continue
            }

            let path = cleanPath(String(remainder[remainder.startIndex..<openParen]))
            let inside = String(remainder[remainder.index(after: openParen)..<closeParen])
            // "1,707 files, 34.6MB" or just "34.6MB". Splitting on commas alone
            // is not enough: brew groups thousands with commas too, so
            // "1,707 files" would come back as two components and the count
            // would read 707.
            var fileCount: Int?
            if let filesRange = inside.range(of: "file") {
                let digits = inside[..<filesRange.lowerBound].filter(\.isNumber)
                fileCount = Int(digits)
            }
            let bytes = inside
                .split(separator: ",")
                .compactMap { parseSize(String($0)) }
                .last ?? 0
            report.entries.append(CleanupEntry(path: path, bytes: bytes, fileCount: fileCount))
        }
        report.totalBytes = report.entries.reduce(0) { $0 + $1.bytes }
        return report
    }

    /// Strips the trailing `...` brew appends to in-progress paths.
    private static func cleanPath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespaces)
        while path.hasSuffix(".") { path.removeLast() }
        return path
    }

    /// `34.6MB` → bytes. Homebrew formats with 1024-based units, so the
    /// conversion matches what the terminal showed.
    static func parseSize(_ raw: String) -> Int64? {
        let token = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !token.isEmpty else { return nil }
        let units: [(suffix: String, multiplier: Double)] = [
            ("TB", 1024 * 1024 * 1024 * 1024),
            ("GB", 1024 * 1024 * 1024),
            ("MB", 1024 * 1024),
            ("KB", 1024),
            ("B", 1),
        ]
        for unit in units where token.uppercased().hasSuffix(unit.suffix) {
            let numberPart = String(token.dropLast(unit.suffix.count))
            guard let value = Double(numberPart) else { return nil }
            return Int64(value * unit.multiplier)
        }
        return nil
    }

    /// Names listed by `brew autoremove [-n]` under its `==>` header.
    static func parseAutoremove(_ output: String) -> [String] {
        var names: [String] = []
        var inList = false
        for rawLine in output.split(separator: "\n") {
            let line = BrewUpgradeStream.stripANSI(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("==>") {
                // "==> Would autoremove 3 unneeded formulae:" /
                // "==> Autoremoving 3 unneeded formulae:"
                inList = line.lowercased().contains("autoremov")
                continue
            }
            guard inList else { continue }
            // Package names never contain spaces; anything else is prose brew
            // printed after the list.
            guard !line.contains(" ") else {
                inList = false
                continue
            }
            names.append(line)
        }
        return names
    }
}
