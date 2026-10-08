import SwiftUI
import AppKit

// MARK: - Tokens

/// Shared spacing, geometry and accent tokens for the Liquid Glass interface.
enum CrystalGlass {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        /// Panels and cards.
        static let panel: CGFloat = 18
        /// Pill / capsule buttons.
        static let pill: CGFloat = 22
        /// Height of compact capsule controls.
        static let icon: CGFloat = 28
    }

    static let secondaryText = Color.primary.opacity(0.82)
    static let tertiaryText = Color.primary.opacity(0.72)

    enum Stroke {
        static let hairline: CGFloat = 1
    }

    /// Cyan accent reused across borders, glows and focus highlights.
    static let glassCyan = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            NSColor(red: 0.30, green: 0.85, blue: 0.95, alpha: 1)
        } else {
            NSColor(red: 0, green: 0.42, blue: 0.55, alpha: 1)
        }
    })

    /// Warm coral accent used for outdated counts, upgrade indicators and the
    /// Free funnel CTA. Replaces the legacy purple plan tints.
    static let warmAccent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            NSColor(red: 1.0, green: 0.57, blue: 0.49, alpha: 1)
        } else {
            NSColor(red: 0.75, green: 0.29, blue: 0.20, alpha: 1)
        }
    })

    /// Soft cyan glow for ambient shadows under glass.
    static func ambientShadow(intensity: Double = 0.18) -> Color {
        Color.cyan.opacity(intensity)
    }
}

// MARK: - Liquid Glass Clear

/// Keep native glass on the content so interactive effects follow its hit area.
/// Earlier macOS versions and accessibility settings use the same geometry.
private struct LiquidGlassClearModifier<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color = .clear
    var interactive = false
    var strokeOpacity: Double = 0.55

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.stroke(.primary.opacity(contrast == .increased ? 0.6 : 0.2), lineWidth: 1))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(
                .clear.tint(tint == .clear ? .clear : tint.opacity(0.12))
                    .interactive(interactive),
                in: shape
            )
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(tint.opacity(0.10), in: shape)
                .overlay(shape.stroke(.white.opacity(strokeOpacity * 0.35), lineWidth: 1))
        }
    }
}

extension View {
    func liquidGlassClear<S: Shape>(
        in shape: S,
        tint: Color = .clear,
        interactive: Bool = false,
        strokeOpacity: Double = 0.55
    ) -> some View {
        modifier(LiquidGlassClearModifier(
            shape: shape,
            tint: tint,
            interactive: interactive,
            strokeOpacity: strokeOpacity
        ))
    }

    /// Batch adjacent glass surfaces without merging separate controls.
    @ViewBuilder
    func liquidGlassContainer() -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) { self }
        } else {
            self
        }
    }
}

struct GlassPanelBackground: View {
    var cornerRadius: CGFloat = CrystalGlass.Radius.panel
    var tint: Color = .clear
    var strokeOpacity: Double = 0.55
    var fillOpacity: Double = 1.0

    var body: some View {
        Color.clear
            .liquidGlassClear(
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                tint: tint,
                strokeOpacity: strokeOpacity
            )
            .allowsHitTesting(false)
    }
}

extension View {
    func glassPanel(
        cornerRadius: CGFloat = CrystalGlass.Radius.panel,
        tint: Color = .clear,
        strokeOpacity: Double = 0.55,
        ambientGlow: Double = 0.12
    ) -> some View {
        liquidGlassClear(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            strokeOpacity: strokeOpacity
        )
    }
}

// MARK: - Pill button style

struct GlassPillButtonStyle: ButtonStyle {
    enum Emphasis {
        case neutral
        case prominent
    }

    var emphasis: Emphasis = .neutral
    var tint: Color = .clear
    var horizontalPadding: CGFloat = CrystalGlass.Spacing.lg
    var verticalPadding: CGFloat = CrystalGlass.Spacing.sm

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .liquidGlassClear(
                in: Capsule(),
                tint: emphasis == .prominent ? CrystalGlass.warmAccent : tint,
                interactive: isEnabled
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1.0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1.0) : 0.55)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.75), value: configuration.isPressed)
            .contentShape(Capsule())
            .accessibilityAddTraits(.isButton)
            .foregroundStyle(.primary)
    }
}

extension ButtonStyle where Self == GlassPillButtonStyle {
    static var glassPill: GlassPillButtonStyle { GlassPillButtonStyle(emphasis: .neutral) }
    static var glassPillProminent: GlassPillButtonStyle {
        GlassPillButtonStyle(emphasis: .prominent)
    }
}

// MARK: - Icon button style

/// Compact capsules keep toolbar actions consistent with text buttons.
struct GlassIconButtonStyle: ButtonStyle {
    var size: CGFloat = CrystalGlass.Radius.icon

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: size + 12, height: size)
            .liquidGlassClear(in: Capsule(), interactive: isEnabled)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1.0)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1.0) : 0.45)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == GlassIconButtonStyle {
    static var glassIcon: GlassIconButtonStyle { GlassIconButtonStyle() }
}

// MARK: - Gradient divider

/// A neutral separator leaves color to status and action accents.
struct GlassDivider: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(contrast == .increased ? 0.5 : 0.12))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

// MARK: - Window background

/// Clear native glass replaces the former cyan/coral ambient washes.
struct CrystalAmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Clear glass needs a dimmed backdrop to keep dark-mode text readable.
            GlassPanelBackground(cornerRadius: 0, strokeOpacity: 0)
            Color.black.opacity(colorScheme == .dark ? 0.65 : 0.02)
        }
        .background(ClearGlassWindowBackground())
        .allowsHitTesting(false)
    }
}

private struct ClearGlassWindowBackground: NSViewRepresentable {
    final class BackgroundView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
    }

    func makeNSView(context: Context) -> BackgroundView { BackgroundView() }
    func updateNSView(_ nsView: BackgroundView, context: Context) {}
}

// MARK: - Previews

#Preview("Clear glass / Light and Dark") {
    HStack {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            VStack(spacing: 12) {
                Button("Renew Pro") {}.buttonStyle(.glassPill)
                Button("Upgrade All") {}.buttonStyle(.glassPillProminent)
                Button("Disabled") {}.buttonStyle(.glassPill).disabled(true)
                HStack {
                    Button {} label: { Image(systemName: "arrow.clockwise") }
                    Button {} label: { Image(systemName: "gear") }
                    Button {} label: { Image(systemName: "power") }
                }
                .buttonStyle(.glassIcon)
                VStack(alignment: .leading, spacing: 8) {
                    Text("3 updates available").font(.headline)
                    Text("git, node, wget").font(.caption).foregroundStyle(CrystalGlass.secondaryText)
                }
                .padding(16)
                .glassPanel()
            }
            .padding(24)
            .frame(width: 300)
            .liquidGlassContainer()
            .background(CrystalAmbientBackground())
            .environment(\.colorScheme, scheme)
        }
    }
}
