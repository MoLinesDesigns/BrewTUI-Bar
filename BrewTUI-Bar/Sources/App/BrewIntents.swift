import AppIntents
import Foundation

/// Bridge between App Intents and the running app.
///
/// Intents execute inside this process, but `AppState` is owned by
/// `AppDelegate` and there is no window scene to reach it through. Constructing
/// a second `AppState` here would spawn a parallel brew pipeline with its own
/// queue and badge state, so the delegate publishes the live one instead.
@MainActor
enum IntentBridge {
    private(set) static weak var appState: AppState?

    static func register(_ state: AppState) {
        appState = state
    }

    /// Shortcuts can launch the app cold to run an intent, arriving before
    /// `applicationDidFinishLaunching`'s task has published the state. Waiting a
    /// couple of seconds is the difference between "works" and "works only when
    /// the app was already open".
    static func resolvedAppState() async throws -> AppState {
        if let appState { return appState }
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            if let appState { return appState }
        }
        throw IntentError.appNotReady
    }
}

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case appNotReady
    case proRequired

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appNotReady: "BrewTUI-Bar is still starting up. Try again in a moment."
        case .proRequired: "This action needs an active BrewTUI-Bar Pro license."
        }
    }
}

// MARK: - Read

struct CheckHomebrewUpdatesIntent: AppIntent {
    static let title: LocalizedStringResource = "Check for Homebrew updates"
    static let description = IntentDescription("Refreshes the package list and reports how many updates are pending.")
    /// The app is an agent with no window to bring forward; opening it would
    /// only steal focus from whatever ran the shortcut.
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let state = try await IntentBridge.resolvedAppState()
        await state.refresh(force: true)
        let count = await state.outdatedCount
        let dialog: IntentDialog = count == 0
            ? "Everything is up to date."
            : "\(count) updates available."
        return .result(value: count, dialog: dialog)
    }
}

struct OutdatedPackagesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get outdated packages"
    static let description = IntentDescription("Returns the names of the Homebrew packages with a pending update, without refreshing.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let state = try await IntentBridge.resolvedAppState()
        let names = await state.visibleOutdatedPackages.map(\.name)
        return .result(value: names)
    }
}

// MARK: - Write

struct UpgradeAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Upgrade all Homebrew packages"
    static let description = IntentDescription("Runs brew upgrade for every outdated package.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = try await IntentBridge.resolvedAppState()
        guard await state.canUpgrade else { throw IntentError.proRequired }
        await state.upgradeAll()
        let remaining = await state.outdatedCount
        let dialog: IntentDialog = remaining == 0
            ? "Everything is up to date."
            : "\(remaining) packages still pending."
        return .result(dialog: dialog)
    }
}

struct UpgradePackageIntent: AppIntent {
    static let title: LocalizedStringResource = "Upgrade a Homebrew package"
    static let description = IntentDescription("Runs brew upgrade for one package.")
    static let openAppWhenRun = false

    @Parameter(title: "Package")
    var package: String

    static var parameterSummary: some ParameterSummary {
        Summary("Upgrade \(\.$package)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = try await IntentBridge.resolvedAppState()
        guard await state.canUpgrade else { throw IntentError.proRequired }
        await state.upgrade(package: package)
        return .result(dialog: "Finished upgrading \(package).")
    }
}

/// The three `brew services` verbs, exposed to Shortcuts as a picker.
enum ServiceActionAppValue: String, AppEnum {
    case start
    case stop
    case restart

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Service action")
    static let caseDisplayRepresentations: [ServiceActionAppValue: DisplayRepresentation] = [
        .start: "Start",
        .stop: "Stop",
        .restart: "Restart",
    ]

    var brewAction: BrewServiceAction {
        switch self {
        case .start:   .start
        case .stop:    .stop
        case .restart: .restart
        }
    }
}

struct ControlServiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Control a Homebrew service"
    static let description = IntentDescription("Starts, stops or restarts a brew service.")
    static let openAppWhenRun = false

    @Parameter(title: "Action")
    var action: ServiceActionAppValue

    @Parameter(title: "Service")
    var service: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) the service \(\.$service)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = try await IntentBridge.resolvedAppState()
        await state.refreshServices()
        let match = await state.services.first { $0.name.caseInsensitiveCompare(service) == .orderedSame }
        guard let match else {
            return .result(dialog: "No Homebrew service named \(service).")
        }
        await state.controlService(action.brewAction, service: match)
        let notice = await state.actionNotice
        return .result(dialog: IntentDialog(stringLiteral: notice?.message ?? "Done."))
    }
}

struct CleanupHomebrewIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean up Homebrew"
    static let description = IntentDescription("Removes old versions and cached downloads, and reports the reclaimed space.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = try await IntentBridge.resolvedAppState()
        guard await state.canUpgrade else { throw IntentError.proRequired }
        let report = try await MaintenanceService.runCleanup()
        let freed = report.formattedTotal
        return .result(dialog: "Reclaimed \(freed).")
    }
}

// MARK: - Shortcuts

struct BrewTUIBarShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckHomebrewUpdatesIntent(),
            phrases: [
                "Check for updates in \(.applicationName)",
                "Check Homebrew updates with \(.applicationName)",
            ],
            shortTitle: "Check for updates",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: UpgradeAllIntent(),
            phrases: [
                "Upgrade everything in \(.applicationName)",
                "Upgrade all Homebrew packages with \(.applicationName)",
            ],
            shortTitle: "Upgrade all",
            systemImageName: "arrow.up.circle"
        )
        AppShortcut(
            intent: CleanupHomebrewIntent(),
            phrases: [
                "Clean up Homebrew with \(.applicationName)",
            ],
            shortTitle: "Clean up",
            systemImageName: "sparkles"
        )
    }
}
