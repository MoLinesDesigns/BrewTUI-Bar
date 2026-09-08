import Foundation
import os

private let packageInfoLogger = Logger(subsystem: "com.molinesdesigns.brewtuibar", category: "PackageInfo")

enum PackageInfoError: LocalizedError {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return String(format: String(localized: "No details available for %@"), name)
        }
    }
}

/// Fetches the extended metadata shown in the package detail window.
///
/// Separate from `CatalogSearchService` on purpose: that one runs a two-stage
/// search over *many* names and only keeps `desc`/`homepage`. This one asks
/// about a single, already-known package and keeps the full record.
actor PackageInfoService {
    static let shared = PackageInfoService()

    private let timeout: TimeInterval = 20

    /// `brew info --json=v2 --formula|--cask <name>`. The kind flag is not
    /// optional here: `brew info <name>` is ambiguous when a formula and a cask
    /// share a token, and would happily return the wrong record.
    func detail(for package: OutdatedPackage) async throws -> PackageDetail {
        let flag = package.kind == .cask ? "--cask" : "--formula"
        let data = try await BrewProcess.run(["info", "--json=v2", flag, package.name], timeout: timeout)
        guard let detail = PackageDetail.parse(data, kind: package.kind) else {
            packageInfoLogger.debug("brew info returned no \(package.kind.rawValue, privacy: .public) entry for \(package.name, privacy: .public)")
            throw PackageInfoError.notFound(package.name)
        }
        return detail
    }
}
