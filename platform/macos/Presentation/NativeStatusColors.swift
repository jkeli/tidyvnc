// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI

// Warning and error text colours. The system orange and red are below the WCAG
// AA 4.5:1 text contrast on light window and sheet backgrounds (system orange
// measured 1.8:1), so status text uses these instead: at least 4.5:1 on standard
// light/dark window backgrounds (light mode is about 6:1, leaving margin for
// colour management) and 6:1 or more under Increase Contrast.
extension NSColor {
  private static func status(light: UInt32, dark: UInt32, highContrastLight: UInt32, highContrastDark: UInt32,
                             name: String) -> NSColor {
    func rgb(_ value: UInt32) -> NSColor {
      NSColor(srgbRed: CGFloat(value >> 16 & 0xff) / 255, green: CGFloat(value >> 8 & 0xff) / 255,
              blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
    return NSColor(name: name) { appearance in
      switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
      case .darkAqua?: rgb(dark)
      case .accessibilityHighContrastAqua?: rgb(highContrastLight)
      case .accessibilityHighContrastDarkAqua?: rgb(highContrastDark)
      default: rgb(light)
      }
    }
  }
  public static let nativeWarningText = status(light: 0x8F3F00, dark: 0xFFA033, highContrastLight: 0x6B2E00,
                                               highContrastDark: 0xFFC266, name: "nativeWarningText")
  public static let nativeErrorText = status(light: 0xB01E17, dark: 0xFF9A94, highContrastLight: 0x8A0E0E,
                                             highContrastDark: 0xFFB3AE, name: "nativeErrorText")
}

extension Color {
  public static let nativeWarningText = Color(nsColor: .nativeWarningText)
  public static let nativeErrorText = Color(nsColor: .nativeErrorText)
}
