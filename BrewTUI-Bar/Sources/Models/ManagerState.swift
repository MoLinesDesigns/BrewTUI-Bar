import Foundation
import Observation
import os

private let managerLogger = Logger(subsystem: "com.molinesdesigns.brewtuibar", category: "ManagerState")

/// State behind the manager window — the surface that finally shows what the
/// CLI has been writing to `~/.brewtui-bar/` all along (history, snapshots,
/// profiles) plus the things a menu bar app should have been able to do from
/// day one (control services, see what is installed, reclaim disk).
///
/// Deliberately separate from `AppState`: none of this is needed to render the
/// popover, and loading it at launch would mean walking the Cellar and the
/// snapshot directory for a window most sessions never open. `AppState` stays
/// the store for the popover; this one is created with the window.
@MainActor
@Observable
final class ManagerState {
    enum Section: String, CaseIterable, Identifiable, Sendable {
        case services
        case inventory
        case history
        case snapshots
        case profiles
        case maintenance

        var id: String { rawValue }

        var title: String {
            switch self {
            case .services:    String(localized: "Services")
            case .inventory:   String(localized: "Installed")
            case .history:     String(localized: "History")
            case .snapshots:   String(localized: "Snapshots")
            case .profiles:    String(localized: "Profiles")
            case .maintenance: String(localized: "Maintenance")
            }
        }

        var systemImage: String {
            switch self {
            case .services:    "bolt.horizontal.circle"
            case .inventory:   "shippingbox"
            case .history:     "clock.arrow.circlepath"
            case .snapshots:   "camera.viewfinder"
            case .profiles:    "person.2.crop.square.stack"
            case .maintenance: "wrench.and.screwdriver"
            }
        }

        /// Sections that read data the CLI produces as part of Pro. Read-only
        /// here, but gated the same way the CLI gates them so the two do not
        /// disagree about what a Basic user is entitled to.
        var requiresPro: Bool {
            switch self {
            case .history, .snapshots, .profiles, .maintenance: true
            case .services, .inventory:                         false
            }
        }
    }

    var selection: Section = .services

    // MARK: Inventory
    private(set) var inventory: [InstalledPackage] = []
    var inventoryLoading = false
    var inventoryError: String?
    /// One listing failed while the other worked (untrusted tap, mostly).
    /// Shown as a strip above the list instead of replacing it.
    private(set) var inventoryWarning: String?
    var inventoryQuery = ""
    var showLeavesOnly = false
    var sizesLoading = false
    private(set) var sizesComputed = false

    // MARK: History
    private(set) var history: [ActionHistoryEntry] = []
    var historyLoading = false
    var historyError: String?

    // MARK: Snapshots
    private(set) var snapshots: [BrewSnapshot] = []
    var snapshotsLoading = false
    var snapshotsError: String?
    var selectedSnapshotID: String?
    private(set) var snapshotDiff: SnapshotDiff?
    private(set) var diffIsAgainstNow = true
    /// Distinguishes "computing the diff" from "cannot compute it". Without it
    /// a failed inventory read left the diff pane spinning forever.
    private(set) var diffLoading = false
    private(set) var diffUnavailableReason: String?

    // MARK: Profiles
    private(set) var profiles: [BrewProfile] = []
    var profilesLoading = false
    var profilesError: String?
    private(set) var brewfile: BrewfileStatus?

    // MARK: Maintenance
    private(set) var cleanupReport: CleanupReport?
    private(set) var autoremoveCandidates: [String]?
    private(set) var doctorOutput: String?
    var maintenanceBusy = false
    var maintenanceError: String?

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    var isPro: Bool { appState.canUpgrade }

    var filteredInventory: [InstalledPackage] {
        let query = inventoryQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return inventory.filter { package in
            if showLeavesOnly && !package.isLeaf { return false }
            guard !query.isEmpty else { return true }
            return package.name.lowercased().contains(query)
        }
    }

    var inventoryTotalSize: Int64? {
        let sizes = inventory.compactMap(\.sizeBytes)
        guard !sizes.isEmpty else { return nil }
        return sizes.reduce(0, +)
    }

    var selectedSnapshot: BrewSnapshot? {
        guard let selectedSnapshotID else { return snapshots.first }
        return snapshots.first { $0.id == selectedSnapshotID } ?? snapshots.first
    }

