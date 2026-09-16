import Testing
import Foundation
@testable import BrewTUI_Bar

// MARK: - Cleanup parsing

@Suite("brew cleanup parsing")
struct CleanupParserTests {
    /// Verbatim from `brew cleanup -n` on a real machine.
    static let dryRunSample = """
    Would remove: /Users/me/Library/Caches/Homebrew/node--22.4.0.bottle.tar.gz (48.2MB)
    Would remove: /opt/homebrew/Cellar/git/2.45.1 (1,707 files, 34.6MB)
    Would remove: /opt/homebrew/Library/Homebrew/vendor/portable-ruby/4.0.6_2 (1,707 files, 34.6MB)
    ==> This operation would free approximately 117.4MB of disk space.
    """

    @Test("sums the per-entry sizes rather than trusting the summary line")
    func sumsEntries() {
        let report = MaintenanceService.parseCleanup(Self.dryRunSample)
        #expect(report.entries.count == 3)
        // 48.2 + 34.6 + 34.6 MB, 1024-based.
        let expected = Int64(48.2 * 1_048_576) + Int64(34.6 * 1_048_576) * 2
        #expect(report.totalBytes == expected)
        #expect(report.summaryBytes == Int64(117.4 * 1_048_576))
    }

    @Test("reads the thousands-separated file count as one number")
    func fileCountWithSeparator() {
        let report = MaintenanceService.parseCleanup(Self.dryRunSample)
        let git = report.entries.first { $0.path.hasSuffix("git/2.45.1") }
        #expect(git?.fileCount == 1707)
    }

    @Test("parses the real run's past-tense summary too")
    func realRunSummary() {
        let output = """
        Removing: /opt/homebrew/Cellar/wget/1.24.5... (94 files, 4.3MB)
        ==> This operation has freed approximately 4.3MB of disk space.
        """
        let report = MaintenanceService.parseCleanup(output)
        #expect(report.entries.count == 1)
        // The trailing "..." brew prints must not end up in the path.
        #expect(report.entries[0].path == "/opt/homebrew/Cellar/wget/1.24.5")
        #expect(report.entries[0].fileCount == 94)
        #expect(report.summaryBytes == report.totalBytes)
    }

    @Test("an entry without a size still counts")
    func entryWithoutSize() {
        let report = MaintenanceService.parseCleanup("Would remove: /opt/homebrew/some/path")
        #expect(report.entries.count == 1)
        #expect(report.totalBytes == 0)
    }

    @Test("nothing to clean produces an empty report")
    func emptyOutput() {
        #expect(MaintenanceService.parseCleanup("").isEmpty)
    }

    @Test("size units are 1024-based, matching Homebrew's own formatting")
    func sizeUnits() {
        #expect(MaintenanceService.parseSize("512B") == Int64(512))
        #expect(MaintenanceService.parseSize("1KB") == Int64(1024))
        #expect(MaintenanceService.parseSize("1.5MB") == Int64(1.5 * 1_048_576))
        #expect(MaintenanceService.parseSize("2GB") == Int64(2_147_483_648))
        #expect(MaintenanceService.parseSize("1,024KB") == Int64(1_048_576))
        #expect(MaintenanceService.parseSize("not a size") == nil)
        #expect(MaintenanceService.parseSize("") == nil)
    }
}

@Suite("brew autoremove parsing")
struct AutoremoveParserTests {
    @Test("collects the names listed under the header")
    func parsesNames() {
        let output = """
        ==> Would autoremove 3 unneeded formulae:
        libidn2
        libunistring
        pcre2
        """
        #expect(MaintenanceService.parseAutoremove(output) == ["libidn2", "libunistring", "pcre2"])
    }

    @Test("ignores prose that follows the list")
    func stopsAtProse() {
        let output = """
        ==> Autoremoving 1 unneeded formula:
        libidn2
        Warning: some other message here
        """
        #expect(MaintenanceService.parseAutoremove(output) == ["libidn2"])
    }

    @Test("nothing to remove yields an empty list")
    func empty() {
        #expect(MaintenanceService.parseAutoremove("").isEmpty)
    }
}

