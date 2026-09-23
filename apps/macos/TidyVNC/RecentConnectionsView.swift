// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

func historyMessage(_ error: NativeStorageError) -> String {
  switch error {
  case .futureSchema, .unsupportedFields: return String(localized:"history.recent.connections.require.a.newer.version.of.tidyvnc.saved.data.has.been", defaultValue:"Recent connections require a newer version of TidyVNC. Saved data has been preserved.")
  case .corrupt, .invalid, .invalidTLSPriority, .unsupportedValue, .tooLarge, .resourceLimit: return String(localized:"history.recent.connections.could.not.be.read.or.saved.existing.data.has.been", defaultValue:"Recent connections could not be read or saved. Existing data has been preserved.")
  case .denied: return String(localized:"history.access.to.recent.connections.was.denied.check.the.native.storage.folder.s", defaultValue:"Access to recent connections was denied. Check the native storage folder’s access and try again.")
  case .conflict: return String(localized:"history.saved.connections.changed.elsewhere.reload.before.making.changes", defaultValue:"Saved connections changed elsewhere. Reload before making changes.")
  case .busy: return String(localized:"history.another.operation.is.updating.saved.connections.try.again", defaultValue:"Another operation is updating saved connections. Try again.")
  case .notFound: return String(localized:"history.the.saved.connection.or.its.storage.folder.is.no.longer.available.try", defaultValue:"The saved connection or its storage folder is no longer available. Try reloading.")
  case .cancelled, .ioFailure: return String(localized:"history.the.history.update.could.not.be.confirmed.reload.to.check.the.saved", defaultValue:"The history update could not be confirmed. Reload to check the saved connections.")
  case .unavailable, .closed: return String(localized:"history.recent.connections.are.unavailable.try.again", defaultValue:"Recent connections are unavailable. Try again.")
  }
}

struct RecentHistoryStatus: View {
  @ObservedObject var model: NativeRecentHistory
  var body: some View {
    if let error = model.error {
      HStack(alignment: .top) {
        Text(historyMessage(error)).foregroundStyle(Color.nativeWarningText).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button(String(localized:"history.reload.history", defaultValue:"Reload History")) { model.reload() }.disabled(model.isBusy)
      }.font(.caption).padding(.bottom, 8).accessibilityIdentifier("history.status")
    }
  }
}
struct RecentConnectionsButton: View {
  @ObservedObject var model: NativeRecentHistory
  let canSelect: Bool
  let select: (NativeConnectionDestination) -> Void
  @MainActor private final class Presentation: ObservableObject { @Published var shown = false }
  @StateObject private var presentation = Presentation()
  var body: some View {
    Button { presentation.shown.toggle() } label: { Image(systemName: "clock.arrow.circlepath") }
      .help(String(localized:"history.recent.connections", defaultValue:"Recent connections")).accessibilityLabel(String(localized:"history.recent.connections", defaultValue:"Recent connections")).accessibilityIdentifier("connection.recent")
      .popover(isPresented: $presentation.shown) {
        RecentConnectionsPanel(model: model, canSelect: canSelect) { endpoint in
          select(endpoint); presentation.shown = false
        }
      }
  }
}
struct RecentConnectionsPanel: View {
  @ObservedObject var model: NativeRecentHistory
  let canSelect: Bool
  let select: (NativeConnectionDestination) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(String(localized:"history.recent.connections.title", defaultValue:"Recent Connections")).font(.headline)
      Text(String(localized:"history.choose.an.address.then.select.connect", defaultValue:"Choose an address, then select Connect.")).foregroundStyle(.secondary).font(.caption)
      if model.connections.isEmpty {
        Text(model.hasLoaded ? String(localized:"history.no.recent.connections", defaultValue:"No recent connections.") : String(localized:"history.recent.connections.have.not.loaded", defaultValue:"Recent connections have not loaded."))
          .foregroundStyle(.secondary).padding(.vertical, 12)
      } else {
        ScrollView {
          VStack(spacing: 6) {
            ForEach(model.connections, id: \.self) { destination in
              HStack {
                Button { select(destination) } label: {
                  VStack(alignment:.leading,spacing:2) {
                    Text(verbatim:destination.endpoint).lineLimit(1).truncationMode(.middle)
                    if let gateway = destination.sshGateway { Text(String(localized:"history.gateway", defaultValue:"Via \(gateway.canonicalURI)")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                  }.frame(maxWidth:.infinity,alignment:.leading)
                }.buttonStyle(.plain).disabled(!canSelect).help(destination.sshGateway.map { String(localized:"history.destination.gateway", defaultValue:"\(destination.endpoint) via \($0.canonicalURI)") } ?? destination.endpoint)
                  .accessibilityHint(String(localized:"history.places.this.address.and.its.gateway.in.the.connection.fields", defaultValue:"Places this address and its gateway in the connection fields"))
                Button { model.remove(destination) } label: { Image(systemName: "xmark.circle") }
                  .buttonStyle(.borderless).disabled(!model.canEdit).help(String(localized:"history.remove.from.recent.connections", defaultValue:"Remove from recent connections")).accessibilityLabel(String(localized:"history.remove.destination", defaultValue:"Remove \(destination.endpoint) from recent connections"))
              }.padding(.vertical, 4)
            }
          }
        }.frame(height: min(CGFloat(model.connections.count) * 52, 260))
      }
      if let error = model.error {
        Text(historyMessage(error)).foregroundStyle(Color.nativeErrorText).fixedSize(horizontal: false, vertical: true)
      }
      if model.isBusy { ProgressView(String(localized:"history.updating.recent.connections", defaultValue:"Updating recent connections…")).controlSize(.small) }
      VStack(alignment: .leading, spacing: 8) {
        Button(String(localized:"trust.library.ui.reload", defaultValue:"Reload")) { model.reload() }.disabled(model.isBusy)
        Button(String(localized:"history.clear.recent.connections", defaultValue:"Clear Recent Connections")) { model.clear() }.disabled(!model.canEdit || model.connections.isEmpty)
          .accessibilityIdentifier("history.clear")
      }
    }.padding(18).frame(width: 440)
      .onAppear { if !model.isBusy { model.reload() } }
  }
}
