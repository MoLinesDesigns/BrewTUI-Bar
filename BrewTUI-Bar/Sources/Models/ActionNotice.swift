import Foundation

/// Outcome of a one-shot action that is not an upgrade: pin/unpin, service
/// control, cleanup, autoremove, install, uninstall.
///
/// Upgrades already have `upgradeFailureNotice` + `upgradeNeedsTerminal`, which
/// are wired into the modal's state machine. Reusing those for every other verb
/// would have meant a failed `brew services start` clearing an upgrade banner
/// the user had not read yet, so these live side by side instead.
struct ActionNotice: Identifiable, Sendable, Equatable {
    let id = UUID()
    let message: String
    let isError: Bool
    /// Shell command that does the same thing under a TTY. Non-nil only when
    /// the action failed because Homebrew wanted an administrator password.
    let terminalCommand: String?

    init(message: String, isError: Bool = false, terminalCommand: String? = nil) {
        self.message = message
        self.isError = isError
        self.terminalCommand = terminalCommand
    }

    /// Builds a notice from a thrown error, promoting the sudo case to a
    /// Terminal handoff instead of a dead end.
    static func failure(_ error: Error) -> ActionNotice {
        if let brewError = error as? BrewProcessError, let command = brewError.terminalCommand {
            return ActionNotice(
                message: brewError.localizedDescription,
                isError: true,
                terminalCommand: command
            )
        }
        return ActionNotice(message: error.localizedDescription, isError: true)
    }
}
