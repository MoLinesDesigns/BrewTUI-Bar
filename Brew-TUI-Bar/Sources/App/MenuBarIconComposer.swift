import AppKit

/// Composes the menu-bar glyph from the split B/T asset layers so AppDelegate
/// can blink only the T when Homebrew packages are outdated.
enum MenuBarIconComposer {
    static let iconSize = NSSize(width: 18, height: 18)

    static func fullIcon() -> NSImage? {
        templateImage(named: "MenuBarIcon")
    }

    /// Draws the static B layer plus an optional T layer. Both assets carry
    /// template intent so AppKit tints them for light/dark menu bars.
    static func layeredIcon(showT: Bool) -> NSImage? {
        guard let b = templateImage(named: "MenuBarIconB"),
              let t = templateImage(named: "MenuBarIconT")
        else {
            return fullIcon()
        }

        let size = iconSize
        let composed = NSImage(size: size, flipped: false) { rect in
            b.draw(in: rect)
            if showT {
                t.draw(in: rect)
            }
            return true
        }
        composed.isTemplate = true
        composed.size = size
        return composed
    }

    private static func templateImage(named: String) -> NSImage? {
        guard let image = NSImage(named: named) else { return nil }
        image.isTemplate = true
        image.size = iconSize
        return image
    }
}
