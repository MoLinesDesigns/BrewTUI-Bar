import Foundation
import os

private let catalogSearchLogger = Logger(subsystem: "com.molinesdesigns.brewtuibar", category: "CatalogSearch")

/// Searches the *entire* Homebrew catalog — core taps plus any third-party taps
/// the user has added — instead of just the "recently added" feed. Two stages:
///  1. `brew search --formula/--cask <query>` → candidate names. Core results
///     come back as short names (`wget`); tapped ones as `owner/tap/name`.
///  2. `brew info --json=v2 --formula/--cask <names>` → `desc` + `homepage` for
///     the capped, ranked candidates. `brew info` reads the local tap, so even
///     third-party packages get descriptions (the dump at formulae.brew.sh
///     would not have them).
///
/// Results carry `addedAt == nil`; `AppState` backfills the date for hits that
/// also appear in the recently-added feed so the row can still flag them as new.
actor CatalogSearchService {
    static let shared = CatalogSearchService()

    /// Upper bound on results surfaced per kind. `brew search bun` can return
    /// hundreds of version-pinned formulae (`bun@1.2.3`); capping keeps both the
    /// follow-up `brew info` call and the modal render cheap. Ranking floats the
    /// best matches above the cut.
    static let maxResultsPerKind = 50

    /// Don't spawn `brew` for ultra-short queries — one character matches half
    /// the catalog. `AppState` enforces this too, but keep the guard here so the
    /// service is safe to call directly.
    static let minQueryLength = 2

    private let searchTimeout: TimeInterval = 25
    private let infoTimeout: TimeInterval = 25

    struct Results: Sendable, Equatable {
        var formulae: [NewPackage]
        var casks: [NewPackage]

        static let empty = Results(formulae: [], casks: [])
    }

    /// Runs the two-stage search. Throws only for genuine failures (Homebrew not
    /// installed); "no matches" and per-stage `brew` errors degrade to
    /// empty/partial results so a flaky stage never blanks the modal.
    func search(_ rawQuery: String) async throws -> Results {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minQueryLength else { return .empty }

        async let formulaNamesTask = searchNames(query: query, kind: .formula)
        async let caskNamesTask = searchNames(query: query, kind: .cask)
        let formulaNames = try await formulaNamesTask
        let caskNames = try await caskNamesTask

        async let formulaeTask = describe(names: formulaNames, kind: .formula)
        async let casksTask = describe(names: caskNames, kind: .cask)
        return Results(formulae: try await formulaeTask, casks: try await casksTask)
    }

    // MARK: - Stage 1: candidate names

    private func searchNames(query: String, kind: NewPackage.Kind) async throws -> [String] {
        let flag = kind == .formula ? "--formula" : "--cask"
        let stdout: String
        do {
            stdout = try await BrewProcess.runString(["search", flag, query], timeout: searchTimeout)
        } catch BrewProcessError.processExited {
            // Exit 1 with empty stdout means "no matches for this kind", not a
            // failure — `brew search` prints its error to stderr (discarded).
            return []
        }
        return Self.rank(Self.parseSearchOutput(stdout), query: query, limit: Self.maxResultsPerKind)
    }

    /// Parses one `brew search --formula/--cask` stdout into candidate names.
    /// Drops the trailing "Use `brew desc`…" tip (which brew prints to *stdout*),
    /// blank lines and any `==>` section headers (those reappear in TTY mode),
    /// and validates the Homebrew name shape.
    static func parseSearchOutput(_ stdout: String) -> [String] {
        stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if line.hasPrefix("==>") { return false }
                if line.hasPrefix("Use `brew") { return false }
                return isValidCandidate(line)
            }
    }

    /// Accepts bare names (`wget`, `bun@1.0`) and tapped names (`owner/tap/name`).
    static func isValidCandidate(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              CharacterSet.letters.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@+-_./"))
        return name.count < 120 && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Ranks candidates exact → prefix → contains, comparing against the
    /// user-facing base name (the last path component for tapped names). Within
    /// a tier, version-pinned names (`bun@1.2.3`) sink below clean ones so the
    /// hundreds of historical `@x.y.z` formulae a tap publishes don't crowd out
    /// the real match — unless the user explicitly typed an `@`. Stable within
    /// each bucket (keeps brew's order), then capped to `limit`.
    static func rank(_ names: [String], query: String, limit: Int) -> [String] {
        let q = query.lowercased()
        let queryHasVersion = q.contains("@")
        func base(_ name: String) -> String {
            (name.split(separator: "/").last.map(String.init) ?? name).lowercased()
        }
        func tier(_ name: String) -> Int {
            let baseName = base(name)
            if baseName == q { return 0 }
            if baseName.hasPrefix(q) || name.lowercased().hasPrefix(q) { return 1 }
            return 2
        }
        func isVersioned(_ name: String) -> Bool {
            !queryHasVersion && name.contains("@")
        }
        return names
            .enumerated()
            .sorted { lhs, rhs in
                let lhsTier = tier(lhs.element)
                let rhsTier = tier(rhs.element)
                if lhsTier != rhsTier { return lhsTier < rhsTier }
                let lhsVersioned = isVersioned(lhs.element)
                let rhsVersioned = isVersioned(rhs.element)
                if lhsVersioned != rhsVersioned { return !lhsVersioned }
                return lhs.offset < rhs.offset
            }
            .prefix(limit)
            .map(\.element)
    }

    // MARK: - Stage 2: descriptions

    private func describe(names: [String], kind: NewPackage.Kind) async throws -> [NewPackage] {
        guard !names.isEmpty else { return [] }

        // `brew info --json=v2` is all-or-nothing: a single unresolvable name
        // aborts it (exit 1, no JSON), which would drop descriptions for the
        // whole kind. If the full batch comes back empty, retry with just the
        // top-ranked names so the most-relevant rows still get descriptions.
        var metaByName = await fetchMeta(names: names, kind: kind)
        if metaByName.isEmpty && names.count > 10 {
            catalogSearchLogger.debug("brew info failed for the full batch; retrying with the top 10")
            metaByName = await fetchMeta(names: Array(names.prefix(10)), kind: kind)
        }

        return names.map { name in
            let meta = metaByName[name]
            return NewPackage(name: name, kind: kind, addedAt: nil, desc: meta?.desc, homepage: meta?.homepage)
        }
    }

    /// Runs `brew info --json=v2` over `names`, decoding desc/homepage. Any
    /// failure (a bad name, timeout) degrades to an empty map — the caller then
    /// shows the names without descriptions rather than nothing.
    private func fetchMeta(names: [String], kind: NewPackage.Kind) async -> [String: PackageMeta] {
        guard !names.isEmpty else { return [:] }
        let flag = kind == .formula ? "--formula" : "--cask"
        do {
            let data = try await BrewProcess.run(["info", "--json=v2", flag] + names, timeout: infoTimeout)
            return Self.parseInfo(data, kind: kind)
        } catch {
            catalogSearchLogger.debug("brew info failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    struct PackageMeta: Sendable, Equatable {
        let desc: String?
        let homepage: URL?
    }

    /// Decodes `brew info --json=v2`. Formulae key on `full_name`, casks on
    /// `token` — the same identifiers `brew search` emits and `brew install`
    /// accepts, so the dictionary lines up with the candidate names.
    static func parseInfo(_ data: Data, kind: NewPackage.Kind) -> [String: PackageMeta] {
        guard let root = try? JSONDecoder().decode(InfoRoot.self, from: data) else { return [:] }
        let entries = (kind == .formula ? root.formulae : root.casks) ?? []
        var out: [String: PackageMeta] = [:]
        out.reserveCapacity(entries.count)
        for entry in entries {
            guard let key = entry.identifier else { continue }
            out[key] = PackageMeta(desc: entry.desc, homepage: entry.homepage.flatMap(URL.init(string:)))
        }
        return out
    }

    private struct InfoRoot: Decodable {
        let formulae: [InfoEntry]?
        let casks: [InfoEntry]?
    }

    private struct InfoEntry: Decodable {
        let fullName: String?
        let token: String?
        let desc: String?
        let homepage: String?

        var identifier: String? { fullName ?? token }

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
            case token, desc, homepage
        }
    }
}
