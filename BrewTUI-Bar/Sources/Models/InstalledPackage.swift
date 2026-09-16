import Foundation

/// One package that is installed right now, as reported by `brew list --versions`.
/// Distinct from `OutdatedPackage`, which only ever covers the subset Homebrew
/// has an update for — until now the app had no idea what else was on the machine.
struct InstalledPackage: Identifiable, Sendable, Equatable {
    var id: String { "\(kind.rawValue):\(name)" }
    let name: String
    /// Every version kept in the Cellar. More than one means old kegs are still
    /// on disk, which is exactly what `brew cleanup` reclaims.
    let versions: [String]
    let kind: PackageKind
    /// Formula nothing else depends on — safe to remove without breaking a
    /// dependent. `brew leaves`. Always true for casks (they have no dependents).
    let isLeaf: Bool
    /// Disk footprint of the package's directory. Computed on demand: walking
    /// the Cellar for 200 formulae takes seconds, so it is opt-in per session.
    var sizeBytes: Int64?

    var displayVersion: String { versions.last ?? "" }
    var hasMultipleVersions: Bool { versions.count > 1 }

    var formattedSize: String? {
        guard let sizeBytes else { return nil }
        return ByteFormat.string(from: sizeBytes)
    }
}

/// Homebrew reports sizes with 1024-based units (`disk_usage_readable`), and so
/// do we — a "34.6MB" parsed out of `brew cleanup` has to render back as the
/// same number the user just read in the terminal.
enum ByteFormat {
    static func string(from bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesActualByteCount = false
        return formatter.string(fromByteCount: bytes)
    }
}
