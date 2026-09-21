// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI

// A passive view of the already throttled observation. It owns no session,
// subscriptions or timers and leaves desktop pointer/keyboard routing intact.
public struct NativeConnectionStatisticsOverlay: View {
  public let information: NativeConnectionInformation
  public init(information: NativeConnectionInformation) { self.information = information }
  public var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Connection Statistics").font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
        row("Desktop", "\(information.width) × \(information.height)")
        row("Frames received", "\(information.frames)")
        row("Encoding", information.lastEncoding < 0 ? "Not received" : information.lastEncodingName)
        row("Line speed estimate", information.frames == 0 ? "Not sampled" : "\(information.bitsPerSecond / 1000) kbit/s")
        row("Protocol", "RFB \(information.protocolMajor).\(information.protocolMinor)")
        row("Security method", information.securityName)
      }.font(.caption).monospacedDigit()
    }
    .padding(12)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.15)))
    .allowsHitTesting(false)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("connection.statistics")
    .accessibilityHint("Use Show Connection Statistics in the Connection menu to hide these statistics.")
  }
  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
  }
}
