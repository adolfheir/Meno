import AppKit

enum MenuBarIcon {
    static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            // Four soft petals with an open center remain distinct at menu-bar size.
            let petal = NSBezierPath()
            petal.move(to: NSPoint(x: 9, y: 10.5))
            petal.curve(to: NSPoint(x: 6.25, y: 13.75),
                        controlPoint1: NSPoint(x: 7.75, y: 10.5),
                        controlPoint2: NSPoint(x: 6.25, y: 12))
            petal.curve(to: NSPoint(x: 9, y: 16.5),
                        controlPoint1: NSPoint(x: 6.25, y: 15.4),
                        controlPoint2: NSPoint(x: 7.4, y: 16.5))
            petal.curve(to: NSPoint(x: 11.75, y: 13.75),
                        controlPoint1: NSPoint(x: 10.6, y: 16.5),
                        controlPoint2: NSPoint(x: 11.75, y: 15.4))
            petal.curve(to: NSPoint(x: 9, y: 10.5),
                        controlPoint1: NSPoint(x: 11.75, y: 12),
                        controlPoint2: NSPoint(x: 10.25, y: 10.5))
            petal.close()
            NSColor.black.setFill()
            for angle in [0.0, 90, 180, 270] {
                NSGraphicsContext.saveGraphicsState()
                let rotation = NSAffineTransform()
                rotation.translateX(by: 9, yBy: 9)
                rotation.rotate(byDegrees: angle)
                rotation.translateX(by: -9, yBy: -9)
                rotation.concat()
                petal.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Meno"
        return image
    }
}
