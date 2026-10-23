import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let sizes = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (size, scale) in sizes {
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let factor = Double(pixels) / 1024
    let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
    let rect = NSRect(x: 65, y: 65, width: 894, height: 894)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.16); shadow.shadowBlurRadius = 32; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    let path = NSBezierPath(roundedRect: rect, xRadius: 215, yRadius: 215)
    NSGradient(starting: NSColor(red: 0.99, green: 0.99, blue: 0.97, alpha: 1), ending: NSColor(red: 0.88, green: 0.90, blue: 0.86, alpha: 1))!.draw(in: path, angle: -90)
    NSShadow().set()
    let inner = NSBezierPath(roundedRect: NSRect(x: 215, y: 242, width: 594, height: 530), xRadius: 142, yRadius: 142)
    NSColor(red: 0.19, green: 0.21, blue: 0.18, alpha: 1).setFill(); inner.fill()
    let font = NSFont(descriptor: NSFont.systemFont(ofSize: 365, weight: .medium).fontDescriptor.withDesign(.rounded)!, size: 365)!
    let text = "m" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(red: 1, green: 0.98, blue: 0.94, alpha: 1)]
    let bounds = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: (1024 - bounds.width) / 2, y: 258), withAttributes: attributes)
    NSColor(red: 0.89, green: 0.68, blue: 0.30, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 700, y: 210, width: 136, height: 136)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
