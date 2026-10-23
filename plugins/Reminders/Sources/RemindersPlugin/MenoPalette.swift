import AppKit
import SwiftUI

public enum MenoPalette {
    public static let background = adaptive(light: 0xE7E7E9, dark: 0x363638)
    public static let canvasTop = adaptive(light: 0xE0E0E3, dark: 0x303033)
    public static let canvasBottom = adaptive(light: 0xEBEBED, dark: 0x414144)
    public static let canvasGlow = adaptive(light: 0xD4D4D8, dark: 0x555559)
    public static let canvasLight = adaptive(light: 0xF1F1F3, dark: 0x5E5E62)
    public static let card = adaptive(light: 0xEFEFF1, dark: 0x444448)
    public static let ink = Color.primary
    public static let secondary = Color.secondary
    public static let muted = Color.secondary
    public static let accent = adaptive(light: 0x606064, dark: 0xCECED2)
    public static let controlTint = adaptive(light: 0x78787D, dark: 0xC8C8CD)
    public static let horizonLight = adaptive(light: 0x929298, dark: 0xD1D1D6)
    public static let primary = adaptive(light: 0x3F3F44, dark: 0xE7E7EA)
    public static let onPrimary = adaptive(light: 0xF3F3F5, dark: 0x343439)
    public static let disabledFill = adaptive(light: 0xE5E5E8, dark: 0x454549)
    public static let disabledInk = adaptive(light: 0x6B6B71, dark: 0xBCBCC2)
    public static let positive = adaptive(light: 0x73737A, dark: 0xCECED4)
    public static let softAccent = adaptive(light: 0xD5D5DA, dark: 0x6A6A71)
    public static let border = adaptive(light: 0xD0D0D6, dark: 0x696970)
    // Keep the accepted fullscreen treatment; its button tint is not a window background.
    public static let overlayBase = Color(red: 0.19, green: 0.21, blue: 0.20)
    public static let overlayAction = Color(red: 0.48, green: 0.56, blue: 0.50)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 0xFF) / 255,
                           green: Double((value >> 8) & 0xFF) / 255,
                           blue: Double(value & 0xFF) / 255, alpha: 1)
        })
    }
}
