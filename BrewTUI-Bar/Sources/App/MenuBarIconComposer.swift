import AppKit

/// Composes the menu-bar glyph from the split B/T asset layers so AppDelegate
/// can blink only the T when Homebrew packages are outdated.
enum MenuBarIconComposer {
    static let iconSize = NSSize(width: 18, height: 18)

    static func fullIcon() -> NSImage? {
        templateImage(named: "MenuBarIcon")
    }

    /// Keep B legible on the menu bar while the optional T blinks in orange.
    static func layeredIcon(showT: Bool, appearance: NSAppearance) -> NSImage? {
        guard let b = templateImage(named: "MenuBarIconB"),
              let t = templateImage(named: "MenuBarIconT")
        else {
            return fullIcon()
        }

        let foreground: NSColor = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
        let bLayer = tintedImage(b, color: foreground)
        let tLayer = tintedImage(t, color: .systemOrange)
        let size = iconSize
        let composed = NSImage(size: size, flipped: false) { rect in
            bLayer.draw(in: rect)
            if showT {
                tLayer.draw(in: rect)
            }
            return true
        }
        composed.isTemplate = false
        composed.size = size
        return composed
    }

    private static func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
        NSImage(size: iconSize, flipped: false) { rect in
            image.draw(in: rect)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func templateImage(named: String) -> NSImage? {
        guard let image = NSImage(named: named) else { return nil }
        image.isTemplate = true
        image.size = iconSize
        return image
    }
}