// MARK: - Inventory

@Suite("brew list parsing")
struct InventoryParserTests {
    @Test("keeps every version of a package with old kegs on disk")
    func multipleVersions() {
        let parsed = InventoryService.parseVersions("""
        git 2.45.1
        python@3.12 3.12.2 3.12.3
        """)
        #expect(parsed.count == 2)
        #expect(parsed[0].name == "git")
        #expect(parsed[1].versions == ["3.12.2", "3.12.3"])
    }

    @Test("blank lines and whitespace do not become packages")
    func ignoresBlankLines() {
        #expect(InventoryService.parseNames("\n  wget \n\nffmpeg\n") == ["wget", "ffmpeg"])
    }
}

// MARK: - History

@Suite("Action history decoding")
struct ActionHistoryTests {
    static let sample = Data("""
    {
      "version": 1,
      "entries": [
        {
          "id": "a",
          "action": "upgrade",
          "packageName": "git",
          "timestamp": "2026-06-08T01:42:06.678Z",
          "success": true,
          "error": null
        },
        {
          "id": "b",
          "action": "upgrade-all",
          "packageName": null,
          "timestamp": "2026-06-25T22:24:42.191Z",
          "success": false,
          "error": "brew exited with code 1"
        }
      ]
    }
    """.utf8)

    @Test("decodes the CLI's fractional-second timestamps and sorts newest first")
    func decodesAndSorts() throws {
        let entries = try ActionHistoryService.decode(Self.sample)
        #expect(entries.count == 2)
        #expect(entries[0].id == "b")
        #expect(entries[0].packageName == nil)
        #expect(entries[0].success == false)
        #expect(entries[1].summary.hasSuffix("git"))
    }

    @Test("a batch action reads as its verb alone")
    func batchSummary() throws {
        let entries = try ActionHistoryService.decode(Self.sample)
        #expect(entries[0].summary == entries[0].actionLabel)
    }
}

// MARK: - Snapshots

@Suite("Snapshot decoding and diffing")
struct SnapshotTests {
    static let sample = Data("""
    {
      "capturedAt": "2026-04-29T15:19:11.068Z",
      "formulae": [
        { "name": "git", "version": "2.45.1", "pinned": false },
        { "name": "wget", "version": "1.24.5", "pinned": true }
      ],
      "casks": [
        { "name": "firefox", "version": "128.0" }
      ],
      "taps": ["homebrew/cask"]
    }
    """.utf8)

    @Test("casks decode even though they carry no pinned flag")
    func decodesCasks() throws {
        let snapshot = try SnapshotService.decode(Self.sample, fileName: "snap.json")
        #expect(snapshot.formulae.count == 2)
        #expect(snapshot.casks[0].pinned == nil)
        #expect(snapshot.packageCount == 3)
        #expect(snapshot.fileName == "snap.json")
    }

    @Test("diff reports additions, removals and version changes")
    func diffsMaps() {
        let diff = SnapshotService.diff(
            base: ["git": "2.45.1", "wget": "1.24.5"],
            target: ["git": "2.46.0", "ffmpeg": "7.0"]
        )
        #expect(diff.added == ["ffmpeg"])
        #expect(diff.removed == ["wget"])
        #expect(diff.changed.count == 1)
        #expect(diff.changed[0].from == "2.45.1")
        #expect(diff.changed[0].to == "2.46.0")
        #expect(diff.totalCount == 3)
    }

    @Test("diffing a snapshot against the live inventory uses the newest keg")
    func diffsAgainstInventory() throws {
        let snapshot = try SnapshotService.decode(Self.sample, fileName: "snap.json")
        let installed = [
            InstalledPackage(name: "git", versions: ["2.45.1", "2.46.0"], kind: .formula, isLeaf: true),
            InstalledPackage(name: "firefox", versions: ["128.0"], kind: .cask, isLeaf: true),
        ]
        let diff = SnapshotService.diff(from: snapshot, toInstalled: installed)
        #expect(diff.changed.map(\.name) == ["git"])
        #expect(diff.changed[0].to == "2.46.0")
        #expect(diff.removed == ["wget"])
        #expect(diff.added.isEmpty)
    }

