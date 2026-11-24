import AppKit

enum MenuBarIcon {
    static func makeImage() -> NSImage? {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: iconURL) else {
            return NSImage(systemSymbolName: "bell", accessibilityDescription: "Meno")
        }

        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = false
        image.accessibilityDescription = "Meno"
        return image
    }
}
