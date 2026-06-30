import Foundation
import Observation
import os

private let appStateLogger = Logger(subsystem: "com.molinesdesigns.brewtuibar", category: "AppState")

@MainActor
@Observable
final class AppState {
    var outdatedPackages: [OutdatedPackage] = []
    var services: [BrewService] = []
    var lastChecked: Date?
    var isLoading = false
    var error: String?
    var servicesError: String?
    var canUpgrade = true
    var onRefreshComplete: (() -> Void)?
    var cveAlerts: [CVEAlert] = []
    var cveCheckError: String?
    var syncActivity = false
    var syncMachineCount = 0
    // Friendly toast shown after Brew-TUI publishes a `last-action.json`.
    // Auto-clears after 30s via lastActionFadeTask.
    var lastActionMessage: String?
    private var lastActionFadeTask: Task<Void, Never>?
    /// Snapshot of the license decoded at launch. Used by PopoverView's footer
    /// (tier badge) and SettingsView's License section. nil until the launch
    /// task in AppDelegate populates it.
    var licenseSummary: LicenseSummary?
    /// Version of the brew-tui CLI on PATH. Populated alongside the license at
    /// launch; shown in SettingsView's About section.
    var brewTuiCliVersion: String?
    /// New Brew-TUI-Bar version detected by `brew outdated`. Surfaced as a
    /// discrete `↑` indicator in the popover footer when non-nil; clicking
    /// opens Terminal with `brew upgrade --cask brew-tui-bar`. Kept separate
    /// from `outdatedPackages` so the self-cask never inflates the user-facing
    /// outdated count.
    var selfUpdateVersion: String?
    /// Live state of an in-flight `brew upgrade`. PopoverView shows the
    /// InstallProgressView sheet whenever this is non-nil; the sheet stays
    /// open after `isFinished` so the user can confirm the outcome before
    /// dismissing it.
    var installProgress: InstallProgress?
    /// "What's new in Homebrew" modal state. Populated lazily the first time
    /// the user opens the modal (or refreshes it); the modal renders empty
    /// states for loading/error so the user knows what's happening.
    var newPackagesFormulae: [NewPackage] = []
    var newPackagesCasks: [NewPackage] = []
    var newPackagesLoading = false
    var newPackagesError: String?
    var newPackagesFetchedAt: Date?
    /// Catalog search state. The modal's search field queries ALL of Homebrew
    /// (core taps + any third-party taps, via `CatalogSearchService`), not just
    /// the recently-added feed above. An empty/short query clears these so the
    /// modal falls back to showing the novelties feed.
    var catalogSearchResultsFormulae: [NewPackage] = []
    var catalogSearchResultsCasks: [NewPackage] = []
    var catalogSearching = false
    var catalogSearchError: String?
    /// Trimmed query the current results correspond to, so the view can tell
    /// whether `catalogSearchResults*` are for what's typed now.
    var catalogSearchQuery = ""
    /// Diagnostic modal for a failed `brew services` entry. The popover opens
    /// this when the user clicks a service error row.
    var serviceDiagnostics: ServiceDiagnostics?

    /// Cola serial de upgrades. Cada petición (paquete suelto o upgrade-all) se
    /// encola y la procesa un único worker en orden, de modo que las cuentas
    /// atrás que vencen mientras otro upgrade está corriendo se ejecutan
    /// después en vez de descartarse. `installProgress` muestra siempre la
    /// petición en curso; al terminar una, el worker arranca la siguiente
    /// reemplazando el contenido del modal.
    private struct UpgradeRequest {
        let id = UUID()
        let mode: InstallProgress.Mode
        let seeds: [String]
        let arguments: [String]
    }
    private var upgradeQueue: [UpgradeRequest] = []
    private var upgradeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var upgradeWorker: Task<Void, Never>?

    /// Número de upgrades esperando turno detrás del que se muestra ahora.
    /// Lo consume el modal para indicar "N en cola".
    var queuedUpgradeCount: Int { upgradeQueue.count }

