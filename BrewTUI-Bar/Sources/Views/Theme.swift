import SwiftUI
import AppKit
import Observation

/// Centralised colour tokens for BrewTUI-Bar. Each token resolves to a different
/// hue when "Increase Contrast" is on (DS-002), so views never have to spell
/// out the high-contrast variant locally.
enum BrewTUIBarTheme {
    /// Installed (older) version — warning hue.
    static func installedVersion(highContrast: Bool) -> Color {
        highContrast ? Color(red: 0.8, green: 0.4, blue: 0) : .orange
    }

    /// Current (latest) version — informational hue.
    static func currentVersion(highContrast: Bool) -> Color {
        highContrast ? Color(red: 0, green: 0.5, blue: 0.7) : CrystalGlass.glassCyan
    }

    /// Generic warning surface (sync banner, etc.).
    static func warning(highContrast: Bool) -> Color {
        highContrast ? Color(red: 0.7, green: 0.5, blue: 0) : .yellow
    }

    /// Critical alerts (CVE counts, errors).
    static func critical(highContrast: Bool) -> Color {
        highContrast ? Color(red: 0.7, green: 0, blue: 0) : .red
    }

    /// Brand accent for outdated counts and upgrade prompts.
    static func accent(highContrast: Bool) -> Color {
        highContrast ? Color(red: 0.7, green: 0.35, blue: 0) : .orange
    }
}


enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
@Observable
final class AppearancePreferences {
    static let shared = AppearancePreferences()
    static let modeKey = "appearanceMode"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onChange: (() -> Void)?

    var mode: AppAppearance {
        didSet {
            guard mode != oldValue else { return }
            defaults.set(mode.rawValue, forKey: Self.modeKey)
            onChange?()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
}

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case spanish = "es"
    case english = "en"

    var id: String { rawValue }
    var label: String { self == .spanish ? "Español" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }

    var bundle: Bundle {
        Bundle.main.path(forResource: rawValue, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
    }
}

/// Localization is also read by background services; the lock protects the
/// selection while Observation refreshes strings already visible in SwiftUI.
@Observable
final class AppLocalization: @unchecked Sendable {
    static let shared = AppLocalization()
    static let languageKey = "appLanguage"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var storedLanguage: AppLanguage

    var language: AppLanguage {
        get {
            access(keyPath: \.language)
            return lock.withLock { storedLanguage }
        }
        set {
            withMutation(keyPath: \.language) {
                lock.withLock {
                    storedLanguage = newValue
                    defaults.set(newValue.rawValue, forKey: Self.languageKey)
                    defaults.set([newValue.rawValue], forKey: "AppleLanguages")
                }
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedLanguage = defaults.string(forKey: Self.languageKey).flatMap(AppLanguage.init(rawValue:)) ?? .spanish
        defaults.set([storedLanguage.rawValue], forKey: "AppleLanguages")
    }
}

extension String {
    // The shorter overload keeps existing call sites localized while using
    // the app's selection instead of Foundation's process-wide system locale.
    init(localized key: String.LocalizationValue, comment: StaticString? = nil) {
        let language = AppLocalization.shared.language
        self.init(localized: key, bundle: language.bundle, locale: language.locale, comment: comment)
    }
}

struct LocalizedContent<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .environment(\.locale, AppLocalization.shared.language.locale)
    }
}