    @Test("identical sides diff to nothing")
    func noDifferences() {
        #expect(SnapshotService.diff(base: ["git": "1"], target: ["git": "1"]).isEmpty)
    }
}

// MARK: - Profiles

@Suite("Profiles")
struct ProfileTests {
    static let sample = Data("""
    {
      "version": 1,
      "profile": {
        "name": "work",
        "description": "Work machine",
        "createdAt": "2026-04-28T06:01:28.947Z",
        "updatedAt": "2026-04-28T06:01:28.947Z",
        "formulae": ["git", "hudochenkov/sshpass/sshpass", "ffmpeg"],
        "casks": ["firefox"]
      }
    }
    """.utf8)

    @Test("missing set ignores what is already installed")
    func missingPackages() throws {
        let profile = try ProfileService.decode(Self.sample, fileName: "work.json")
        let installed = [
            InstalledPackage(name: "git", versions: ["2.45.1"], kind: .formula, isLeaf: true),
            InstalledPackage(name: "firefox", versions: ["128.0"], kind: .cask, isLeaf: true),
        ]
        let missing = profile.missingPackages(installed: installed)
        #expect(missing.map(\.name) == ["hudochenkov/sshpass/sshpass", "ffmpeg"])
    }

    @Test("a tap-qualified formula counts as installed under its short name")
    func tapQualifiedNames() throws {
        let profile = try ProfileService.decode(Self.sample, fileName: "work.json")
        let installed = [
            InstalledPackage(name: "sshpass", versions: ["1.10"], kind: .formula, isLeaf: true),
        ]
        let missing = profile.missingPackages(installed: installed)
        #expect(!missing.contains { $0.name.hasSuffix("sshpass") })
    }

    @Test("the copied command separates formulae from casks")
    func installCommand() {
        let command = BrewProfile.installCommand(for: [
            (name: "git", kind: .formula),
            (name: "firefox", kind: .cask),
        ])
        #expect(command.contains("brew install git"))
        #expect(command.contains("brew install --cask firefox"))
    }
}

// MARK: - Ignore list

@Suite("Ignored packages")
@MainActor
struct IgnoredPackagesTests {
    private func makeStore() -> (IgnoredPackages, UserDefaults) {
        let suite = "brewtui-bar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (IgnoredPackages(defaults: defaults), defaults)
    }

    private func package(_ name: String, current: String) -> OutdatedPackage {
        OutdatedPackage(name: name, installedVersions: ["1.0"], currentVersion: current)
    }

    @Test("skipping a version stops applying once a newer one appears")
    func skipExpires() {
        let (store, _) = makeStore()
        let pkg = package("git", current: "2.46.0")
        store.skipVersion(pkg)
        #expect(store.isIgnored(pkg))
        #expect(!store.isIgnored(package("git", current: "2.47.0")))
    }

    @Test("always-ignore survives any version change")
    func alwaysIgnores() {
        let (store, _) = makeStore()
        store.ignoreAlways("git")
        #expect(store.isIgnored(package("git", current: "9.9.9")))
    }

    @Test("rules round-trip through UserDefaults")
    func persists() {
        let (store, defaults) = makeStore()
        store.skipVersion(package("git", current: "2.46.0"))
        store.ignoreAlways("wget")

        let reloaded = IgnoredPackages(defaults: defaults)
        #expect(reloaded.rule(for: "git") == .version("2.46.0"))
        #expect(reloaded.rule(for: "wget") == .always)
    }

    @Test("clearing brings a package back")
    func clears() {
        let (store, _) = makeStore()
        store.ignoreAlways("git")
        store.clear("git")
        #expect(!store.isIgnored(package("git", current: "1.0")))
        #expect(store.isEmpty)
    }
}

// MARK: - AppState integration