    // MARK: - Loading

    /// Loads whatever the section needs, once. Re-entrant calls while a load is
    /// in flight are dropped rather than queued — the window re-triggers this
    /// on every selection change.
    func loadIfNeeded(_ section: Section) async {
        switch section {
        case .services:
            await appState.refreshServices()
        case .inventory:
            guard inventory.isEmpty, !inventoryLoading else { return }
            await loadInventory()
        case .history:
            guard history.isEmpty, !historyLoading else { return }
            await loadHistory()
        case .snapshots:
            guard snapshots.isEmpty, !snapshotsLoading else { return }
            await loadSnapshots()
        case .profiles:
            guard profiles.isEmpty, !profilesLoading else { return }
            await loadProfiles()
        case .maintenance:
            guard cleanupReport == nil, !maintenanceBusy else { return }
            await previewMaintenance()
        }
    }

    func reload(_ section: Section) async {
        switch section {
        case .services:    await appState.refreshServices()
        case .inventory:   await loadInventory()
        case .history:     await loadHistory()
        case .snapshots:   await loadSnapshots()
        case .profiles:    await loadProfiles()
        case .maintenance: await previewMaintenance()
        }
    }

    func loadInventory() async {
        inventoryLoading = true
        inventoryError = nil
        defer { inventoryLoading = false }
        do {
            let result = try await InventoryService.load()
            inventory = result.packages
            inventoryWarning = result.warning
            sizesComputed = false
        } catch {
            managerLogger.error("Inventory load failed: \(error.localizedDescription, privacy: .public)")
            inventoryError = error.localizedDescription
        }
    }

    /// Walks the Cellar/Caskroom to size every package. Opt-in: on a machine
    /// with a couple of hundred formulae this touches hundreds of thousands of
    /// files, which is far too much to do behind the user's back every time the
    /// window opens.
    func computeSizes() async {
        guard !sizesLoading, !inventory.isEmpty else { return }
        sizesLoading = true
        defer { sizesLoading = false }

        let roots = await InventoryService.roots()
        let packages = inventory
        let sizes = await Task.detached(priority: .utility) { () -> [String: Int64] in
            var result: [String: Int64] = [:]
            for package in packages {
                let root = package.kind == .formula ? roots.cellar : roots.caskroom
                guard let root else { continue }
                let directory = root.appendingPathComponent(package.name, isDirectory: true)
                if let size = InventoryService.directorySize(at: directory) {
                    result[package.id] = size
                }
            }
            return result
        }.value

        inventory = inventory.map { package in
            var copy = package
            copy.sizeBytes = sizes[package.id]
            return copy
        }
        sizesComputed = true
    }

    func loadHistory() async {
        historyLoading = true
        historyError = nil
        defer { historyLoading = false }
        do {
            history = try await ActionHistoryService.load()
        } catch {
            managerLogger.error("History load failed: \(error.localizedDescription, privacy: .public)")
            historyError = error.localizedDescription
        }
    }

    func loadSnapshots() async {
        snapshotsLoading = true
        snapshotsError = nil
        defer { snapshotsLoading = false }
        do {
            snapshots = try await SnapshotService.list()
            selectedSnapshotID = snapshots.first?.id
            await computeDiff()
        } catch {
            managerLogger.error("Snapshot load failed: \(error.localizedDescription, privacy: .public)")
            snapshotsError = error.localizedDescription
        }
    }

    /// Diffs the selected snapshot against what is installed right now, loading
    /// the inventory first if the user never opened that section.
    func computeDiff() async {
        diffUnavailableReason = nil
        guard let snapshot = selectedSnapshot else {
            snapshotDiff = nil
            diffUnavailableReason = String(localized: "Select a snapshot to compare.")
            return
        }
        diffLoading = true
        defer { diffLoading = false }
        if inventory.isEmpty { await loadInventory() }
        guard !inventory.isEmpty else {
            snapshotDiff = nil
            diffUnavailableReason = inventoryError
                ?? String(localized: "The list of installed packages could not be read, so there is nothing to compare against.")
            return
        }
        snapshotDiff = SnapshotService.diff(from: snapshot, toInstalled: inventory)
        diffIsAgainstNow = true
    }

