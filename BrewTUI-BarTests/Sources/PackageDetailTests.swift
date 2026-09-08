import Testing
import Foundation
import SwiftUI
import AppKit
@testable import BrewTUI_Bar

@Suite("PackageDetail decoding")
struct PackageDetailTests {
    @Test("formula payload maps full_name, versions.stable and dependencies")
    func decodesFormula() throws {
        let json = """
        {"formulae":[{
          "name":"wget","full_name":"wget","tap":"homebrew/core",
          "desc":"Internet file retriever","license":"GPL-3.0-or-later",
          "homepage":"https://www.gnu.org/software/wget/",
          "versions":{"stable":"1.25.0","head":null,"bottle":true},
          "installed":[{"version":"1.24.5"}],
          "dependencies":["libidn2","openssl@3"],
          "caveats":null,"deprecated":false,"deprecation_reason":null,"disabled":false
        }],"casks":[]}
        """
        let detail = try #require(PackageDetail.parse(Data(json.utf8), kind: .formula))

        #expect(detail.name == "wget")
        #expect(detail.kind == .formula)
        #expect(detail.latestVersion == "1.25.0")
        #expect(detail.installedVersions == ["1.24.5"])
        #expect(detail.dependencies == ["libidn2", "openssl@3"])
        #expect(detail.license == "GPL-3.0-or-later")
        #expect(detail.tap == "homebrew/core")
        #expect(detail.autoUpdates == false)
    }

    /// Casks key on `token`, carry `name` as an *array*, expose a flat
    /// `version` and a bare-string `installed`. Feeding a cask payload through
    /// the formula shape would silently yield an empty record.
    @Test("cask payload maps token, the name array and the flat version")
    func decodesCask() throws {
        let json = """
        {"formulae":[],"casks":[{
          "token":"iterm2","name":["iTerm2"],"tap":"homebrew/cask",
          "desc":"Terminal emulator as alternative to Apple's Terminal app",
          "homepage":"https://iterm2.com/","version":"3.5.11","installed":"3.5.10",
          "auto_updates":true,"caveats":null,
          "deprecated":false,"deprecation_reason":null,"disabled":false,
          "depends_on":{"macos":{">=":["11"]},"formula":["python@3.12"]}
        }]}
        """
        let detail = try #require(PackageDetail.parse(Data(json.utf8), kind: .cask))

        #expect(detail.name == "iterm2")
        #expect(detail.title == "iTerm2")
        #expect(detail.latestVersion == "3.5.11")
        #expect(detail.installedVersions == ["3.5.10"])
        #expect(detail.autoUpdates)
        // `depends_on.macos` is a dict keyed by comparison operators; decoding
        // must skip it rather than choking on it.
        #expect(detail.dependencies == ["python@3.12"])
    }

    @Test("asking for the wrong kind yields nil instead of an empty record")
    func mismatchedKindReturnsNil() {
        let json = #"{"formulae":[],"casks":[{"token":"iterm2","version":"3.5.11"}]}"#
        #expect(PackageDetail.parse(Data(json.utf8), kind: .formula) == nil)
    }

    @Test("deprecation reason survives decoding")
    func decodesDeprecation() throws {
        let json = """
        {"formulae":[{"full_name":"qt@5","versions":{"stable":"5.15.16"},
          "deprecated":true,"deprecation_reason":"versioned_formula"}],"casks":[]}
        """
        let detail = try #require(PackageDetail.parse(Data(json.utf8), kind: .formula))
        #expect(detail.deprecated)
        #expect(detail.deprecationReason == "versioned_formula")
    }

    /// The window paints before `brew info` returns, from what the outdated row
    /// already knows.
    @Test("placeholder carries over what the outdated row already knew")
    func placeholderSeedsFromRow() {
        let pkg = OutdatedPackage(
            name: "herdr", installedVersions: ["0.8.2"], currentVersion: "0.9.0", kind: .formula
        )
        let placeholder = PackageDetail.placeholder(for: pkg)

        #expect(placeholder.name == "herdr")
        #expect(placeholder.latestVersion == "0.9.0")
        #expect(placeholder.installedVersions == ["0.8.2"])
        #expect(placeholder.desc == nil)
    }
}

@Suite("Package detail window progress ownership")
struct PackageDetailProgressTests {
    /// The one that matters: `finishQueueRun` clears `installProgress` on a
    /// clean run so the popover sheet does not linger. The detail window needs
    /// the finished progress to render the result and run its auto-close
    /// countdown, so ownership has to suppress that clear — otherwise the
    /// window goes blank at the exact moment of success.
    @Test("a successful upgrade keeps its progress while the window owns it")
    @MainActor func detailWindowKeepsFinishedProgress() async {
        let stub = StubBrewChecker()
        let state = AppState(checker: stub)
        state.canUpgrade = true

        await state.upgradeFromDetailWindow(package: "wget")

        #expect(stub.upgradedPackages == ["wget"])
        #expect(state.progressPresentation == .detailWindow)
        #expect(state.installProgress?.isFinished == true)
        #expect(state.installProgress?.finalError == nil)
    }

    /// Same run through the popover: the sheet has no countdown to run, so the
    /// progress is cleared as before.
    @Test("the popover path still clears its progress on a clean run")
    @MainActor func sheetClearsFinishedProgress() async {
        let stub = StubBrewChecker()
        let state = AppState(checker: stub)
        state.canUpgrade = true

        await state.upgrade(package: "wget")

        #expect(state.progressPresentation == .sheet)
        #expect(state.installProgress == nil)
    }

