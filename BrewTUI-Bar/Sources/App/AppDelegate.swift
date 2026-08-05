import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let isRunningForPreviews =
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" ||
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PLAYGROUNDS"] == "1" ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private static let didAutoRegisterLoginItemKey = "didAutoRegisterLoginItem"

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()
    private let scheduler = SchedulerService()
    // Side-effect: BadgePreferences reads UserDefaults in its init, so the
    // UserDefaults phase of the legacy migrator must run before that read.
    // The Login Item phase runs later from applicationDidFinishLaunching
    // (SMAppService needs an initialised NSApp).
    private let badgePreferences: BadgePreferences = {
        LegacyMigrator.migrateUserDefaultsIfNeeded()
        return BadgePreferences()
    }()
    private var badgeTimer: Timer?
    private var blinkTimer: Timer?
    private var tLayerVisible = true
    private var launchTask: Task<Void, Never>?
    private var hostingController: NSHostingController<PopoverView>?
    // Red de seguridad sobre `.transient`: en algunos escenarios (popover con
    // foco forzado vía `makeKey()`, tasks largos corriendo, sheet de Settings
    // dejando foco residual) el cierre automático en click fuera no dispara.
    // Este monitor lo garantiza sin tocar el subprocess de brew — `performClose`
    // solo oculta la UI; los Tasks viven en AppState y siguen ejecutándose.
    private var clickOutsideMonitor: Any?
    private var reduceMotionObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningForPreviews else { return }

        // Install crash reporter as early as possible so NSException handlers
        // catch failures during the rest of launch. No-op if not configured.
        CrashReporter.install()

        // Phase 2 of the legacy migrator — UserDefaults already migrated in
        // the stored-property init. SMAppService needs NSApp running, so the
        // Login Item re-register happens here.
        LegacyMigrator.completePendingLoginItemMigration()

        launchTask = Task {
            // The required-CLI alert is the one case where we terminate, so it
            // runs before anything is built. `showBrewTUIBarRequired` returns
            // true when the user asked to retry after installing.
            while await !checkBrewTUIBarInstalled() {
                guard showBrewTUIBarRequired() else { return }
            }

            // Build the status item BEFORE the non-blocking alerts below.
            // Without it the app has no Dock icon (LSUIElement) and no menu bar
            // presence, so an alert that ends up behind another window leaves
            // the user with no surface at all to reach it — the app just looks
            // like it never launched.
            setupStatusItem()
            setupPopover()

            // Cross-platform version contract: warn (non-blocking) when the
            // installed BrewTUI-Bar drifts from the brewtui-bar CLI. License
            // decryption may still work today, but skew has bitten us before
            // (HKDF schema bump). Continue to license check either way.
            let versionStatus = await VersionChecker.check()
            if case let .mismatch(brewTUIBar, brewBar) = versionStatus {
                showVersionMismatch(brewTUIBar: brewTUIBar, brewBar: brewBar)
            }

            // Check Pro license. Attempt silent auto-revalidation before denying
            // Pro — stale lastValidatedAt or benign clock skew self-heals when
            // the API is reachable, without surfacing a blocking alert.
            var licenseStatus = LicenseChecker.checkLicense()
            if let recoverable = LicenseChecker.recoverableLicense() {
                let shouldRefresh = switch licenseStatus {
                case .expired: true
                case .pro: LicenseChecker.needsRevalidation(for: recoverable)
                default: false
                }
                if shouldRefresh, await LicenseRevalidator.revalidateIfNeeded() {
                    licenseStatus = LicenseChecker.checkLicense()
                }
            }

            switch licenseStatus {
            case .pro:
                appState.canUpgrade = true
                autoRegisterLoginItemIfNeeded()
                // future: surface DegradationLevel.warning/.limited in UI
            case .expired:
                appState.canUpgrade = false
                // Only alert when the license is genuinely gone/revoked — not when
                // offline degradation blocked Pro but the subscription may still be valid.
                if LicenseChecker.recoverableLicense() == nil {
                    showLicenseExpired()
                }
                // Continue in degraded mode — app stays open without Pro badge
            case .notFound:
                appState.canUpgrade = false
                // No alert, no terminate. PopoverView renders freeTierView
                // when licenseSummary.tier == .basic && !wasEverActive.
            }

            // Snapshot the license for the popover tier badge + Settings panel.
            // Built from the same value `checkLicense()` returned so we never
            // re-decode the file.
            appState.licenseSummary = LicenseSummary(from: licenseStatus)
            // Surface the BrewTUI-Bar CLI version alongside BrewTUI-Bar's in the
            // About section. Reused from VersionChecker so we do not spawn
            // a second `BrewTUI-Bar --version` process at launch.
            if case let .match(version) = versionStatus {
                appState.brewTUIBarCliVersion = version
            } else if case let .mismatch(brewTUIBar, _) = versionStatus {
                appState.brewTUIBarCliVersion = brewTUIBar
            }

            appState.onRefreshComplete = { [weak self] in
                self?.updateBadge()
            }
            badgePreferences.onChange = { [weak self] in
                self?.updateBadge()
            }

            scheduler.start(state: appState)
            await appState.refresh()

            // Load cached CVE alerts on launch (no network, just cache)
            let cachedAlerts = await SecurityMonitor.shared.loadCachedAlerts()
            appState.updateCVEAlerts(cachedAlerts)

            // Check sync activity on launch
            let hasSyncActivity = await SyncMonitor.shared.checkForSyncActivity()
            let machineCount = await SyncMonitor.shared.getKnownMachineCount()
            appState.updateSyncStatus(hasActivity: hasSyncActivity, machineCount: machineCount)

            // Listen for actions performed in the BrewTUI-Bar so the popover
            // reflects them immediately and shows a friendly status banner.
            LastActionMonitor.shared.start { [weak self] action in
                guard let self else { return }
                self.appState.applyLastAction(action)
            }

            updateBadge()
            observeReduceMotionChanges()

            badgeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateBadge() }
            }
        }
    }

    /// Repaints the menu bar when the user flips "Reduce Motion" while the app
    /// is running, so the indicator switches between blinking and the static
    /// count badge without needing a relaunch.
    private func observeReduceMotionChanges() {
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateBadge() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchTask?.cancel()
        launchTask = nil
        appState.onRefreshComplete = nil
        badgeTimer?.invalidate()
        badgeTimer = nil
        stopOutdatedBlink()
        scheduler.stop()
        LastActionMonitor.shared.stop()
        removeClickOutsideMonitor()
        if let reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver)
            self.reduceMotionObserver = nil
        }
    }

    // MARK: - Login item

    /// Registers BrewTUI-Bar as a login item the first time it runs as Pro.
    /// Honors the user's choice afterwards: if they later disable it in Settings,
    /// we won't re-register on subsequent launches.
    private func autoRegisterLoginItemIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didAutoRegisterLoginItemKey) else { return }

        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
            defaults.set(true, forKey: Self.didAutoRegisterLoginItemKey)
        } catch {
            // Non-fatal: user can enable manually from Settings later.
            // Don't set the flag so we retry on next launch.
        }
    }

    // MARK: - BrewTUI-Bar dependency check

    private func checkBrewTUIBarInstalled() async -> Bool {
        let paths = [
            "/usr/local/bin/BrewTUI-Bar",
            "/opt/homebrew/bin/BrewTUI-Bar",
            "\(NSHomeDirectory())/.npm/bin/BrewTUI-Bar",
            "/usr/local/bin/brewtui-bar",
            "/opt/homebrew/bin/brewtui-bar",
            "\(NSHomeDirectory())/.npm/bin/brewtui-bar",
        ]

        // Check known paths
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return true
            }
        }

        // Fallback: check via shell PATH (non-blocking via terminationHandler)
        for commandName in ["BrewTUI-Bar", "brewtui-bar"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [commandName]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                let found = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                    process.terminationHandler = { proc in
                        cont.resume(returning: proc.terminationStatus == 0)
                    }
                    do {
                        try process.run()
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                if found { return true }
            } catch {
                continue
            }
        }
        return false
    }

    /// Blocking alert shown when the `brewtui-bar` CLI is missing. Returns
    /// `true` when the user copied the command and wants to retry (the caller
    /// re-runs the check), `false` when they chose to quit. Copying used to
    /// terminate as well, which made "Copy Install Command" silently kill the
    /// app with no way to act on what had just been copied.
    @discardableResult
    private func showBrewTUIBarRequired() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "The brewtui-bar CLI is required")
        alert.informativeText = String(localized: "BrewTUI-Bar needs the brewtui-bar command line tool.\n\nInstall it with:\n  npm install -g brewtui-bar\n\nThen click Retry.")
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "Copy Command and Retry"))
        alert.addButton(withTitle: String(localized: "Quit"))

        activateForAlert()
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("npm install -g brewtui-bar", forType: .string)
            return true
        }

        NSApp.terminate(nil)
        return false
    }

    /// Brings the app forward before a modal alert. As an `LSUIElement` agent
    /// we own no Dock icon and, early in launch, no status item either, so an
    /// alert raised while another app is frontmost can end up behind it with
    /// nothing for the user to click on to surface it again.
    private func activateForAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showVersionMismatch(brewTUIBar: String, brewBar: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "BrewTUI-Bar version mismatch")
        let template = String(
            localized: "BrewTUI-Bar %@ is out of sync with the brewtui-bar CLI %@. They must match for license decryption and updates.\n\nRun this in the terminal:\n\n  brewtui-bar install-brewtui-bar --force"
        )
        alert.informativeText = String(format: template, brewBar, brewTUIBar)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Copy Update Command"))
        alert.addButton(withTitle: String(localized: "Continue Anyway"))

        activateForAlert()
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brewtui-bar install-brewtui-bar --force", forType: .string)
        }
    }

    private func showLicenseExpired() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Pro license expired")
        alert.informativeText = String(
            localized: "Your Pro license has expired or needs revalidation.\n\nRun `brewtui-bar revalidate` in the terminal, or renew your subscription.\n\nThe app will continue in basic mode."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Continue"))
        activateForAlert()
        alert.runModal()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let icon = MenuBarIconComposer.fullIcon()
            button.image = icon
            button.image?.accessibilityDescription = String(localized: "BrewTUI-Bar")
            button.imagePosition = .imageLeft
            button.title = ""
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 420)
        popover.behavior = .transient
        // Delegate is required to learn about `.transient` auto-closes
        // (click outside, focus loss) — without it `clickOutsideMonitor`
        // leaks past the popover lifecycle and fires phantom closePopover()
        // calls on the next external click. See popoverDidClose below.
        popover.delegate = self
        // The hostingController is created fresh on every show in
        // togglePopover(), not here. Reusing the same controller across
        // shows leaves a stale SwiftUI tree + window-responder chain
        // after a sheet dismiss: buttons render but mouse events never
        // reach them. See togglePopover for the rationale.
    }

    /// Whether outdated packages should be surfaced at all. Independent from
    /// *how* they are surfaced — see `shouldAnimateOutdatedIndicator`.
    private func shouldShowOutdatedIndicator() -> Bool {
        appState.outdatedCount > 0 && badgePreferences.showOutdated
    }

    /// Blinking is the default presentation, but it is suppressed under
    /// "Reduce Motion". Previously the blink was the *only* channel for
    /// outdated packages, so a user who wanted it to stop had to turn the
    /// indicator off entirely and lose the signal. When we don't animate we
    /// fall back to a static count badge, the same treatment CVE and sync get.
    private func shouldAnimateOutdatedIndicator() -> Bool {
        shouldShowOutdatedIndicator() && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func syncOutdatedBlink() {
        if shouldAnimateOutdatedIndicator() {
            guard blinkTimer == nil else { return }
            tLayerVisible = true
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.tLayerVisible.toggle()
                    self.updateStatusItemIcon()
                }
            }
        } else {
            stopOutdatedBlink()
        }
    }

    private func stopOutdatedBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        tLayerVisible = true
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem.button else { return }

        let icon = shouldAnimateOutdatedIndicator()
            ? MenuBarIconComposer.layeredIcon(showT: tLayerVisible)
            : MenuBarIconComposer.fullIcon()
        icon?.accessibilityDescription = statusItemAccessibilityDescription()
        button.image = icon
    }

    private func statusItemAccessibilityDescription() -> String {
        let outdated = appState.outdatedCount
        let cve = appState.criticalCveCount
        let sync = appState.syncActivity

        var parts: [String] = []
        if outdated > 0, badgePreferences.showOutdated {
            parts.append(String(format: String(localized: "%lld outdated packages"), outdated))
        }
        if cve > 0, badgePreferences.showCVE { parts.append("\(cve) CVE") }
        if sync, badgePreferences.showSync { parts.append(String(localized: "Sync active")) }

        if parts.isEmpty {
            return String(localized: "BrewTUI-Bar")
        }
        return String(format: String(localized: "BrewTUI-Bar — %@"), parts.joined(separator: ", "))
    }

    private func updateBadge() {
        guard let button = statusItem.button else { return }

        let cve = appState.criticalCveCount
        let sync = appState.syncActivity

        // Outdated packages are surfaced by blinking the T layer in the icon,
        // or — when motion is suppressed — by a static count badge so the
        // signal survives without animation. CVE and sync keep compact text
        // badges beside the glyph.
        var parts: [String] = []
        if shouldShowOutdatedIndicator(), !shouldAnimateOutdatedIndicator() {
            parts.append("\(appState.outdatedCount)↑")
        }
        if cve > 0, badgePreferences.showCVE { parts.append("\(cve)⚠") }
        if sync, badgePreferences.showSync { parts.append("⟳") }

        let menuFont = NSFont.menuBarFont(ofSize: NSFont.systemFontSize(for: .small))
        let attributed = NSMutableAttributedString()
        for (idx, part) in parts.enumerated() {
            if idx > 0 {
                attributed.append(NSAttributedString(string: " ", attributes: [.font: menuFont]))
            }
            attributed.append(NSAttributedString(string: part, attributes: [.font: menuFont]))
        }
        if attributed != button.attributedTitle {
            button.attributedTitle = attributed
        }

        syncOutdatedBlink()
        updateStatusItemIcon()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            closePopover()
        } else {
            // Recreate the hostingController on every show. Reusing the
            // same controller across shows means the same NSView tree is
            // re-attached to whatever NSWindow NSPopover hands us, and after
            // a `.sheet` dismissal the responder chain on that view can
            // stay broken even when makeKey() succeeds — buttons render
            // but mouse events never reach the SwiftUI handlers. A fresh
            // controller forces NSPopover to wire up a fresh view hierarchy,
            // which always gets a clean event routing path. The cost is
            // resetting `@State` (showSettings / showNewPackages), which
            // is desirable: those sheets shouldn't survive a popover close.
            let controller = NSHostingController(
                rootView: PopoverView(
                    appState: appState,
                    scheduler: scheduler,
                    badgePreferences: badgePreferences
                )
            )
            hostingController = controller
            popover.contentViewController = controller

            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Arranca la caducidad del banner: mientras el popover está
            // cerrado el aviso espera en vez de expirar sin que nadie lo vea.
            appState.popoverVisible = true
            // Defer makeKey() one runloop tick. Calling it synchronously
            // after popover.show() races NSPopover's own window-keying:
            // in some scenarios (reopen after a sheet dismiss, reopen
            // long after a previous show) the synchronous call silently
            // no-ops and the popover stays non-key, which kills mouse
            // event delivery to SwiftUI controls inside it.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.popover.isShown else { return }
                self.popover.contentViewController?.view.window?.makeKey()
            }
            installClickOutsideMonitor()
        }
    }

    private func closePopover() {
        removeClickOutsideMonitor()
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    // MARK: - NSPopoverDelegate

    /// Called by AppKit when the popover closes for any reason, including
    /// the `.transient` auto-close that bypasses our `closePopover()`.
    /// Without this, the global click-outside monitor stays installed
    /// after a transient close and fires phantom `closePopover()` calls
    /// on the next click in another app — harmless but messy. Cleanup
    /// here makes installClickOutsideMonitor's `guard == nil` accurate.
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.removeClickOutsideMonitor()
            self?.appState.popoverVisible = false
        }
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        // Global monitor sólo dispara en clicks fuera de la app, justo lo que
        // queremos. Clicks dentro del popover llegan como eventos locales y no
        // entran por aquí — el popover sigue navegable.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
