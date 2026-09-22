// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

// Each explicit launch gets a separate window; restoration retains only IDs,
// and session creation rereads the profile instead of restoring stale settings.
struct ProfileConnectionRequest: Codable, Hashable {
  var windowID = UUID()
  let profileID: UUID
}
struct ProfileLibraryRoot: View {
  @ObservedObject var model: NativeProfileLibrary
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    ProfileLibraryView(model: model) { id in openWindow(id: "profile-connection", value: ProfileConnectionRequest(profileID: id)) }
  }
}
func profileMessage(_ error: NativeStorageError) -> String {
  switch error {
  case .futureSchema, .unsupportedFields: return String(localized:"profiles.saved.profiles.require.a.newer.version.of.tidyvnc.existing.data.has.been", defaultValue:"Saved profiles require a newer version of TidyVNC. Existing data has been preserved.")
  case .denied: return String(localized:"profiles.access.to.saved.profiles.was.denied.check.the.native.storage.folder.s", defaultValue:"Access to saved profiles was denied. Check the native storage folder’s access and reload.")
  case .conflict: return String(localized:"profiles.saved.profiles.or.recent.connections.changed.elsewhere.reload.before.saving.or.deleting", defaultValue:"Saved profiles or recent connections changed elsewhere. Reload before saving or deleting.")
  case .notFound: return String(localized:"profiles.this.saved.profile.is.no.longer.available.choose.another.profile.or.create", defaultValue:"This saved profile is no longer available. Choose another profile or create a new connection.")
  case .busy: return String(localized:"profiles.another.operation.is.updating.saved.connections.reload.and.try.again", defaultValue:"Another operation is updating saved connections. Reload and try again.")
  case .invalidTLSPriority: return String(localized:"profiles.the.tls.priority.expression.is.invalid.correct.it.or.use.the.library", defaultValue:"The TLS priority expression is invalid. Correct it or use the library default. The profile has not been changed.")
  case .invalid, .tooLarge, .resourceLimit: return String(localized:"profiles.the.profile.could.not.be.saved.check.the.name.address.and.settings", defaultValue:"The profile could not be saved. Check the name, address and settings, then reload.")
  case .corrupt, .unsupportedValue: return String(localized:"profiles.saved.profiles.could.not.be.read.existing.data.has.been.preserved", defaultValue:"Saved profiles could not be read. Existing data has been preserved.")
  case .cancelled, .ioFailure: return String(localized:"profiles.the.profile.operation.could.not.be.confirmed.reload.to.check.the.saved", defaultValue:"The profile operation could not be confirmed. Reload to check the saved profiles.")
  case .closed, .unavailable: return String(localized:"profiles.saved.profiles.are.unavailable.try.reloading", defaultValue:"Saved profiles are unavailable. Try reloading.")
  }
}

