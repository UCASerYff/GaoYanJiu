import AppKit
import SwiftUI

enum AppTheme {
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let accent = adaptive(light: rgb(0x244b42), dark: rgb(0xa7e6c8))
    static let blue = accent
    static let indigo = accent
    static let teal = adaptive(light: rgb(0x4f7465), dark: rgb(0x83b79d))
    static let clay = adaptive(light: rgb(0xad6347), dark: rgb(0xd99577))
    static let canvas = adaptive(light: rgb(0xf3f0e8), dark: rgb(0x171b19))
    static let sidebar = adaptive(light: rgb(0xe7e6dc), dark: rgb(0x202623))
    static let card = adaptive(light: rgb(0xfffdf8), dark: rgb(0x222824))
    static let border = adaptive(light: rgb(0xdcd8cc), dark: rgb(0x3a413b))
    static func titleFont(_ size: CGFloat = 30) -> Font {
        .custom("Songti SC", size: size, relativeTo: .title)
    }
}
