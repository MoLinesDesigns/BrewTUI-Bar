import Foundation

/// Extended metadata for a single formula/cask, decoded from
/// `brew info --json=v2`. Backs the package detail window opened from a row of
/// the outdated list.
///
/// `brew info` exposes two different shapes — formulae key on `full_name` with
/// `versions.stable` + `dependencies`, casks key on `token` with a flat
/// `version` and a `name` *array* — so decoding goes through two dedicated
/// `Decodable` types that both project into this one value type.
struct PackageDetail: Sendable, Equatable {
    let name: String
    let kind: PackageKind
    /// Human-readable title. Casks carry one (`name[0]`); formulae don't.
    let title: String?
    let desc: String?
    let homepage: URL?
    let license: String?
    let tap: String?
    /// Latest version brew knows about (`versions.stable` / cask `version`).
    let latestVersion: String?
    let installedVersions: [String]
    let dependencies: [String]
    let caveats: String?
    let deprecated: Bool
    let deprecationReason: String?
    let disabled: Bool
    /// Casks that update themselves — upgrading them through brew is usually a
    /// no-op, worth flagging in the window before the user hits Update.
    let autoUpdates: Bool

    /// Placeholder rendered while `brew info` is still running, so the window
    /// can paint immediately from what the outdated row already knows.
    static func placeholder(for package: OutdatedPackage) -> PackageDetail {
        PackageDetail(
            name: package.name,
            kind: package.kind,
            title: nil,
            desc: nil,
            homepage: nil,
            license: nil,
            tap: nil,
            latestVersion: package.currentVersion,
            installedVersions: package.installedVersions,
            dependencies: [],
            caveats: nil,
            deprecated: false,
            deprecationReason: nil,
            disabled: false,
            autoUpdates: false
        )
    }
}

// MARK: - Decoding

extension PackageDetail {
    /// Decodes the single-package payload of `brew info --json=v2`. Returns nil
    /// when the requested kind's array is empty (unknown name, tap gone).
    static func parse(_ data: Data, kind: PackageKind) -> PackageDetail? {
        guard let root = try? JSONDecoder().decode(InfoRoot.self, from: data) else { return nil }
        switch kind {
        case .formula: return root.formulae?.first.map(PackageDetail.init(formula:))
        case .cask:    return root.casks?.first.map(PackageDetail.init(cask:))
        }
    }

    private struct InfoRoot: Decodable {
        let formulae: [FormulaInfo]?
        let casks: [CaskInfo]?
    }

    struct FormulaInfo: Decodable {
        let fullName: String?
        let name: String?
        let tap: String?
        let desc: String?
        let license: String?
        let homepage: String?
        let versions: Versions?
        let installed: [Installed]?
        let dependencies: [String]?
        let caveats: String?
        let deprecated: Bool?
        let deprecationReason: String?
        let disabled: Bool?

        struct Versions: Decodable {
            let stable: String?
        }

        struct Installed: Decodable {
            let version: String?
        }

        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
            case deprecationReason = "deprecation_reason"
            case name, tap, desc, license, homepage, versions, installed
            case dependencies, caveats, deprecated, disabled
        }
    }

    struct CaskInfo: Decodable {
        let token: String?
        /// Casks publish a *list* of display names ("Visual Studio Code").
        let name: [String]?
        let tap: String?
        let desc: String?
        let homepage: String?
        let version: String?
        let installed: String?
        let autoUpdates: Bool?
        let caveats: String?
        let deprecated: Bool?
        let deprecationReason: String?
        let disabled: Bool?
        let dependsOn: DependsOn?

        /// Only the package-shaped keys are decoded. `depends_on` also carries
        /// `macos`/`arch` constraints whose values are nested dictionaries with
        /// comparison operators as keys — irrelevant here and a decoding
        /// hazard, so they are left out entirely.
        struct DependsOn: Decodable {
            let cask: [String]?
            let formula: [String]?
        }

        enum CodingKeys: String, CodingKey {
            case autoUpdates = "auto_updates"
            case deprecationReason = "deprecation_reason"
            case dependsOn = "depends_on"
            case token, name, tap, desc, homepage, version, installed
            case caveats, deprecated, disabled
        }
    }

    init(formula: FormulaInfo) {
        self.name = formula.fullName ?? formula.name ?? ""
        self.kind = .formula
        self.title = nil
        self.desc = formula.desc
        self.homepage = formula.homepage.flatMap(URL.init(string:))
        self.license = formula.license
        self.tap = formula.tap
        self.latestVersion = formula.versions?.stable
        self.installedVersions = (formula.installed ?? []).compactMap(\.version)
        self.dependencies = formula.dependencies ?? []
        self.caveats = formula.caveats
        self.deprecated = formula.deprecated ?? false
        self.deprecationReason = formula.deprecationReason
        self.disabled = formula.disabled ?? false
        self.autoUpdates = false
    }

    init(cask: CaskInfo) {
        self.name = cask.token ?? ""
        self.kind = .cask
        self.title = cask.name?.first
        self.desc = cask.desc
        self.homepage = cask.homepage.flatMap(URL.init(string:))
        self.license = nil
        self.tap = cask.tap
        self.latestVersion = cask.version
        // Cask `installed` is a bare version string, not an array of records.
        self.installedVersions = cask.installed.map { [$0] } ?? []
        self.dependencies = (cask.dependsOn?.formula ?? []) + (cask.dependsOn?.cask ?? [])
        self.caveats = cask.caveats
        self.deprecated = cask.deprecated ?? false
        self.deprecationReason = cask.deprecationReason
        self.disabled = cask.disabled ?? false
        self.autoUpdates = cask.autoUpdates ?? false
    }
}