struct ProfileLibraryView: View {
  @ObservedObject var model: NativeProfileLibrary
  let open: (UUID) -> Void
  @MainActor private final class Presentation: ObservableObject { @Published var confirmDelete = false }
  @StateObject private var presentation = Presentation()
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(String(localized:"profiles.saved.profiles", defaultValue:"Saved Profiles")).font(.title2)
      Text(String(localized:"profiles.save.an.address.and.its.connection.settings.open.creates.a.new.connection", defaultValue:"Save an address and its connection settings. Open creates a new connection window; select Connect when ready."))
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading) {
          if model.profiles.isEmpty { Text(model.hasLoaded ? String(localized:"profiles.no.saved.profiles", defaultValue:"No saved profiles.") : String(localized:"profiles.profiles.have.not.loaded", defaultValue:"Profiles have not loaded.")).foregroundStyle(.secondary) }
          ScrollView {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(model.profiles) { profile in
                Button { model.select(profile.id) } label: {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: profile.name).lineLimit(2)
                    Text(verbatim: profile.endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let gateway = profile.sshGateway { Text(String(localized:"history.gateway", defaultValue:"Via \(gateway.canonicalURI)")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                  }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    .background(model.draft?.id == profile.id ? Color.accentColor.opacity(0.15) : Color.clear)
                }.buttonStyle(.plain).disabled(!model.canEdit || model.hasChanges)
                  .accessibilityAddTraits(model.draft?.id == profile.id ? .isSelected : [])
              }
            }
          }
          Button(String(localized:"profiles.new.profile", defaultValue:"New Profile")) { model.newProfile() }
            .disabled(!model.canEdit || model.hasChanges || model.profiles.count >= NativeProfileHistoryStore.profileCapacity)
            .accessibilityIdentifier("profiles.new")
        }.frame(width: 210)
        Divider()
        ScrollView {
          if let draft = model.draft {
            VStack(alignment: .leading, spacing: 12) {
              Text(String(localized:"profiles.profile.name", defaultValue:"Profile name")).font(.caption).fixedSize(horizontal: false, vertical: true)
              TextField("", text: text(\.name)).textFieldStyle(.roundedBorder).accessibilityLabel(String(localized:"profiles.profile.name", defaultValue:"Profile name")).accessibilityIdentifier("profiles.name")
              Text(String(localized:"profiles.server.address", defaultValue:"Server address")).font(.caption).fixedSize(horizontal: false, vertical: true)
              TextField("", text: text(\.endpoint)).textFieldStyle(.roundedBorder).accessibilityLabel(String(localized:"profiles.server.address", defaultValue:"Server address")).accessibilityIdentifier("profiles.endpoint")
                .help(String(localized:"profiles.enter.host.display.host.port.ipv6.display.or.a.unix.socket.path", defaultValue:"Enter host:display, host::port, [IPv6]:display, or a Unix socket path."))
              EndpointIssueView(issue: model.endpointIssue)
              Text(String(localized:"profiles.ssh.gateway.optional", defaultValue:"SSH gateway (optional)")).font(.caption).fixedSize(horizontal: false, vertical: true)
              TextField("",text:$model.gatewayText).textFieldStyle(.roundedBorder)
                .accessibilityLabel(String(localized:"profiles.ssh.gateway.optional", defaultValue:"SSH gateway (optional)")).accessibilityIdentifier("profiles.sshGateway")
                .help(String(localized:"profiles.enter.user.host.or.ssh.user.host.port.leave.empty.for.a", defaultValue:"Enter user@host or ssh://user@host:port. Leave empty for a direct connection."))
              if let issue = model.gatewayIssue { Text(issue).font(.caption).foregroundStyle(.red) }
              if !model.gatewayText.isEmpty {
                Text(String(localized:"profiles.ssh.reads.supported.settings.from.ssh.config.commands.and.proxy.hops.are", defaultValue:"SSH reads supported settings from ~/.ssh/config. Commands and proxy hops are unavailable. Passwords are used once; new Ed25519/RSA/ECDSA gateway keys require approval. Changed keys are rejected."))
                  .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
              }
              Text(String(localized:"profiles.settings.without.a.profile.override.use.app.defaults.for.each.new.connection", defaultValue:"Settings without a profile override use app defaults for each new connection."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              GroupBox(String(localized:"settings.section.connection", defaultValue:"Connection")) {
                ConnectionSettingsFields(shared:Binding(get: { model.draft?.settings.shared },set: { if model.canEdit { model.draft?.settings.shared = $0 } }),
                  reconnectOnError:Binding(get: { model.draft?.settings.reconnectOnError },set: { if model.canEdit { model.draft?.settings.reconnectOnError = $0 } }),
                  inheritedShared:model.inheritedShared,inheritedReconnectOnError:model.inheritedReconnectOnError,inheritance:String(localized:"settings.encoding.app.default", defaultValue:"App default")).padding(8)
              }
              GroupBox(String(localized:"settings.section.fullscreen", defaultValue:"Fullscreen")) {
                FullscreenDefaultsFields(patch:Binding(get:{ model.draft?.settings.fullscreen ?? .init() },set:{
                  if model.canEdit { model.draft?.settings.fullscreen = $0 == .init() ? nil : $0 }
                }),inherited:model.inheritedFullscreenPolicy,inheritance:String(localized:"settings.encoding.app.default", defaultValue:"App default")).padding(8)
              }
              GroupBox(String(localized:"settings.section.remoteResize", defaultValue:"Remote Resize")) {
                RemoteResizeSettingsFields(patch:Binding(get: { model.draft?.settings.remoteResize ?? .init() },set: {
                  if model.canEdit { model.draft?.settings.remoteResize = $0 == .init() ? nil : $0 }
                }),inherited:model.inheritedResizePolicy,inheritance:String(localized:"settings.encoding.app.default", defaultValue:"App default")).padding(8)
              }
              GroupBox(String(localized:"settings.section.clipboard", defaultValue:"Clipboard")) {
                VStack {
                  clipboard(String(localized:"settings.defaults.send.clipboard.to.server", defaultValue:"Send clipboard to server"), \NativePreferences.clipboardSend)
                  clipboard(String(localized:"settings.defaults.receive.clipboard.from.server", defaultValue:"Receive clipboard from server"), \NativePreferences.clipboardReceive)
                }.padding(8)
              }
              if let inherited = model.inheritedSecurity {
                DisclosureGroup(String(localized:"profiles.security.methods", defaultValue:"Security Methods")) {
                  SecuritySettingsFields(patch:Binding(get: { model.draft?.settings.security ?? NativeSecurityPreferences() },set: {
                    if model.canEdit { model.draft?.settings.security = $0 == NativeSecurityPreferences() ? nil : $0 }
                  }),inherited:inherited,choices:model.securityChoices,inheritance:String(localized:"settings.inheritance.use.app.defaults.lowercase", defaultValue:"Use app defaults"),inheritedPriority:model.inheritedTLSPriority).padding(8)
                }
              }
              GroupBox(String(localized:"settings.section.certificateFiles", defaultValue:"Certificate Files")) {
                TrustFileSettingsFields(patch: Binding(get: { model.draft?.settings.trustFiles ?? NativeTrustFiles() }, set: {
                  if model.canEdit { model.draft?.settings.trustFiles = $0 == NativeTrustFiles() ? nil : $0 }
                }), inherited: model.inheritedTrustFiles, inheritance: String(localized:"settings.encoding.use.app.default", defaultValue:"Use app default"), contextID: draft.id.uuidString).padding(8)
              }
              GroupBox(String(localized:"settings.section.scaling", defaultValue:"Scaling")) {
                ScalingDefaultsFields(patch: Binding(get: { model.draft?.settings.scaling ?? NativeScalingPreferences() }, set: {
                  if model.canEdit { model.draft?.settings.scaling = $0 == NativeScalingPreferences() ? nil : $0 }
                }), inherited: model.inheritedScaling, inheritance: String(localized:"settings.encoding.use.app.default", defaultValue:"Use app default"), resetSource: .appDefaults).padding(8)
              }
              GroupBox(String(localized:"settings.section.input", defaultValue:"Input")) {
                InputDefaultsFields(patch: Binding(get: { model.draft?.settings.input ?? NativeInputPreferences() }, set: {
                  if model.canEdit { model.draft?.settings.input = $0 == NativeInputPreferences() ? nil : $0 }
                }), inherited: model.inheritedInput, inheritance: String(localized:"settings.encoding.use.app.default", defaultValue:"Use app default"), resetSource: .appDefaults).padding(8)
              }
              GroupBox(String(localized:"settings.section.encoding", defaultValue:"Encoding")) {
                VStack(alignment: .leading) {
                  EncodingSettingsFields(values: model.encodingValues, schema: model.schema, choices: model.choices,
                    setValue: { model.setEncoding($0, value: $1) }, inheritValue: { model.setEncoding($0, value: nil) })
                  Button(String(localized:"settings.inheritance.use.app.defaults", defaultValue:"Use App Defaults")) { model.inheritEncoding() }
                    .disabled(draft.settings.encoding == nil)
                }.padding(8)
              }
              if draft.credentialReference != nil {
                Text(String(localized:"profiles.this.profile.s.saved.credential.reference.is.preserved.credential.management.is.not", defaultValue:"This profile’s saved credential reference is preserved. Credential management is not yet available here."))
                  .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              }
            }.disabled(!model.canEdit)
          } else {
            Text(String(localized:"profiles.choose.a.profile.or.create.a.new.one", defaultValue:"Choose a profile or create a new one.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
          }
        }
      }.frame(minHeight: 180, idealHeight: 430, maxHeight: 430)
      if let error = model.error { Text(profileMessage(error)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
      if model.defaultsError != nil { Text(String(localized:"profiles.app.defaults.could.not.be.loaded.resolve.the.defaults.error.and.reload", defaultValue:"App defaults could not be loaded. Resolve the defaults error and reload profiles.")).foregroundStyle(.red) }
      if model.isBusy { ProgressView(String(localized:"profiles.updating.profiles", defaultValue:"Updating profiles…")).controlSize(.small) }
      HStack {
        Button(model.hasChanges ? String(localized:"action.discard.edits.reload", defaultValue:"Discard Edits and Reload") : String(localized:"trust.library.ui.reload", defaultValue:"Reload")) { model.reload() }.disabled(model.isBusy)
        Button(String(localized:"profiles.delete", defaultValue:"Delete…")) { presentation.confirmDelete = true }.disabled(!model.canUse)
          .confirmationDialog(String(localized:"profiles.delete.this.saved.profile", defaultValue:"Delete this saved profile?"), isPresented: $presentation.confirmDelete) {
            Button(String(localized:"profiles.delete.profile", defaultValue:"Delete Profile"), role: .destructive) { model.deleteSelected() }
          } message: { Text(String(localized:"profiles.existing.connections.recent.history.and.stored.credentials.are.kept", defaultValue:"Existing connections, recent history and stored credentials are kept.")) }
      }
      HStack {
        Spacer()
        Button(String(localized:"settings.defaults.cancel.edits", defaultValue:"Cancel Edits")) { model.cancelEdits() }.disabled(model.isBusy || !model.hasChanges).keyboardShortcut(.cancelAction)
        Button(String(localized:"profiles.save", defaultValue:"Save")) { model.save() }.disabled(!model.canSave).keyboardShortcut(.defaultAction).accessibilityIdentifier("profiles.save")
        Button(String(localized:"profiles.open.connection", defaultValue:"Open Connection")) { if let id = model.draft?.id, model.canUse { open(id) } }.disabled(!model.canUse)
          .accessibilityIdentifier("profiles.open")
      }
    }.padding(24).frame(minWidth: 900, idealWidth: 900, minHeight: 640, idealHeight: 640).frame(maxHeight: 680)
      .onAppear { model.refreshIfClean() }
      .onDisappear { model.cancelEdits() }
  }
  private func text(_ path: WritableKeyPath<NativeConnectionProfile, String>) -> Binding<String> {
    Binding(get: { model.draft?[keyPath: path] ?? "" }, set: { if model.canEdit { model.draft?[keyPath: path] = $0 } })
  }
  private func clipboard(_ title: String, _ path: WritableKeyPath<NativePreferences, Bool?>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).fixedSize(horizontal: false, vertical: true)
      Picker(title, selection: Binding(get: { model.draft?.settings[keyPath: path] }, set: { model.draft?.settings[keyPath: path] = $0 })) {
        Text(String(localized:"settings.encoding.use.app.default", defaultValue:"Use app default")).tag(nil as Bool?)
        Text(String(localized:"settings.input.on", defaultValue:"On")).tag(true as Bool?)
        Text(String(localized:"settings.input.off", defaultValue:"Off")).tag(false as Bool?)
      }.labelsHidden()
    }
  }
}
