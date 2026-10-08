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
