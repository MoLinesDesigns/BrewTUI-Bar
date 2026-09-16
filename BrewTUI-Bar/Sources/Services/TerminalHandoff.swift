import AppKit
import Foundation

/// Hands a command off to the user's terminal app through a one-shot
/// `.command` script.
///
/// Four call sites had grown their own copy of this (open the TUI, self
/// upgrade, sudo-blocked upgrade, license revalidation), and every new action
/// that can hit `sudo` — service control, cleanup, profile apply — needs the
/// same escape hatch: brew cannot prompt for a password without a TTY, and we
/// deliberately do not run privileged helpers from the menu bar.
enum TerminalHandoff {
    /// Writes `script` into a temp `.command` file and opens it.
    /// `label` identifies the script on disk and must be filename-safe.
    @discardableResult
    static func run(script: String, label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrewTUI-Bar-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scriptURL = directory.appendingPathComponent("BrewTUI-Bar-\(label).command")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        guard NSWorkspace.shared.open(scriptURL) else {
            throw TerminalHandoffError.couldNotOpen
        }
        return scriptURL
    }

    /// Convenience for the common shape: an explanatory echo, then the command.
    @discardableResult
    static func run(command: String, label: String, announcement: String? = nil) throws -> URL {
        var lines = ["#!/bin/zsh"]
        if let announcement {
            // Single-quoted echo so backticks/$ in the announcement stay literal.
            lines.append("echo '\(announcement.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
        lines.append(command)
        return try run(script: lines.joined(separator: "\n"), label: label)
    }

    /// Shows the standard "could not reach Terminal" alert. Kept here so the
    /// failure copy stays identical wherever a handoff is offered.
    @MainActor
    static func presentFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Could not open Terminal")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.runModal()
    }
}

enum TerminalHandoffError: LocalizedError {
    case couldNotOpen

    var errorDescription: String? {
        String(localized: "Could not launch the command in your terminal app.")
    }
}
