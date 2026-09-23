// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import UniformTypeIdentifiers
import TidyVNCNative

struct TrustFileSettingsFields: View {
  @Binding var patch: NativeTrustFiles
  let inherited: NativeTrustFiles
  let inheritance: String
  let contextID: String
  var scopeMessage = String(localized:"settings.defaults.changes.apply.to.new.connection.windows", defaultValue:"Changes apply to new connection windows.")
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
      Text(String(localized:"settings.trustFiles.for.x509.tls.connections.a.ca.file.adds.certificate.authorities.to.system", defaultValue:"For X509 TLS connections, a CA file adds certificate authorities to system trust. A CRL file adds certificate revocations. Files must contain PEM data."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      file(String(localized:"settings.trustFiles.certificate.authorities", defaultValue:"Certificate authorities"), .ca, \NativeTrustFiles.caFile)
      file(String(localized:"settings.trustFiles.certificate.revocations", defaultValue:"Certificate revocations"), .crl, \NativeTrustFiles.crlFile)
      Text(String(localized:"settings.trustFiles.selected.files.are.read.at.each.connection.attempt.if.a.file.cannot", defaultValue:"Selected files are read at each connection attempt. If a file cannot be loaded, the connection fails."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Text(scopeMessage)
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
      Toggle(field == .ca ? String(localized:"settings.trustFiles.override.certificate.authorities", defaultValue:"Override certificate authorities") : String(localized:"settings.trustFiles.override.certificate.revocations", defaultValue:"Override certificate revocations"), isOn: Binding(get: { patch[keyPath: key] != nil }, set: {
        patch[keyPath: key] = $0 ? (inherited[keyPath: key] ?? "") : nil
      })).accessibilityIdentifier("trustFiles.override.\(field)")
      VStack(alignment: .leading, spacing: 6) {
        TextField("", text: Binding(get: { patch[keyPath: key] ?? inherited[keyPath: key] ?? "" }, set: { patch[keyPath: key] = $0 }))
          .textFieldStyle(.roundedBorder).accessibilityLabel(title).accessibilityIdentifier("trustFiles.path.\(field)")
        HStack {
        Button(String(localized:"settings.trustFiles.choose", defaultValue:"Choose…")) {
          selection.field = field; selection.submitted = patch; selection.context = contextID; selection.showing = true
        }.accessibilityLabel(field == .ca ? String(localized:"settings.trustFiles.choose.certificate.authorities.file", defaultValue:"Choose certificate authorities file") : String(localized:"settings.trustFiles.choose.certificate.revocations.file", defaultValue:"Choose certificate revocations file"))
        Button(String(localized:"settings.trustFiles.none", defaultValue:"None")) { patch[keyPath: key] = "" }.accessibilityLabel(field == .ca ? String(localized:"settings.trustFiles.no.additional.certificate.authorities.file", defaultValue:"No additional certificate authorities file") : String(localized:"settings.trustFiles.no.additional.certificate.revocations.file", defaultValue:"No additional certificate revocations file"))
        }
      }.disabled(patch[keyPath: key] == nil)
      if let path = patch[keyPath: key], !NativeTrustFiles.isValidPath(path) {
        Text(String(localized:"settings.trustFiles.enter.a.valid.full.file.path.or.leave.it.empty.for.no", defaultValue:"Enter a valid full file path, or leave it empty for no additional file."))
          .font(.caption).foregroundStyle(Color.nativeErrorText).fixedSize(horizontal: false, vertical: true)
      } else {
        Text(patch[keyPath: key] == nil ? String(localized:"settings.trustFiles.inherited.status", defaultValue:"\(inheritance): \((inherited[keyPath: key] ?? "").isEmpty ? String(localized:"settings.trustFiles.no.additional.file", defaultValue:"no additional file") : String(localized:"settings.trustFiles.selected.file", defaultValue:"selected file"))") :
          patch[keyPath: key] == "" ? String(localized:"settings.trustFiles.no.additional.file.title", defaultValue:"No additional file") : String(localized:"settings.trustFiles.selected.file.title", defaultValue:"Selected file"))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}
