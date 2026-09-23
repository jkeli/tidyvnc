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
      Text(String(localized:"information.connection.information", defaultValue:"Connection Information")).font(.title2).bold()
      ScrollView {
       Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
        row(String(localized:"information.server", defaultValue:"Server"), endpoint)
        if let info = session.information {
          row(String(localized:"information.desktop.name", defaultValue:"Desktop name"), info.desktopName.isEmpty ? String(localized:"information.unnamed", defaultValue:"Unnamed") : info.desktopName + (info.nameTruncated ? "…" : ""))
          row(String(localized:"information.protocol", defaultValue:"Protocol"), "RFB \(info.protocolMajor).\(info.protocolMinor)")
          row(String(localized:"information.security.method", defaultValue:"Security method"), info.securityName)
          row(String(localized:"information.pixel.format", defaultValue:"Pixel format"), info.pixelFormat)
          row(String(localized:"information.requested.encoding", defaultValue:"Requested encoding"), info.requestedEncodingName)
          row(String(localized:"information.last.used.encoding", defaultValue:"Last used encoding"), info.lastEncoding < 0 ? String(localized:"information.not.received", defaultValue:"Not received") : info.lastEncodingName)
          row(String(localized:"information.line.speed.estimate", defaultValue:"Line speed estimate"), info.frames == 0 ? String(localized:"information.not.sampled", defaultValue:"Not sampled") : String(localized:"information.speed", defaultValue:"\((info.bitsPerSecond / 1000).formatted()) kbit/s"))
        }
        row(String(localized:"information.desktop.size.title", defaultValue:"Desktop size"), String(localized:"information.desktop.size", defaultValue:"\((session.snapshot.width).formatted()) × \((session.snapshot.height).formatted())"))
        row(String(localized:"information.frames.received", defaultValue:"Frames received"), session.snapshot.frames.formatted())
        row(String(localized:"information.remote.resize", defaultValue:"Remote resize"), session.snapshot.supportsResize ? (session.snapshot.resizePending ? String(localized:"information.requested", defaultValue:"Requested") : String(localized:"information.available", defaultValue:"Available")) : String(localized:"settings.encoding.unavailable", defaultValue:"Unavailable"))
        row(String(localized:"settings.section.input", defaultValue:"Input"), session.isViewOnly ? String(localized:"settings.input.view.only", defaultValue:"View only") : String(localized:"information.keyboard.and.pointer", defaultValue:"Keyboard and pointer"))
        row(String(localized:"information.middle.button.emulation", defaultValue:"Middle-button emulation"), session.emulatesMiddleButton ? String(localized:"settings.input.on", defaultValue:"On") : String(localized:"settings.input.off", defaultValue:"Off"))
        row(String(localized:"information.send.clipboard", defaultValue:"Send clipboard"), session.clipboardSendEnabled ? String(localized:"settings.input.on", defaultValue:"On") : String(localized:"settings.input.off", defaultValue:"Off"))
        row(String(localized:"information.receive.clipboard", defaultValue:"Receive clipboard"), session.clipboardReceiveEnabled ? String(localized:"settings.input.on", defaultValue:"On") : String(localized:"settings.input.off", defaultValue:"Off"))
       }.frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Button(String(localized:"information.copy.diagnostics", defaultValue:"Copy Diagnostics")) {
          guard let info = session.information else { return }
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(info.redactedDiagnostics, forType: .string)
        }.disabled(session.information == nil).help(String(localized:"information.copies.connection.details.without.the.server.address.or.desktop.name", defaultValue:"Copies connection details without the server address or desktop name."))
          .accessibilityIdentifier("information.copy")
        Spacer(); Button(String(localized:"action.done", defaultValue:"Done"), action: dismiss).keyboardShortcut(.defaultAction).accessibilityIdentifier("information.done")
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
