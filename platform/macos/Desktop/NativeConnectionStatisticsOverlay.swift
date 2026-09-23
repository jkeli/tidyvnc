// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI

// A passive view of the already throttled observation. It owns no session,
// subscriptions or timers and leaves desktop pointer/keyboard routing intact.
public struct NativeConnectionStatisticsOverlay: View {
  public let information: NativeConnectionInformation
  public init(information: NativeConnectionInformation) { self.information = information }
  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(String(localized:"information.connection.statistics", defaultValue:"Connection Statistics")).font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
        row(String(localized:"information.desktop", defaultValue:"Desktop"), String(localized:"information.desktop.size", defaultValue:"\((information.width).formatted()) × \((information.height).formatted())"))
        row(String(localized:"information.frames.received", defaultValue:"Frames received"), information.frames.formatted())
        row(String(localized:"settings.section.encoding", defaultValue:"Encoding"), information.lastEncoding < 0 ? String(localized:"information.not.received", defaultValue:"Not received") : information.lastEncodingName)
        row(String(localized:"information.line.speed.estimate", defaultValue:"Line speed estimate"), information.frames == 0 ? String(localized:"information.not.sampled", defaultValue:"Not sampled") : String(localized:"information.speed", defaultValue:"\((information.bitsPerSecond / 1000).formatted()) kbit/s"))
        row(String(localized:"information.protocol", defaultValue:"Protocol"), "RFB \(information.protocolMajor).\(information.protocolMinor)")
        row(String(localized:"information.security.method", defaultValue:"Security method"), information.securityName)
      }.font(.caption).monospacedDigit()
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.15)))
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("connection.statistics")
    .accessibilityHint(String(localized:"information.use.show.connection.statistics.in.the.connection.menu.to.hide.these.statistics", defaultValue:"Use Show Connection Statistics in the Connection menu to hide these statistics."))
  }
  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
  }
}
