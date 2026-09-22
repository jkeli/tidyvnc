// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

func historyMessage(_ error: NativeStorageError) -> String {
  switch error {
  case .futureSchema, .unsupportedFields: return "Recent connections require a newer version of TidyVNC. Saved data has been preserved."
  case .corrupt, .invalid, .invalidTLSPriority, .unsupportedValue, .tooLarge, .resourceLimit: return "Recent connections could not be read or saved. Existing data has been preserved."
  case .denied: return "Access to recent connections was denied. Check the native storage folder’s access and try again."
  case .conflict: return "Saved connections changed elsewhere. Reload before making changes."
  case .busy: return "Another operation is updating saved connections. Try again."
  case .notFound: return "The saved connection or its storage folder is no longer available. Try reloading."
  case .cancelled, .ioFailure: return "The history update could not be confirmed. Reload to check the saved connections."
  case .unavailable, .closed: return "Recent connections are unavailable. Try again."
  }
}

struct RecentHistoryStatus: View {
  @ObservedObject var model: NativeRecentHistory
  var body: some View {
    if let error = model.error {
      HStack(alignment: .top) {
        Text(historyMessage(error)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button("Reload History") { model.reload() }.disabled(model.isBusy)
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
      .help("Recent connections").accessibilityLabel("Recent connections").accessibilityIdentifier("connection.recent")
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
      Text("Recent Connections").font(.headline)
      Text("Choose an address, then select Connect.").foregroundStyle(.secondary).font(.caption)
      if model.connections.isEmpty {
        Text(model.hasLoaded ? "No recent connections." : "Recent connections have not loaded.")
          .foregroundStyle(.secondary).padding(.vertical, 12)
      } else {
        ScrollView {
          VStack(spacing: 6) {
            ForEach(model.connections, id: \.self) { destination in
              HStack {
                Button { select(destination) } label: {
                  VStack(alignment:.leading,spacing:2) {
                    Text(verbatim:destination.endpoint).lineLimit(1).truncationMode(.middle)
                    if let gateway = destination.sshGateway { Text("Via \(gateway.canonicalURI)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                  }.frame(maxWidth:.infinity,alignment:.leading)
                }.buttonStyle(.plain).disabled(!canSelect).help(destination.endpoint + (destination.sshGateway.map { " via " + $0.canonicalURI } ?? ""))
                  .accessibilityHint("Places this address and its gateway in the connection fields")
                Button { model.remove(destination) } label: { Image(systemName: "xmark.circle") }
                  .buttonStyle(.borderless).disabled(!model.canEdit).help("Remove from recent connections").accessibilityLabel("Remove \(destination.endpoint) from recent connections")
              }.padding(.vertical, 4)
            }
          }
        }.frame(height: min(CGFloat(model.connections.count) * 52, 260))
      }
      if let error = model.error {
        Text(historyMessage(error)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
      if model.isBusy { ProgressView("Updating recent connections…").controlSize(.small) }
      HStack {
        Button("Reload") { model.reload() }.disabled(model.isBusy)
        Spacer()
        Button("Clear Recent Connections") { model.clear() }.disabled(!model.canEdit || model.connections.isEmpty)
          .accessibilityIdentifier("history.clear")
      }
    }.padding(18).frame(width: 440)
      .onAppear { if !model.isBusy { model.reload() } }
  }
}