    @Test("closing the window drops a finished run and returns ownership")
    @MainActor func closingWindowReleasesProgress() async {
        let stub = StubBrewChecker()
        let state = AppState(checker: stub)
        state.canUpgrade = true

        await state.upgradeFromDetailWindow(package: "wget")
        state.releaseDetailWindowProgress()

        #expect(state.progressPresentation == .sheet)
        #expect(state.installProgress == nil)
    }

    /// The row's button calls `showPackageDetail`, which is the only thing that
    /// reaches AppDelegate's window. Cheap to break by renaming the hook.
    @Test("showPackageDetail forwards the row's package to the window hook")
    @MainActor func showPackageDetailInvokesHook() {
        let state = AppState(checker: StubBrewChecker())
        let package = OutdatedPackage(
            name: "wget", installedVersions: ["1.24.5"], currentVersion: "1.25.0", kind: .formula
        )
        var received: [String] = []
        state.onShowPackageDetail = { received.append($0.name) }

        state.showPackageDetail(package)

        #expect(received == ["wget"])
    }

    /// Without a Pro license nothing is enqueued, so ownership must go straight
    /// back — otherwise the popover sheet stays suppressed for the rest of the
    /// session.
    @Test("a refused upgrade hands ownership straight back")
    @MainActor func refusedUpgradeRestoresSheet() async {
        let stub = StubBrewChecker()
        let state = AppState(checker: stub)
        state.canUpgrade = false

        await state.upgradeFromDetailWindow(package: "wget")

        #expect(stub.upgradedPackages.isEmpty)
        #expect(state.progressPresentation == .sheet)
    }

    /// A failed run parks its modal for the user to read — the window must not
    /// auto-close, and the progress must survive for it to show why.
    @Test("a failed upgrade keeps the window's progress parked")
    @MainActor func failedUpgradeKeepsProgress() async {
        let stub = StubBrewChecker()
        stub.upgradePackageError = BrewProcessError.timeout
        let state = AppState(checker: stub)
        state.canUpgrade = true

        await state.upgradeFromDetailWindow(package: "wget")

        #expect(state.installProgress?.finalError != nil)
        #expect(state.progressPresentation == .detailWindow)
    }
}

@Suite("Package detail window auto-close")
@MainActor
struct PackageDetailAutoCloseTests {
    /// Hosts the view in a real `NSWindow` — `.onChange` and `.task(id:)` only
    /// run for a view that is actually being rendered, so a bare
    /// `NSHostingController` would prove nothing.
    private static func host<V: View>(_ view: V) -> NSWindow {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = controller.view
        window.orderFrontRegardless()
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    /// The titular requirement: after a clean install the window counts down
    /// and closes itself. Everything else about the flow is state-machine
    /// testable, but the arming (`onChange`) and the tick (`task(id:)`) only
    /// exist inside a rendered SwiftUI view.
    @Test("a successful install counts down and closes the window on its own")
    func autoClosesAfterSuccess() async throws {
        let stub = StubBrewChecker()
        let state = AppState(checker: stub)
        state.canUpgrade = true
        let package = OutdatedPackage(
            name: "wget", installedVersions: ["1.24.5"], currentVersion: "1.25.0", kind: .formula
        )
        state.outdatedPackages = [package]

        let closed = Box()
        let window = Self.host(
            PackageDetailView(
                package: package,
                appState: state,
                autoCloseSeconds: 2,
                onClose: { closed.value = true }
            )
        )
        defer { window.orderOut(nil) }

        await state.upgradeFromDetailWindow(package: package.name)
        #expect(state.installProgress?.isFinished == true)

        // Nothing should close before the countdown has run its course.
        try await Task.sleep(for: .milliseconds(600))
        #expect(closed.value == false, "la ventana se cerró antes de terminar la cuenta")

        for _ in 0..<60 where !closed.value {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(closed.value, "la ventana no se cerró sola tras la cuenta atrás")
    }

    /// A failed run parks the window: the user has to read the error, so no
    /// countdown may start.
    @Test("a failed install never arms the countdown")
    func failedInstallDoesNotAutoClose() async throws {
        let stub = StubBrewChecker()
        stub.upgradePackageError = BrewProcessError.timeout
        let state = AppState(checker: stub)
        state.canUpgrade = true
        let package = OutdatedPackage(
            name: "wget", installedVersions: ["1.24.5"], currentVersion: "1.25.0", kind: .formula
        )
        state.outdatedPackages = [package]

        let closed = Box()
        let window = Self.host(
            PackageDetailView(
                package: package,
                appState: state,
                autoCloseSeconds: 1,
                onClose: { closed.value = true }
            )
        )
        defer { window.orderOut(nil) }

        await state.upgradeFromDetailWindow(package: package.name)
        try await Task.sleep(for: .milliseconds(1800))

        #expect(state.installProgress?.finalError != nil)
        #expect(closed.value == false, "una instalación fallida no debe cerrar la ventana")
    }

    /// Mutable flag the SwiftUI closure can set; `@MainActor` throughout, so no
    /// synchronisation is needed.
    @MainActor final class Box {
        var value = false
    }
}
