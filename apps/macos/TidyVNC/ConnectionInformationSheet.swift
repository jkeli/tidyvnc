// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import AppKit
import TidyVNCNative

struct ConnectionInformationSheet: View {
  let endpoint: String
  @ObservedObject var session: NativeSession
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Connection Information").font(.title2).bold()
      ScrollView {
       Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
        row("Server", endpoint)
        if let info = session.information {
          row("Desktop name", info.desktopName.isEmpty ? "Unnamed" : info.desktopName + (info.nameTruncated ? "…" : ""))
          row("Protocol", "RFB \(info.protocolMajor).\(info.protocolMinor)")
          row("Security method", info.securityName)
          row("Pixel format", info.pixelFormat)
          row("Requested encoding", info.requestedEncodingName)
          row("Last used encoding", info.lastEncoding < 0 ? "Not received" : info.lastEncodingName)
          row("Line speed estimate", info.frames == 0 ? "Not sampled" : "\(info.bitsPerSecond / 1000) kbit/s")
        }
        row("Desktop size", "\(session.snapshot.width) × \(session.snapshot.height)")
        row("Frames received", "\(session.snapshot.frames)")
        row("Remote resize", session.snapshot.supportsResize ? (session.snapshot.resizePending ? "Requested" : "Available") : "Unavailable")
        row("Input", session.isViewOnly ? "View only" : "Keyboard and pointer")
        row("Middle-button emulation", session.emulatesMiddleButton ? "On" : "Off")
        row("Send clipboard", session.clipboardSendEnabled ? "On" : "Off")
        row("Receive clipboard", session.clipboardReceiveEnabled ? "On" : "Off")
       }.frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Button("Copy Diagnostics") {
          guard let info = session.information else { return }
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(info.redactedDiagnostics, forType: .string)
        }.disabled(session.information == nil).help("Copies connection details without the server address or desktop name.")
          .accessibilityIdentifier("information.copy")
        Spacer(); Button("Done", action: dismiss).keyboardShortcut(.defaultAction).accessibilityIdentifier("information.done")
      }
    }.padding(24).frame(width: 560, height: 650)
  }
  private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled).lineLimit(3).fixedSize(horizontal: false, vertical: true).help(value)
    }
  }
}