    /// Dedupes concurrent calls to `loadNewPackagesIfNeeded`. Non-nil means
    /// a fetch is in flight; new callers piggyback on it.
    private var newPackagesTask: Task<Void, Never>?

    /// Debounce/cancel handle for `searchCatalog`. Each keystroke cancels the
    /// previous in-flight search before scheduling a new one.
    private var catalogSearchTask: Task<Void, Never>?

    /// Serializes `refresh()` so only one `brew update`/outdated/services chain
    /// runs at a time. `pendingCoalescedForce` merges overlapping `force: true`
    /// callers (scheduler + LastActionMonitor) into a single follow-up pass.
    private var refreshTask: Task<Void, Never>?
    private var pendingCoalescedForce = false

    private let checker: any BrewChecking

    init(checker: any BrewChecking = BrewChecker()) {
        self.checker = checker
    }

    var outdatedCount: Int { outdatedPackages.count }
    var errorServices: [BrewService] { services.filter(\.hasError) }
    var criticalCveCount: Int { cveAlerts.filter { $0.severity == .critical || $0.severity == .high }.count }

    var lastSchedulerError: (message: String, date: String)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: "lastSchedulerError"),
              let message = dict["message"] as? String,
              let date = dict["date"] as? String
        else { return nil }
        return (message, date)
    }

    func refresh(force: Bool = false) async {
        guard force || !isLoading else { return }

        if let running = refreshTask {
            if force {
                pendingCoalescedForce = true
            } else {
                return
            }
            await running.value
            if pendingCoalescedForce {
                pendingCoalescedForce = false
                await refresh(force: true)
            }
            return
        }

        refreshTask = Task {
            defer { refreshTask = nil }
            await performRefresh()
            while pendingCoalescedForce {
                pendingCoalescedForce = false
                await performRefresh()
            }
        }
        await refreshTask?.value
    }

    private func performRefresh() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            onRefreshComplete?()
        }

        // Refresh the tap index before `brew outdated`. Running both in parallel
        // (PERF-011) caused false "up to date" results because outdated reads the
        // local formula index, which is stale until `brew update` finishes.
        await checker.updateIndex()

        async let outdatedResult = checker.checkOutdated()
        async let servicesResult = checker.checkServices()

        do {
            let result = try await outdatedResult
            outdatedPackages = result.formulae + result.casks
            selfUpdateVersion = result.selfUpdateVersion
            lastChecked = Date()
        } catch {
            appStateLogger.error("Outdated check failed: \(error.localizedDescription, privacy: .public) | \(String(describing: error), privacy: .public)")
            self.error = error.localizedDescription
        }

        do {
            services = try await servicesResult
            servicesError = nil
        } catch {
            appStateLogger.error("Services check failed: \(error.localizedDescription, privacy: .public)")
            servicesError = error.localizedDescription
        }
    }

    func updateCVEAlerts(_ alerts: [CVEAlert]) {
        cveAlerts = alerts.sorted { $0.severity.sortOrder < $1.severity.sortOrder }
    }

    func updateSyncStatus(hasActivity: Bool, machineCount: Int) {
        syncActivity = hasActivity
        syncMachineCount = machineCount
    }

    // Builds a localized banner from the cross-process action payload and
    // schedules an auto-fade. Refreshes `outdatedPackages` so the badge lines
    // up with what the message claims is left.
    func applyLastAction(_ action: LastAction) {
        let message = formatLastActionMessage(
            action: action.action,
            packages: action.packages,
            remaining: action.remainingOutdated
        )
        lastActionMessage = message
        lastActionFadeTask?.cancel()
        lastActionFadeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.lastActionMessage = nil
        }
        Task { await self.refresh(force: true) }
    }

    func dismissLastActionMessage() {
        lastActionFadeTask?.cancel()
        lastActionFadeTask = nil
        lastActionMessage = nil
    }

    func showServiceDiagnostics(for service: BrewService) async {
        let requestID = UUID()
        let serviceName = service.name
        let diagnostics = ServiceDiagnostics(id: requestID, serviceName: serviceName)
        serviceDiagnostics = diagnostics

        do {
            let output = try await checker.serviceDiagnostics(for: serviceName)
            guard serviceDiagnostics?.id == requestID else { return }
            diagnostics.output = output
            diagnostics.isLoading = false
        } catch {
            guard serviceDiagnostics?.id == requestID else { return }
            diagnostics.output = error.localizedDescription
            diagnostics.isLoading = false
        }
    }

    func dismissServiceDiagnostics() {
        serviceDiagnostics = nil
    }

    private func formatLastActionMessage(action: String, packages: [String], remaining: Int) -> String {
        let isUpgrade = action == "upgrade"
        let pkgLabel: String
        if packages.isEmpty {
            pkgLabel = String(localized: "some packages")
        } else if packages.count == 1, let only = packages.first {
            pkgLabel = only
        } else {
            let template = String(localized: "%lld packages")
            pkgLabel = String(format: template, Int64(packages.count))
        }

        let actionLine: String
        if isUpgrade {
            let template = String(localized: "Just upgraded %@ from Brew-TUI.")
            actionLine = String(format: template, pkgLabel)
        } else {
            // install / uninstall — keep the wording neutral so future actions
            // surface here without code changes per verb.
            let template = String(localized: "Brew-TUI just ran %@ on %@.")
            actionLine = String(format: template, action, pkgLabel)
        }

        let tailLine: String
        if remaining == 0 {
            tailLine = String(localized: "No packages left to update — you're all set.")
        } else if remaining == 1 {
            tailLine = String(localized: "1 package still pending an update.")
        } else {
            let template = String(localized: "%lld packages still pending an update.")
            tailLine = String(format: template, Int64(remaining))
        }

        return "\(actionLine) \(tailLine)"
    }

    func upgrade(package name: String) async {
        guard canUpgrade else {
            error = String(localized: "Pro license expired")
            return
        }
        // Look up the package's kind so we can pass `--cask`/`--formula`
        // explicitly. Without it `brew upgrade <name>` is ambiguous for
        // certain casks and can silently no-op (exit 0, "Warning: Not
        // upgrading X, the latest version is already installed"), leaving
        // the modal showing "Done" over a package that's still outdated.
        let kind = outdatedPackages.first(where: { $0.name == name })?.kind ?? .formula
        let typeFlag = kind == .cask ? "--cask" : "--formula"
        await enqueueUpgrade(
            UpgradeRequest(mode: .singlePackage(name), seeds: [name], arguments: [typeFlag, name])
        )
    }

    func upgradeAll() async {
        guard canUpgrade else {
            error = String(localized: "Pro license expired")
            return
        }
        // Seed the progress with what we currently know is outdated so the
        // modal can render its rows immediately. The stream then refines the
        // list as `==> Upgrading X` lines arrive (brew may skip pinned or
        // already-current packages between our last refresh and now).
        let seeds = outdatedPackages
            .filter { !$0.pinned }
            .map(\.name)
        await enqueueUpgrade(UpgradeRequest(mode: .all, seeds: seeds, arguments: []))
    }

    /// Encola una petición de upgrade y suspende hasta que ESA petición concreta
    /// termina, preservando el contrato `await state.upgrade(...)` que usan la
    /// UI y los tests. Si el worker ya está procesando otra petición, esta
    /// espera su turno en la cola en vez de descartarse (antes, un segundo
    /// upgrade simultáneo se perdía por el `guard !isLoading`).
    private func enqueueUpgrade(_ request: UpgradeRequest) async {
        upgradeQueue.append(request)
        startUpgradeWorkerIfNeeded()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Sin carrera: estamos en el @MainActor y no cedemos entre el
            // append y este registro, así que el worker (que sólo avanza al
            // suspendernos aquí) nunca resume antes de que el waiter exista.
            upgradeWaiters[request.id] = continuation
        }
    }

    /// Arranca el worker serial si no hay uno vivo. Drena la cola en orden:
    /// cada petición corre su `runUpgradeStream` completo (incluido el refresh
    /// final) antes de sacar la siguiente, así que los modales se encadenan sin
    /// solaparse.
    private func startUpgradeWorkerIfNeeded() {
        guard upgradeWorker == nil else { return }
        upgradeWorker = Task { @MainActor in
            defer { upgradeWorker = nil }
            while !upgradeQueue.isEmpty {
                let request = upgradeQueue.removeFirst()
                await runUpgradeStream(
                    mode: request.mode,
                    seeds: request.seeds,
                    arguments: request.arguments
                )
                upgradeWaiters.removeValue(forKey: request.id)?.resume()
            }
        }
    }

    /// Dismisses the install-progress sheet. Allowed only once the run has
    /// finished — the view binding gates the close button on `isFinished`.
    func dismissInstallProgress() {
        guard installProgress?.isFinished == true else { return }
        installProgress = nil
    }

    /// Aborts the in-flight install and discards everything still queued.
    /// Cancelling the worker propagates to the `for await` loop in
    /// `runUpgradeStream`, the stream's `onTermination` fires and brew receives
    /// SIGTERM. Queued requests are dropped and their waiters resumed so no
    /// `await enqueueUpgrade` stays suspended. The modal keeps a `.failed`
    /// final state so the user can read the outcome before dismissing.
    func cancelInstallProgress() {
        guard installProgress?.isFinished == false else { return }
        let pending = upgradeQueue
        upgradeQueue.removeAll()
        for request in pending {
            upgradeWaiters.removeValue(forKey: request.id)?.resume()
        }
        upgradeWorker?.cancel()
        installProgress?.finishFailure(String(localized: "Cancelled"))
        // The worker re-enters after the cancelled stream returns, resumes the
        // current request's waiter and exits (queue is now empty).
    }

    // MARK: - What's new in Homebrew

    /// Triggers a NewPackagesService fetch, reusing the in-flight task if any.
    /// `force: true` bypasses the 24h cache (the modal's refresh button passes
    /// this). Errors are surfaced via `newPackagesError`; partial data still
    /// shows so a flaky GitHub doesn't blank the modal.
    func loadNewPackagesIfNeeded(force: Bool = false) {
        if newPackagesTask != nil { return }
        newPackagesLoading = true
        newPackagesError = nil
        newPackagesTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.newPackagesLoading = false
                self.newPackagesTask = nil
            }
            do {
                let result = try await NewPackagesService.shared.fetchNewPackages(force: force)
                self.newPackagesFormulae = result.formulae
                self.newPackagesCasks = result.casks
                self.newPackagesFetchedAt = result.fetchedAt
            } catch {
                appStateLogger.warning("New packages fetch failed: \(error.localizedDescription, privacy: .public)")
                self.newPackagesError = error.localizedDescription
            }
        }
    }

    /// Searches the entire Homebrew catalog for `rawQuery`, debounced ~250 ms so
    /// fast typing spawns `brew` once, not per keystroke. A query shorter than
    /// `CatalogSearchService.minQueryLength` clears the results, dropping the
    /// modal back to the novelties feed. Hits that are also current novelties
    /// get their `addedAt` backfilled so the row keeps its "added X ago" pill.
    func searchCatalog(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        catalogSearchTask?.cancel()

        guard query.count >= CatalogSearchService.minQueryLength else {
            catalogSearchTask = nil
            catalogSearching = false
            catalogSearchError = nil
            catalogSearchQuery = ""
            catalogSearchResultsFormulae = []
            catalogSearchResultsCasks = []
            return
        }

        catalogSearching = true
        catalogSearchError = nil
        catalogSearchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))   // debounce
            } catch {
                return // cancelled by a newer keystroke before the network hit
            }
            do {
                let results = try await CatalogSearchService.shared.search(query)
                if Task.isCancelled { return }
                self.catalogSearchResultsFormulae = self.backfillNovelty(results.formulae, kind: .formula)
                self.catalogSearchResultsCasks = self.backfillNovelty(results.casks, kind: .cask)
                self.catalogSearchQuery = query
                self.catalogSearchError = nil
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                appStateLogger.warning("Catalog search failed: \(error.localizedDescription, privacy: .public)")
                self.catalogSearchError = error.localizedDescription
                self.catalogSearchResultsFormulae = []
                self.catalogSearchResultsCasks = []
                self.catalogSearchQuery = query
            }
            self.catalogSearching = false
            self.catalogSearchTask = nil
        }
    }

    /// Copies the `addedAt` date from the recently-added feed onto matching
    /// search hits, so a result that is also a current novelty keeps its date
    /// pill while plain catalog hits stay dateless.
    private func backfillNovelty(_ hits: [NewPackage], kind: NewPackage.Kind) -> [NewPackage] {
        let feed = kind == .formula ? newPackagesFormulae : newPackagesCasks
        guard !feed.isEmpty else { return hits }
        let dateByName: [String: Date] = Dictionary(
            feed.compactMap { pkg in pkg.addedAt.map { (pkg.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        return hits.map { hit in
            guard let date = dateByName[hit.name] else { return hit }
            return NewPackage(name: hit.name, kind: hit.kind, addedAt: date, desc: hit.desc, homepage: hit.homepage)
        }
    }

    // MARK: - Streaming upgrade core

    /// Shared driver for single-package and upgrade-all flows. Consumes
    /// `BrewUpgradeStream` events, mutates `installProgress`, then refreshes
    /// the outdated list when the stream finishes.
    private func runUpgradeStream(
        mode: InstallProgress.Mode,
        seeds: [String],
        arguments: [String]
    ) async {
        isLoading = true
        error = nil
        installProgress = InstallProgress(mode: mode, seeds: seeds)

        // Drive the stream on the main actor — AppState is @MainActor, every
        // mutation happens here, and the modal observes the same actor. The
        // checker injects a real `BrewUpgradeStream` in production, while the
        // test MockChecker inherits the protocol's fallback (which routes
        // through `upgradePackage`/`upgradeAll`).
        var succeeded = true
        let events = checker.streamUpgrade(packages: arguments)
        for await event in events {
            switch event {
            case .packageDiscovered(let name):
                installProgress?.mark(name, stage: .pending)
            case .packageStage(let name, let stage):
                installProgress?.mark(name, stage: stage)
            case .logLine:
                break
            case .success:
                installProgress?.finishSuccess()
            case .failure(let reason):
                succeeded = false
                installProgress?.finishFailure(reason)
                self.error = String(format: String(localized: "Upgrade failed: %@"), reason)
            }
        }

        // Defense in depth: brew can exit 0 even when no package was actually
        // upgraded — the "Not upgrading X, latest already installed" branch
        // detected by BrewUpgradeStream tags those packages as `.failed`.
        // If brew claimed success but every tracked seed ended in `.failed`,
        // flip the overall outcome to failure so the user sees what happened
        // instead of "Done" over a package that's about to re-appear in the
        // next refresh.
        if succeeded, let progress = installProgress, !progress.packages.isEmpty {
            let allFailed = progress.packages.allSatisfy {
                if case .failed = $0.stage { return true } else { return false }
            }
            if allFailed {
                succeeded = false
                let reason: String = {
                    for pkg in progress.packages {
                        if case .failed(let failedReason) = pkg.stage { return failedReason }
                    }
                    return String(localized: "Homebrew did not perform any upgrade")
                }()
                installProgress?.finalError = reason
                self.error = String(format: String(localized: "Upgrade failed: %@"), reason)
            }
        }

        if succeeded {
            // Refresh the outdated badge so it reflects the new state.
            // Skipping the refresh on failure preserves the error message
            // (refresh wipes `error` on entry) and avoids re-querying brew
            // when nothing changed.
            await refresh(force: true)
        } else {
            isLoading = false
        }
    }
}
