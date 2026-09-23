// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct TrustLibraryView: View {
  @ObservedObject var model: NativeTrustLibrary
  @MainActor private final class Selection: ObservableObject { @Published var pending: String?; @Published var destination = ""; @Published var pendingDestination: String? }
  @StateObject private var selection = Selection()
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(model.kind == .certificate ? String(localized:"trust.library.ui.saved.certificate.decisions", defaultValue:"Saved Certificate Decisions") : String(localized:"trust.library.ui.saved.server.keys", defaultValue:"Saved Server Keys")).font(.title2)
      Text(model.kind == .certificate ? String(localized:"trust.library.ui.exceptions.apply.to.the.displayed.destination.s.address.port.and.route.forget", defaultValue:"Exceptions apply to the displayed destination’s address, port and route. Forget removes its saved key and prevents reuse of older host-wide exceptions there. Existing connections are unchanged.") : String(localized:"trust.library.ui.rsa.aes.server.keys.are.saved.for.the.displayed.destination.s.address", defaultValue:"RSA-AES server keys are saved for the displayed destination’s address, port and route. Forget requires verification again on the next connection. Existing connections are unchanged."))
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 6) {
        Text(String(localized:"trust.library.ui.destination.host.display.or.host.port", defaultValue:"Destination (host:display or host::port)"))
          .fixedSize(horizontal: false, vertical: true)
        TextField("",text: $selection.destination).textFieldStyle(.roundedBorder)
          .accessibilityLabel(String(localized:"trust.library.ui.destination.host.display.or.host.port", defaultValue:"Destination (host:display or host::port)"))
          .accessibilityIdentifier("trustLibrary.destination")
        Button(String(localized:"trust.library.ui.ask.again", defaultValue:"Ask Again…")) { selection.pendingDestination = selection.destination }
          .disabled(model.isWorking || model.needsReload || model.snapshot == nil || NativeEndpoint.issue(for: selection.destination) != nil)
      }
      Text(model.kind == .certificate ? String(localized:"trust.library.ui.ask.again.also.suppresses.an.older.host.wide.exception.for.the.entered", defaultValue:"Ask Again also suppresses an older host-wide exception for the entered destination.") : String(localized:"trust.library.ui.ask.again.removes.any.saved.server.key.for.the.entered.destination", defaultValue:"Ask Again removes any saved server key for the entered destination.")).font(.caption).foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if model.entries.isEmpty { Text(model.snapshot == nil ? String(localized:"trust.library.ui.decisions.have.not.loaded", defaultValue:"Decisions have not loaded.") : String(localized:"trust.library.ui.no.saved.destination.decisions", defaultValue:"No saved destination decisions.")).foregroundStyle(.secondary) }
          ForEach(model.entries) { entry in
            VStack(alignment: .leading, spacing: 6) {
              Text(verbatim: entry.scope.endpoint).font(.headline).textSelection(.enabled)
              if !entry.scope.routeIdentity.isEmpty { Text(String(localized:"trust.library.route", defaultValue:"Route: \(entry.scope.routeIdentity)")).textSelection(.enabled) }
              if let fingerprint = entry.fingerprint {
                Text(entry.scope.kind.savedFingerprintMessage(fingerprint)).font(.system(.caption,design: .monospaced))
                  .textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
                Button(String(localized:"trust.library.ui.forget.for.this.destination", defaultValue:"Forget for This Destination"),role: .destructive) { selection.pending = entry.id }
                  .disabled(model.isWorking || model.needsReload).accessibilityIdentifier("trustLibrary.forget")
              } else { Text(model.kind == .certificate ? String(localized:"trust.library.ui.ask.again.when.a.certificate.exception.is.needed.legacy.host.exceptions.are", defaultValue:"Ask again when a certificate exception is needed. Legacy host exceptions are ignored here.") : String(localized:"trust.library.ui.ask.again.before.trusting.the.server.key", defaultValue:"Ask again before trusting the server key.")).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity,alignment: .leading)
            Divider()
          }
        }
      }.frame(height: 360)
      if let message = model.message { Text(message).fixedSize(horizontal: false,vertical: true).accessibilityIdentifier("trustLibrary.message") }
      HStack {
        if model.isWorking { ProgressView().controlSize(.small) }
        Spacer()
        Button(String(localized:"trust.library.ui.reload", defaultValue:"Reload")) { model.reload() }.disabled(model.isWorking).accessibilityIdentifier("trustLibrary.reload")
      }
    }.padding(24).frame(width: 570)
      .onAppear { model.reload() }
      .confirmationDialog(String(localized:"trust.library.ui.forget.the.saved.key.for.this.destination", defaultValue:"Forget the saved key for this destination?"),isPresented: Binding(get: { selection.pending != nil || selection.pendingDestination != nil },set: { if !$0 { selection.pending = nil; selection.pendingDestination = nil } })) {
        Button(String(localized:"trust.library.ui.forget.saved.key", defaultValue:"Forget Saved Key"),role: .destructive) { if let id = selection.pending { model.forget(id) }
          else if let endpoint = selection.pendingDestination { model.forgetDestination(endpoint) }
          selection.pending = nil; selection.pendingDestination = nil }
        Button(String(localized:"action.cancel", defaultValue:"Cancel"),role: .cancel) { selection.pending = nil; selection.pendingDestination = nil }.keyboardShortcut(.defaultAction)
      } message: { Text(model.entries.first(where: { $0.id == selection.pending })?.scope.endpoint ?? selection.pendingDestination ?? "") }
  }
}
