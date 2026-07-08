import Foundation
import os

/// Cross-platform version contract: BrewTUI-Bar's marketing version must match
/// the BrewTUI-Bar CLI it talks to (license schema + future IPC). On mismatch we
/// surface a non-blocking warning at launch — license decryption may still
/// succeed today, but skew is the early signal that something will break.
struct VersionChecker {
    private static let logger = Logger(subsystem: "com.molinesdesigns.brewtuibar", category: "VersionChecker")

    enum Status: Equatable {
        case match(brewTUIBar: String)
        case mismatch(brewTUIBar: String, brewBar: String)
        case unknown // brewtui-bar present but version unreadable
    }

    /// Marketing version embedded in BrewTUI-Bar's bundle.
    static var brewBarVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Calls `brewtui-bar --version` and parses the single-line output.
    /// Returns nil if brewtui-bar is missing or the call fails.
    static func brewTUIBarVersion() async -> String? {
        let executable = await locateBrewTUIBar()
        guard let executable else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in cont.resume() }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } catch {
            logger.error("brewtui-bar --version failed to launch: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Defensive: accept either "0.7.0" or "vX.Y.Z" or any token starting with a digit.
        guard let token = raw.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
              !token.isEmpty
        else {
            logger.error("brewtui-bar --version returned empty output")
            return nil
        }
        return token.hasPrefix("v") ? String(token.dropFirst()) : token
    }

    static func check() async -> Status {
        guard let cliVersion = await brewTUIBarVersion() else {
            return .unknown
        }
        if cliVersion == brewBarVersion {
            return .match(brewTUIBar: cliVersion)
        }
        return .mismatch(brewTUIBar: cliVersion, brewBar: brewBarVersion)
    }

    // MARK: - Helpers

    private static func locateBrewTUIBar() async -> String? {
        let knownPaths = [
            "/opt/homebrew/bin/brewtui-bar",
            "/usr/local/bin/brewtui-bar",
            "\(NSHomeDirectory())/.npm/bin/brewtui-bar",
        ]
        for path in knownPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        // Fallback: ask the shell PATH via /usr/bin/which
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["brewtui-bar"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in cont.resume() }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }
}