    /// Diffs the selected snapshot against the one captured before it — "what
    /// did that run change", which is the other question users ask.
    func computeDiffAgainstPrevious() async {
        diffUnavailableReason = nil
        guard let snapshot = selectedSnapshot,
              let index = snapshots.firstIndex(where: { $0.id == snapshot.id }),
              index + 1 < snapshots.count
        else {
            snapshotDiff = nil
            diffUnavailableReason = String(localized: "This is the oldest snapshot — there is nothing before it.")
            return
        }
        // `snapshots` is newest-first, so the *older* capture is the next one.
        snapshotDiff = SnapshotService.diff(from: snapshots[index + 1], to: snapshot)
        diffIsAgainstNow = false
    }

    func loadProfiles() async {
        profilesLoading = true
        profilesError = nil
        defer { profilesLoading = false }
        do {
            profiles = try await ProfileService.list()
            brewfile = ProfileService.brewfileStatus()
            if inventory.isEmpty { await loadInventory() }
        } catch {
            managerLogger.error("Profile load failed: \(error.localizedDescription, privacy: .public)")
            profilesError = error.localizedDescription
        }
    }

    // MARK: - Maintenance actions

    func previewMaintenance() async {
        maintenanceBusy = true
        maintenanceError = nil
        defer { maintenanceBusy = false }
        do {
            async let cleanup = MaintenanceService.previewCleanup()
            async let autoremove = MaintenanceService.previewAutoremove()
            cleanupReport = try await cleanup
            autoremoveCandidates = try await autoremove
        } catch {
            managerLogger.error("Maintenance preview failed: \(error.localizedDescription, privacy: .public)")
            maintenanceError = error.localizedDescription
        }
    }

    func runCleanup() async {
        maintenanceBusy = true
        maintenanceError = nil
        defer { maintenanceBusy = false }
        do {
            let report = try await MaintenanceService.runCleanup()
            appState.postActionNotice(
                String(format: String(localized: "Reclaimed %@."), report.formattedTotal)
            )
            cleanupReport = try await MaintenanceService.previewCleanup()
        } catch {
            appState.presentActionFailure(error)
            maintenanceError = error.localizedDescription
        }
    }

    func runAutoremove() async {
        maintenanceBusy = true
        maintenanceError = nil
        defer { maintenanceBusy = false }
        do {
            let removed = try await MaintenanceService.runAutoremove()
            appState.postActionNotice(
                removed.isEmpty
                    ? String(localized: "Nothing to remove.")
                    : String(format: String(localized: "Removed %lld unused dependencies."), Int64(removed.count))
            )
            autoremoveCandidates = try await MaintenanceService.previewAutoremove()
            await loadInventory()
        } catch {
            appState.presentActionFailure(error)
            maintenanceError = error.localizedDescription
        }
    }

    func runDoctor() async {
        maintenanceBusy = true
        maintenanceError = nil
        defer { maintenanceBusy = false }
        do {
            doctorOutput = try await MaintenanceService.doctor()
        } catch {
            managerLogger.error("brew doctor failed: \(error.localizedDescription, privacy: .public)")
            maintenanceError = error.localizedDescription
        }
    }

    func dumpBrewfile(to url: URL) async {
        maintenanceBusy = true
        defer { maintenanceBusy = false }
        do {
            try await MaintenanceService.dumpBrewfile(to: url)
            appState.postActionNotice(
                String(format: String(localized: "Brewfile written to %@."), url.path)
            )
        } catch {
            appState.presentActionFailure(error)
        }
    }

    // MARK: - Package actions

    func uninstall(_ package: InstalledPackage) async {
        await appState.uninstall(package: package.name, kind: package.kind)
        await loadInventory()
    }

    /// Installs everything a profile lists that this machine is missing.
    /// Formulae and casks go in as two runs because `brew install` refuses to
    /// mix `--formula` and `--cask` in one invocation.
    func applyProfile(_ profile: BrewProfile) async {
        let missing = profile.missingPackages(installed: inventory)
        guard !missing.isEmpty else {
            appState.postActionNotice(String(localized: "Everything in this profile is already installed."))
            return
        }
        for package in missing {
            await appState.install(package: package.name, kind: package.kind)
        }
        await loadInventory()
    }
}
