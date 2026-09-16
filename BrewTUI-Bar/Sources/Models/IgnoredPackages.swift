import Foundation
import Observation

/// Local "don't nag me about this one" list.
///
/// `brew pin` only works on formulae, and even there it is a global Homebrew
/// state change the user may not want: pinning `node` also stops `brew upgrade`
/// from touching it in the terminal. This store is the app-local alternative —
/// it hides a package from the badge, the outdated list and Upgrade All without
/// touching Homebrew at all, and it is the *only* option for casks.
///
/// Two modes per package:
/// - `.version(x)` — skip until something newer than `x` shows up.
/// - `.always` — never surface it again until the user says otherwise.
@MainActor
@Observable
final class IgnoredPackages {
    /// Sentinel stored in place of a version for `.always`. A real Homebrew
    /// version can never be `*`, so the two cases cannot collide.
    private static let alwaysSentinel = "*"
    private static let storageKey = "ignoredPackages"

    enum Rule: Equatable, Sendable {
        case version(String)
        case always
    }

    /// name → rule. Kept as a plain dictionary so the whole thing round-trips
    /// through UserDefaults as `[String: String]` with no bespoke coding.
    private(set) var rules: [String: Rule] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        rules = stored.mapValues { $0 == Self.alwaysSentinel ? .always : .version($0) }
    }

    var isEmpty: Bool { rules.isEmpty }
    var count: Int { rules.count }

    /// Names with a rule of any kind, for callers that only need membership.
    var names: Set<String> { Set(rules.keys) }

    /// True when `package` should be hidden from the user-facing list.
    /// A `.version` rule expires by itself: once Homebrew offers something
    /// other than the version the user skipped, the package comes back.
    func isIgnored(_ package: OutdatedPackage) -> Bool {
        switch rules[package.name] {
        case .none:                return false
        case .always:              return true
        case .version(let skipped): return skipped == package.currentVersion
        }
    }

    func rule(for name: String) -> Rule? { rules[name] }

    func skipVersion(_ package: OutdatedPackage) {
        rules[package.name] = .version(package.currentVersion)
        persist()
    }

    func ignoreAlways(_ name: String) {
        rules[name] = .always
        persist()
    }

    func clear(_ name: String) {
        rules.removeValue(forKey: name)
        persist()
    }

    func clearAll() {
        rules.removeAll()
        persist()
    }

    /// Human-readable description of a rule, for the Settings/manager list.
    func label(for name: String) -> String {
        switch rules[name] {
        case .always:
            return String(localized: "Always ignored")
        case .version(let version):
            return String(format: String(localized: "Skipping %@"), version)
        case .none:
            return ""
        }
    }

    private func persist() {
        let encoded = rules.mapValues { rule -> String in
            switch rule {
            case .always:             Self.alwaysSentinel
            case .version(let value): value
            }
        }
        defaults.set(encoded, forKey: Self.storageKey)
    }
}
