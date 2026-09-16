import Foundation
import os

private let brewProcessLogger = Logger(subsystem: "com.molinesdesigns.brewtuibar", category: "BrewProcess")

enum BrewProcessError: LocalizedError {
    case brewNotInstalled
    case processExited(Int32)
    case timeout
    /// brew refused because it needed an administrator password and had no TTY
    /// to ask from. Carries the shell command the user should run instead.
    case needsAdminPassword(command: String)
    /// Non-zero exit where brew told us why on stderr.
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .brewNotInstalled:
            String(localized: "Homebrew is not installed. Install it from https://brew.sh")
        case .processExited(let code):
            String(format: String(localized: "brew exited with code %lld"), Int64(code))
        case .timeout:
            String(localized: "brew command timed out")
        case .needsAdminPassword:
            String(localized: "Homebrew needs an administrator password for this and cannot ask for it from the menu bar. Run it in Terminal.")
        case .commandFailed(let reason):
            reason
        }
    }

    /// Shell command to hand off to Terminal, when there is one.
    var terminalCommand: String? {
        if case .needsAdminPassword(let command) = self { return command }
        return nil
    }
}

/// Outcome of a brew invocation that is allowed to fail. `BrewProcess.run`
/// throws on a non-zero exit; callers that need brew's own explanation (service
/// control, pin, cleanup) use `runResult` and read `errorOutput` themselves.
struct BrewCommandResult: Sendable {
    let status: Int32
    let output: Data
    let errorOutput: String

    var isSuccess: Bool { status == 0 }
    var outputString: String { String(decoding: output, as: UTF8.self) }

    /// True when the failure is sudo asking for a password we cannot provide.
    var needsAdminPassword: Bool {
        errorOutput
            .split(separator: "\n")
            .contains { BrewUpgradeStream.isSudoPasswordFailure(BrewUpgradeStream.stripANSI(String($0)).trimmingCharacters(in: .whitespaces)) }
    }

