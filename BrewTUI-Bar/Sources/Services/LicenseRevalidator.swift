import Foundation
import os

/// Silently refreshes the local license envelope via `brewtui-bar revalidate`.
/// BrewTUI-Bar reads license.json offline; when degradation blocks Pro but
/// the subscription is still active, this self-heals without user intervention.
enum LicenseRevalidator {
    private static let logger = Logger(
        subsystem: "com.molinesdesigns.brewtuibar",
        category: "LicenseRevalidator"
    )

    /// Runs `brewtui-bar revalidate` when a recoverable license exists. Returns
    /// true when the CLI exits 0 (valid or grace).
    @discardableResult
    static func revalidateIfNeeded() async -> Bool {
        guard LicenseChecker.recoverableLicense() != nil else {
            return false
        }

        guard let executable = await locateBrewTUIBar() else {
            logger.warning("brewtui-bar not found — skipping auto-revalidation")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["revalidate"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            let exitCode: Int32 = try await withCheckedThrowingContinuation { cont in
                process.terminationHandler = { proc in
                    cont.resume(returning: proc.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            if exitCode == 0 {
                logger.info("Auto-revalidation succeeded")
                return true
            }
            logger.info("Auto-revalidation failed with exit code \(exitCode, privacy: .public)")
            return false
        } catch {
            logger.error("Auto-revalidation could not launch brewtui-bar: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func locateBrewTUIBar() async -> String? {
        let knownPaths = [
            "/opt/homebrew/bin/brewtui-bar",
            "/usr/local/bin/brewtui-bar",
            "\(NSHomeDirectory())/.npm/bin/brewtui-bar",
        ]
        for path in knownPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

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
