import Foundation

/// A named package set saved by the CLI under `~/.brewtui-bar/profiles/`.
/// "Package Profiles" is one of the Pro features the popover advertises; the
/// app could not show a single one of them until now.
struct BrewProfile: Identifiable, Sendable, Decodable, Equatable {
    struct Payload: Sendable, Decodable, Equatable {
        let name: String
        let description: String?
        let createdAt: Date?
        let updatedAt: Date?
        let formulae: [String]
        let casks: [String]
    }

    var id: String { fileName }
    var fileName: String = ""
    let version: Int
    let profile: Payload

    enum CodingKeys: String, CodingKey {
        case version, profile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profile = try container.decode(Payload.self, forKey: .profile)
    }

    var name: String { profile.name }
    var packageCount: Int { profile.formulae.count + profile.casks.count }

    /// Packages in the profile that are not installed on this machine.
    ///
    /// The CLI has no `profile apply` subcommand — profiles live inside its
    /// interactive TUI — so the app computes the delta itself and installs it
    /// with plain `brew install`. Inventing a CLI verb here is exactly the
    /// mistake CLAUDE.md § Naming warns about.
    func missingPackages(installed: [InstalledPackage]) -> [(name: String, kind: PackageKind)] {
        let installedFormulae = Set(installed.filter { $0.kind == .formula }.map(\.name))
        let installedCasks = Set(installed.filter { $0.kind == .cask }.map(\.name))
        let missingFormulae = profile.formulae
            .filter { !installedFormulae.contains($0) && !installedFormulae.contains(shortName($0)) }
            .map { (name: $0, kind: PackageKind.formula) }
        let missingCasks = profile.casks
            .filter { !installedCasks.contains($0) && !installedCasks.contains(shortName($0)) }
            .map { (name: $0, kind: PackageKind.cask) }
        return missingFormulae + missingCasks
    }

    /// `brew list` reports tapped formulae by their short name (`sshpass`),
    /// while a profile can store the fully qualified one
    /// (`hudochenkov/sshpass/sshpass`). Comparing the raw strings would report
    /// an installed package as missing.
    private func shortName(_ raw: String) -> String {
        raw.split(separator: "/").last.map(String.init) ?? raw
    }

    /// A real, runnable command for the missing set — what the user gets when
    /// they would rather do it themselves in a terminal.
    static func installCommand(for missing: [(name: String, kind: PackageKind)]) -> String {
        let formulae = missing.filter { $0.kind == .formula }.map(\.name)
        let casks = missing.filter { $0.kind == .cask }.map(\.name)
        var lines: [String] = []
        if !formulae.isEmpty { lines.append("brew install \(formulae.joined(separator: " "))") }
        if !casks.isEmpty { lines.append("brew install --cask \(casks.joined(separator: " "))") }
        return lines.joined(separator: "\n")
    }
}