    /// Best-effort human reason: brew's own `Error:` line when it printed one,
    /// otherwise the last non-empty stderr line, otherwise the exit code.
    var failureReason: String {
        let lines = errorOutput
            .split(separator: "\n")
            .map { BrewUpgradeStream.stripANSI(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let errorLine = lines.first(where: { $0.hasPrefix("Error:") }) {
            return String(errorLine.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces)
        }
        if let last = lines.last { return last }
        return String(format: String(localized: "brew exited with code %lld"), Int64(status))
    }
}

/// Resolves the Homebrew executable. Apple Silicon default with Intel/Linux fallbacks.
enum BrewExecutable {
    static let path: String = {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
            "/home/linuxbrew/.linuxbrew/bin/brew",
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? candidates[0]
    }()
}

/// Shared brew process runner. Spawns `brew` with the given arguments, enforces a
/// timeout, and returns stdout as `Data`. The timeout `Task` is cancelled when the
/// process terminates normally so it does not outlive the call.
enum BrewProcess {
    static let defaultTimeout: TimeInterval = 60

    /// Throwing variant: returns stdout and turns a non-zero exit into an error.
    /// Unchanged contract for every existing caller (`outdated`, `services list`,
    /// `info --json=v2`, …).
    static func run(
        _ arguments: [String],
        suppressAutoUpdate: Bool = true,
        timeout: TimeInterval = BrewProcess.defaultTimeout,
        executable: String = BrewExecutable.path
    ) async throws -> Data {
        let result = try await runResult(
            arguments,
            suppressAutoUpdate: suppressAutoUpdate,
            timeout: timeout,
            executable: executable
        )
        guard result.isSuccess else {
            throw BrewProcessError.processExited(result.status)
        }
        return result.output
    }

    /// Non-throwing variant (except for launch/timeout failures): hands back the
    /// exit status alongside both streams so the caller can decide what a
    /// failure means. stderr is captured rather than discarded — a `sudo`
    /// refusal says nothing on stdout, and throwing away stderr is how service
    /// control would have degraded to a bare "exited with code 1".
    static func runResult(
        _ arguments: [String],
        suppressAutoUpdate: Bool = true,
        timeout: TimeInterval = BrewProcess.defaultTimeout,
        executable: String = BrewExecutable.path
    ) async throws -> BrewCommandResult {
        brewProcessLogger.info("Running brew \(arguments.joined(separator: " "), privacy: .public)")

        // Thread-safe exactly-once continuation wrapper. The continuation, the
        // Process and the Pipe all cross actor boundaries via the termination
        // handler (GCD thread) and the timeout Task. The lock guarantees a
        // single resume(...) regardless of which path wins the race.
        final class OnceGuard: @unchecked Sendable {
            private var resumed = false
            private let lock = NSLock()
            private let continuation: CheckedContinuation<BrewCommandResult, Error>

            init(_ continuation: CheckedContinuation<BrewCommandResult, Error>) {
                self.continuation = continuation
            }

            func resume(with result: Result<BrewCommandResult, Error>) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return false }
                resumed = true
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
                return true
            }
        }

        // Box the timeout task reference so the termination handler can cancel
        // it. Using a class avoids capturing a `var` in the @Sendable closure.
        final class TimeoutBox: @unchecked Sendable {
            var task: Task<Void, Never>?
        }
        let timeoutBox = TimeoutBox()

        // Thread-safe buffer that the readability handler appends to while the
        // process is still running. Letting the kernel pipe buffer fill up
        // (~64 KB on macOS) used to deadlock `brew search`/`brew outdated --json`
        // on machines with thousands of formulae: the writer blocked, never
        // reached its termination handler, and the synchronous
        // `readDataToEndOfFile()` we used to call there waited forever.
        final class DataBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ chunk: Data) {
                lock.lock(); defer { lock.unlock() }
                data.append(chunk)
            }
            func snapshot() -> Data {
                lock.lock(); defer { lock.unlock() }
                return data
            }
        }
        let buffer = DataBuffer()
        let errorBuffer = DataBuffer()

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let errorPipe = Pipe()
            let onceGuard = OnceGuard(continuation)

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = errorPipe

            var extraEnv: [String: String] = [:]
            if suppressAutoUpdate { extraEnv["HOMEBREW_NO_AUTO_UPDATE"] = "1" }
            extraEnv["HOMEBREW_NO_ENV_HINTS"] = "1"
            process.environment = ProcessInfo.processInfo.environment.merging(extraEnv) { _, new in new }

            // Drain both streams incrementally so neither kernel buffer fills.
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil // EOF
                } else {
                    buffer.append(chunk)
                }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil // EOF
                } else {
                    errorBuffer.append(chunk)
                }
            }

            process.terminationHandler = { proc in
                // Detach the streaming readers, then drain anything still in the
                // pipes. The process has closed its write ends by now, so these
                // final reads are bounded and cannot deadlock.
                pipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                if let remaining = try? pipe.fileHandleForReading.readToEnd(),
                   !remaining.isEmpty {
                    buffer.append(remaining)
                }
                if let remaining = try? errorPipe.fileHandleForReading.readToEnd(),
                   !remaining.isEmpty {
                    errorBuffer.append(remaining)
                }
                let result = BrewCommandResult(
                    status: proc.terminationStatus,
                    output: buffer.snapshot(),
                    errorOutput: String(decoding: errorBuffer.snapshot(), as: UTF8.self)
                )
                if onceGuard.resume(with: .success(result)) {
                    // Process finished first — cancel the pending timeout so it
                    // does not stay alive sleeping until the deadline.
                    timeoutBox.task?.cancel()
                }
            }

            do {
                try process.run()
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                brewProcessLogger.error("Homebrew not found at \(executable, privacy: .public)")
                _ = onceGuard.resume(with: .failure(BrewProcessError.brewNotInstalled))
                return
            } catch {
                brewProcessLogger.error("Failed to launch brew: \(error.localizedDescription, privacy: .public)")
                _ = onceGuard.resume(with: .failure(error))
                return
            }

            timeoutBox.task = Task {
                do {
                    try await Task.sleep(for: .seconds(timeout))
                } catch {
                    return // cancelled — process completed normally
                }
                if process.isRunning {
                    brewProcessLogger.error("brew command timed out after \(timeout, privacy: .public)s")
                    process.terminate()
                    _ = onceGuard.resume(with: .failure(BrewProcessError.timeout))
                }
            }
        }
    }

    /// String convenience: decodes stdout as UTF-8 (replaces invalid bytes).
    static func runString(
        _ arguments: [String],
        suppressAutoUpdate: Bool = true,
        timeout: TimeInterval = BrewProcess.defaultTimeout
    ) async throws -> String {
        let data = try await run(arguments, suppressAutoUpdate: suppressAutoUpdate, timeout: timeout)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Runs a mutating brew command and maps its failure modes to
    /// `BrewProcessError`. `terminalCommand` is what the user should paste into
    /// a shell when the action turns out to need `sudo`.
    @discardableResult
    static func runAction(
        _ arguments: [String],
        terminalCommand: String,
        timeout: TimeInterval = BrewProcess.defaultTimeout
    ) async throws -> String {
        let result = try await runResult(arguments, timeout: timeout)
        guard result.isSuccess else {
            if result.needsAdminPassword {
                throw BrewProcessError.needsAdminPassword(command: terminalCommand)
            }
            throw BrewProcessError.commandFailed(result.failureReason)
        }
        return result.outputString
    }
}
