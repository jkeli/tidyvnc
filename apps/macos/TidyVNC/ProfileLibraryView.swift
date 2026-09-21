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
  case .futureSchema, .unsupportedFields: return "Saved profiles require a newer version of TidyVNC. Existing data has been preserved."
  case .denied: return "Access to saved profiles was denied. Check the native storage folder’s access and reload."
  case .conflict: return "Saved profiles or recent connections changed elsewhere. Reload before saving or deleting."
  case .notFound: return "This saved profile is no longer available. Choose another profile or create a new connection."
  case .busy: return "Another operation is updating saved connections. Reload and try again."
  case .invalidTLSPriority: return "The TLS priority expression is invalid. Correct it or use the library default. The profile has not been changed."
  case .invalid, .tooLarge, .resourceLimit: return "The profile could not be saved. Check the name, address and settings, then reload."
  case .corrupt, .unsupportedValue: return "Saved profiles could not be read. Existing data has been preserved."
  case .cancelled, .ioFailure: return "The profile operation could not be confirmed. Reload to check the saved profiles."
  case .closed, .unavailable: return "Saved profiles are unavailable. Try reloading."
  }
}

struct ProfileLibraryView: View {
  @ObservedObject var model: NativeProfileLibrary
  let open: (UUID) -> Void
  @MainActor private final class Presentation: ObservableObject { @Published var confirmDelete = false }
  @StateObject private var presentation = Presentation()
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Saved Profiles").font(.title2)
      Text("Save an address and its connection settings. Open creates a new connection window; select Connect when ready.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading) {
          if model.profiles.isEmpty { Text(model.hasLoaded ? "No saved profiles." : "Profiles have not loaded.").foregroundStyle(.secondary) }
          ScrollView {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(model.profiles) { profile in
                Button { model.select(profile.id) } label: {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: profile.name).lineLimit(2)
                    Text(verbatim: profile.endpoint).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                  }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    .background(model.draft?.id == profile.id ? Color.accentColor.opacity(0.15) : Color.clear)
                }.buttonStyle(.plain).disabled(!model.canEdit || model.hasChanges)
                  .accessibilityAddTraits(model.draft?.id == profile.id ? .isSelected : [])
              }
            }
          }
          Button("New Profile") { model.newProfile() }
            .disabled(!model.canEdit || model.hasChanges || model.profiles.count >= NativeProfileHistoryStore.profileCapacity)
            .accessibilityIdentifier("profiles.new")
        }.frame(width: 210)
        Divider()
        ScrollView {
          if let draft = model.draft {
            VStack(alignment: .leading, spacing: 12) {
              TextField("Profile name", text: text(\.name)).textFieldStyle(.roundedBorder).accessibilityIdentifier("profiles.name")
              TextField("Server address", text: text(\.endpoint)).textFieldStyle(.roundedBorder).accessibilityIdentifier("profiles.endpoint")
                .help("Enter host:display, host::port, [IPv6]:display, or a Unix socket path.")
              EndpointIssueView(issue: model.endpointIssue)
              Text("Settings without a profile override use app defaults for each new connection.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              GroupBox("Connection") {
                ConnectionSettingsFields(shared:Binding(get: { model.draft?.settings.shared },set: { if model.canEdit { model.draft?.settings.shared = $0 } }),
                  reconnectOnError:Binding(get: { model.draft?.settings.reconnectOnError },set: { if model.canEdit { model.draft?.settings.reconnectOnError = $0 } }),
                  inheritedShared:model.inheritedShared,inheritedReconnectOnError:model.inheritedReconnectOnError,inheritance:"App default").padding(8)
              }
              GroupBox("Fullscreen") {
                FullscreenDefaultsFields(patch:Binding(get:{ model.draft?.settings.fullscreen ?? .init() },set:{
                  if model.canEdit { model.draft?.settings.fullscreen = $0 == .init() ? nil : $0 }
                }),inherited:model.inheritedFullscreenPolicy,inheritance:"App default").padding(8)
              }
              GroupBox("Remote Resize") {
                RemoteResizeSettingsFields(patch:Binding(get: { model.draft?.settings.remoteResize ?? .init() },set: {
                  if model.canEdit { model.draft?.settings.remoteResize = $0 == .init() ? nil : $0 }
                }),inherited:model.inheritedResizePolicy,inheritance:"App default").padding(8)
              }
              GroupBox("Clipboard") {
                VStack {
                  clipboard("Send clipboard to server", \NativePreferences.clipboardSend)
                  clipboard("Receive clipboard from server", \NativePreferences.clipboardReceive)
                }.padding(8)
              }
              if let inherited = model.inheritedSecurity {
                DisclosureGroup("Security Methods") {
                  SecuritySettingsFields(patch:Binding(get: { model.draft?.settings.security ?? NativeSecurityPreferences() },set: {
                    if model.canEdit { model.draft?.settings.security = $0 == NativeSecurityPreferences() ? nil : $0 }
                  }),inherited:inherited,choices:model.securityChoices,inheritance:"Use app defaults",inheritedPriority:model.inheritedTLSPriority).padding(8)
                }
              }
              GroupBox("Certificate Files") {
                TrustFileSettingsFields(patch: Binding(get: { model.draft?.settings.trustFiles ?? NativeTrustFiles() }, set: {
                  if model.canEdit { model.draft?.settings.trustFiles = $0 == NativeTrustFiles() ? nil : $0 }
                }), inherited: model.inheritedTrustFiles, inheritance: "Use app default", contextID: draft.id.uuidString).padding(8)
              }
              GroupBox("Scaling") {
                ScalingDefaultsFields(patch: Binding(get: { model.draft?.settings.scaling ?? NativeScalingPreferences() }, set: {
                  if model.canEdit { model.draft?.settings.scaling = $0 == NativeScalingPreferences() ? nil : $0 }
                }), inherited: model.inheritedScaling, inheritance: "Use app default").padding(8)
              }
              GroupBox("Input") {
                InputDefaultsFields(patch: Binding(get: { model.draft?.settings.input ?? NativeInputPreferences() }, set: {
                  if model.canEdit { model.draft?.settings.input = $0 == NativeInputPreferences() ? nil : $0 }
                }), inherited: model.inheritedInput, inheritance: "Use app default").padding(8)
              }
              GroupBox("Encoding") {
                VStack(alignment: .leading) {
                  EncodingSettingsFields(values: model.encodingValues, schema: model.schema, choices: model.choices,
                    setValue: { model.setEncoding($0, value: $1) }, inheritValue: { model.setEncoding($0, value: nil) })
                  Button("Use App Defaults for All Encoding Settings") { model.inheritEncoding() }
                    .disabled(draft.settings.encoding == nil)
                }.padding(8)
              }
              if draft.credentialReference != nil {
                Text("This profile’s saved credential reference is preserved. Credential management is not yet available here.")
                  .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              }
            }.disabled(!model.canEdit)
          } else {
            Text("Choose a profile or create a new one.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
          }
        }
      }
      if let error = model.error { Text(profileMessage(error)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
      if model.defaultsError != nil { Text("App defaults could not be loaded. Resolve the defaults error and reload profiles.").foregroundStyle(.red) }
      if model.isBusy { ProgressView("Updating profiles…").controlSize(.small) }
      HStack {
        Button(model.hasChanges ? "Discard Edits and Reload" : "Reload") { model.reload() }.disabled(model.isBusy)
        Button("Delete…") { presentation.confirmDelete = true }.disabled(!model.canUse)
          .confirmationDialog("Delete this saved profile?", isPresented: $presentation.confirmDelete) {
            Button("Delete Profile", role: .destructive) { model.deleteSelected() }
          } message: { Text("Existing connections, recent history and stored credentials are kept.") }
        Spacer()
        Button("Cancel Edits") { model.cancelEdits() }.disabled(model.isBusy || !model.hasChanges).keyboardShortcut(.cancelAction)
        Button("Save") { model.save() }.disabled(!model.canSave).keyboardShortcut(.defaultAction).accessibilityIdentifier("profiles.save")
        Button("Open Connection") { if let id = model.draft?.id, model.canUse { open(id) } }.disabled(!model.canUse)
          .accessibilityIdentifier("profiles.open")
      }
    }.padding(24).frame(minWidth: 900, idealWidth: 940, minHeight: 640, idealHeight: 680)
      .onAppear { model.refreshIfClean() }
      .onDisappear { model.cancelEdits() }
  }
  private func text(_ path: WritableKeyPath<NativeConnectionProfile, String>) -> Binding<String> {
    Binding(get: { model.draft?[keyPath: path] ?? "" }, set: { if model.canEdit { model.draft?[keyPath: path] = $0 } })
  }
  private func clipboard(_ title: String, _ path: WritableKeyPath<NativePreferences, Bool?>) -> some View {
    Picker(title, selection: Binding(get: { model.draft?.settings[keyPath: path] }, set: { model.draft?.settings[keyPath: path] = $0 })) {
      Text("Use app default").tag(nil as Bool?)
      Text("On").tag(true as Bool?)
      Text("Off").tag(false as Bool?)
    }
  }
}
