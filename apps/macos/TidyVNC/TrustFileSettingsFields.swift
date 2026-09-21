// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import UniformTypeIdentifiers
import TidyVNCNative

struct TrustFileSettingsFields: View {
  @Binding var patch: NativeTrustFiles
  let inherited: NativeTrustFiles
  let inheritance: String
  let contextID: String
  var scopeMessage = "Changes apply to new connection windows."
  private enum Field { case ca, crl }
  @MainActor private final class Selection: ObservableObject {
    @Published var showing = false
    var field: Field = .ca
    var submitted = NativeTrustFiles()
    var context = ""
    var active = false
  }
  @StateObject private var selection = Selection()
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("For X509 TLS connections, a CA file adds certificate authorities to system trust. A CRL file adds certificate revocations. Files must contain PEM data.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      file("Certificate authorities", .ca, \NativeTrustFiles.caFile)
      file("Certificate revocations", .crl, \NativeTrustFiles.crlFile)
      Text("Selected files are read at each connection attempt. If a file cannot be loaded, the connection fails. " + scopeMessage)
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .fileImporter(isPresented: $selection.showing, allowedContentTypes: [.item]) { result in
      guard selection.active, selection.context == contextID, selection.submitted == patch,
            case let .success(url) = result, url.isFileURL else { return }
      let path = url.path
      guard NativeTrustFiles.isValidPath(path) else { return }
      switch selection.field { case .ca: patch.caFile = path; case .crl: patch.crlFile = path }
    }
    .onAppear { selection.active = true }
    .onDisappear { selection.active = false; selection.showing = false }
    .onChange(of: contextID) { _,_ in selection.active = false; selection.showing = false; selection.active = true; selection.context = "" }
  }
  private func file(_ title: String, _ field: Field, _ key: WritableKeyPath<NativeTrustFiles,String?>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle("Override \(title.lowercased())", isOn: Binding(get: { patch[keyPath: key] != nil }, set: {
        patch[keyPath: key] = $0 ? (inherited[keyPath: key] ?? "") : nil
      })).accessibilityIdentifier("trustFiles.override.\(field)")
      HStack {
        TextField(title, text: Binding(get: { patch[keyPath: key] ?? inherited[keyPath: key] ?? "" }, set: { patch[keyPath: key] = $0 }))
          .textFieldStyle(.roundedBorder).accessibilityIdentifier("trustFiles.path.\(field)")
        Button("Choose…") {
          selection.field = field; selection.submitted = patch; selection.context = contextID; selection.showing = true
        }.accessibilityLabel("Choose \(title.lowercased()) file")
        Button("None") { patch[keyPath: key] = "" }.accessibilityLabel("No additional \(title.lowercased()) file")
      }.disabled(patch[keyPath: key] == nil)
      if let path = patch[keyPath: key], !NativeTrustFiles.isValidPath(path) {
        Text("Enter a valid full file path, or leave it empty for no additional file.")
          .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      } else {
        Text(patch[keyPath: key] == nil ? "\(inheritance): \((inherited[keyPath: key] ?? "").isEmpty ? "no additional file" : "selected file")" :
          patch[keyPath: key] == "" ? "No additional file" : "Selected file")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