@Suite("AppState honours the ignore list")
struct AppStateIgnoreTests {
    @MainActor
    private func makeState(_ packages: [OutdatedPackage]) -> (AppState, StubBrewChecker, IgnoredPackages) {
        let stub = StubBrewChecker()
        stub.outdatedResult = .success(OutdatedResponse(formulae: packages, casks: []))
        let ignored = IgnoredPackages(defaults: UserDefaults(suiteName: "brewtui-bar.tests.\(UUID().uuidString)")!)
        return (AppState(checker: stub, ignoredPackages: ignored), stub, ignored)
    }

    @Test("an ignored package leaves the visible list and the badge count")
    @MainActor func hidesIgnored() async {
        let packages = [
            OutdatedPackage(name: "git", installedVersions: ["2.45"], currentVersion: "2.46"),
            OutdatedPackage(name: "wget", installedVersions: ["1.24"], currentVersion: "1.25"),
        ]
        let (state, _, _) = makeState(packages)
        await state.refresh()
        #expect(state.outdatedCount == 2)

        state.skipVersion(packages[0])
        #expect(state.outdatedCount == 1)
        #expect(state.ignoredCount == 1)
        #expect(state.visibleOutdatedPackages.map(\.name) == ["wget"])
        // The raw brew result is untouched — ignoring hides, it does not delete.
        #expect(state.outdatedPackages.count == 2)
    }

    @Test("Upgrade All skips ignored packages, not just pinned ones")
    @MainActor func upgradeAllSkipsIgnored() async {
        let packages = [
            OutdatedPackage(name: "git", installedVersions: ["2.45"], currentVersion: "2.46"),
            OutdatedPackage(name: "wget", installedVersions: ["1.24"], currentVersion: "1.25"),
            OutdatedPackage(name: "node", installedVersions: ["22"], currentVersion: "23", pinned: true),
        ]
        let (state, stub, _) = makeState(packages)
        await state.refresh()
        state.ignoreAlways(packages[0])

        await state.upgradeAll()

        // The stub's default streamUpgrade bridge upgrades each seeded name.
        #expect(stub.upgradedPackages == ["wget"])
    }

    @Test("stopping the ignore puts the package back")
    @MainActor func stopIgnoring() async {
        let packages = [OutdatedPackage(name: "git", installedVersions: ["2.45"], currentVersion: "2.46")]
        let (state, _, _) = makeState(packages)
        await state.refresh()
        state.ignoreAlways(packages[0])
        #expect(state.outdatedCount == 0)

        state.stopIgnoringAll()
        #expect(state.outdatedCount == 1)
    }
}

// MARK: - Action notices

@Suite("Action notices")
struct ActionNoticeTests {
    @Test("a sudo failure carries the command for the Terminal handoff")
    func sudoFailureOffersTerminal() {
        let notice = ActionNotice.failure(BrewProcessError.needsAdminPassword(command: "brew services start nginx"))
        #expect(notice.isError)
        #expect(notice.terminalCommand == "brew services start nginx")
    }

    @Test("an ordinary failure has no Terminal command")
    func plainFailure() {
        let notice = ActionNotice.failure(BrewProcessError.commandFailed("nope"))
        #expect(notice.isError)
        #expect(notice.terminalCommand == nil)
        #expect(notice.message == "nope")
    }
}

// MARK: - brew command results

@Suite("BrewCommandResult")
struct BrewCommandResultTests {
    @Test("prefers brew's own Error: line as the reason")
    func readsErrorLine() {
        let result = BrewCommandResult(
            status: 1,
            output: Data(),
            errorOutput: "Warning: something\nError: No available formula with the name \"nope\"\n"
        )
        #expect(result.failureReason == "No available formula with the name \"nope\"")
    }

    @Test("detects the sudo refusal that has no Error: line at all")
    func detectsSudo() {
        let result = BrewCommandResult(
            status: 1,
            output: Data(),
            errorOutput: "sudo: a terminal is required to read the password; either use the -S option..."
        )
        #expect(result.needsAdminPassword)
    }

    @Test("falls back to the exit code when stderr is silent")
    func fallsBackToExitCode() {
        let result = BrewCommandResult(status: 3, output: Data(), errorOutput: "")
        #expect(result.failureReason.contains("3"))
    }
}
