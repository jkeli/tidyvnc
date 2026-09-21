// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
import TidyVNCNative

func preferencesMessage(_ error: NativePreferencesError) -> String {
  switch error {
  case .futureSchema, .unsupportedFields: return "These saved defaults require a newer version of TidyVNC. They have been preserved."
  case .invalidTLSPriority: return "The TLS priority expression is invalid. Correct it or use the library default. Saved values have been preserved."
  case .invalidValue: return "A setting is outside the supported range. Saved values have been preserved."
  case .unsupportedValue: return "A saved setting is unavailable in this build. Saved values have been preserved."
  case .corrupt, .tooLarge: return "Saved defaults could not be read. They have been preserved."
  case .conflict: return "Saved defaults changed while you were editing. Reload them before applying changes."
  case .denied: return "Access to saved defaults was denied. Check access and try again."
  case .cancelled: return "The defaults operation was cancelled. Reload to check the saved values."
  case .ioFailure: return "The defaults operation could not be confirmed. Reload to check the saved values before retrying."
  default: return "Saved defaults are unavailable. Try again."
  }
}

struct PreferencesSettingsView: View {
  @ObservedObject var model: NativePreferencesDraft
  enum Section: Hashable { case clipboard, encoding, input, scaling, trust, security, connection, remoteResize, fullscreen }
  @MainActor private final class Selection: ObservableObject {
    @Published var section: Section
    init(_ section: Section) { self.section = section }
  }
  @StateObject private var selection: Selection
  init(model: NativePreferencesDraft, section: Section = .clipboard) {
    self.model = model; _selection = StateObject(wrappedValue: Selection(section))
  }
  @ViewBuilder private var encodingFields: some View {
    if let options = try? (model.values.encoding ?? NativeEncodingPreferences()).resolved(),
       let values = try? Dictionary(uniqueKeysWithValues: NativeEncodingOption.allCases.map { ($0, try options.value(for: $0)) }) {
      EncodingSettingsFields(values: values, schema: model.encodingSchema, choices: model.encodingChoices, setValue: model.setEncoding)
    } else { Text("Encoding settings could not be resolved. Reload the saved defaults.") }
  }
  private let builtIn = NativeSessionConfiguration()
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Connection Defaults").font(.title2)
      Text("These defaults apply to new connection windows. Existing connections keep their own settings.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Picker("Section",selection:$selection.section) {
        Text("Clipboard").tag(Section.clipboard)
        Text("Encoding").tag(Section.encoding)
        Text("Input").tag(Section.input)
        Text("Scaling").tag(Section.scaling)
        Text("Security").tag(Section.security)
        Text("Connection").tag(Section.connection)
        Text("Remote Resize").tag(Section.remoteResize)
        Text("Fullscreen").tag(Section.fullscreen)
        if selection.section == .trust { Text("Certificate Files").tag(Section.trust) }
      }.pickerStyle(.menu).accessibilityIdentifier("preferences.section")
      VStack(alignment: .leading, spacing: 12) {
        if selection.section == .clipboard {
          GroupBox("Clipboard") {
            VStack(alignment: .leading, spacing: 10) {
              Toggle("Send clipboard to server", isOn: Binding(get: { model.values.clipboardSend ?? builtIn.clipboardSend },
                set: { model.values.clipboardSend = $0 })).accessibilityIdentifier("preferences.clipboard.send")
              Text(model.values.clipboardSend == nil ? "Uses the built-in default" : "App default override").font(.caption).foregroundStyle(.secondary)
              Toggle("Receive clipboard from server", isOn: Binding(get: { model.values.clipboardReceive ?? builtIn.clipboardReceive },
                set: { model.values.clipboardReceive = $0 })).accessibilityIdentifier("preferences.clipboard.receive")
              Text(model.values.clipboardReceive == nil ? "Uses the built-in default" : "App default override").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
          }
        } else if selection.section == .fullscreen {
          FullscreenDefaultsFields(patch:Binding(get:{ model.values.fullscreen ?? .init() },set:{
            if !model.isBusy && !model.needsReload { model.values.fullscreen = $0 == .init() ? nil : $0 }
          }),inherited:.builtIn,inheritance:"Built-in default").padding(8)
        } else if selection.section == .remoteResize {
          RemoteResizeSettingsFields(patch:Binding(get: { model.values.remoteResize ?? .init() },set: {
            if !model.isBusy && !model.needsReload { model.values.remoteResize = $0 == .init() ? nil : $0 }
          }),inherited:builtIn.resizePolicy,inheritance:"Built-in default").padding(8)
        } else if selection.section == .connection {
          ConnectionSettingsFields(shared:$model.values.shared,reconnectOnError:$model.values.reconnectOnError,
            inheritedShared:builtIn.shared,inheritedReconnectOnError:builtIn.reconnectOnError,inheritance:"Built-in default").padding(8)
          Text("Changes apply to new connection windows.").font(.caption).foregroundStyle(.secondary)
        } else if selection.section == .security {
          Button("Certificate Files…") { selection.section = .trust }.accessibilityIdentifier("security.files")
          ScrollView {
            if let inherited = model.securityDefaults {
              SecuritySettingsFields(patch: Binding(get: { model.values.security ?? NativeSecurityPreferences() },set: {
                if !model.isBusy && !model.needsReload { model.values.security = $0 == NativeSecurityPreferences() ? nil : $0 }
              }),inherited: inherited,choices: model.securityChoices,inheritance: "Use built-in defaults").padding(4)
            }
          }
        } else if selection.section == .trust {
          Button("Authentication & Encryption") { selection.section = .security }

          GroupBox("Certificate Files") {
            TrustFileSettingsFields(patch: Binding(get: { model.values.trustFiles ?? NativeTrustFiles() }, set: {
              if !model.isBusy && !model.needsReload { model.values.trustFiles = $0 == NativeTrustFiles() ? nil : $0 }
            }), inherited: NativeTrustFiles(), inheritance: "Use built-in default", contextID: "defaults").padding(8)
          }
        } else if selection.section == .scaling {
          GroupBox("Scaling") {
            ScalingDefaultsFields(patch: Binding(get: { model.values.scaling ?? NativeScalingPreferences() }, set: {
              model.values.scaling = $0 == NativeScalingPreferences() ? nil : $0
            }), inherited: .builtIn, inheritance: "Use built-in default").padding(8)
          }
        } else if selection.section == .input {
          GroupBox("Input") {
            InputDefaultsFields(patch: Binding(get: { model.values.input ?? NativeInputPreferences() }, set: {
              model.values.input = $0 == NativeInputPreferences() ? nil : $0
            }), inherited: NativeInputSettings(), inheritance: "Use built-in default").padding(8)
          }
        } else { GroupBox("Encoding") { encodingFields.padding(8) } }
      }.frame(height: selection.section == .input || selection.section == .scaling || selection.section == .trust || selection.section == .security ? 380 : 330, alignment: .top).disabled(model.isBusy || model.snapshot == nil || model.needsReload)
      if let error = model.error {
        Text(preferencesMessage(error)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("preferences.error")
      }
      if model.isBusy { ProgressView("Updating defaults…").controlSize(.small) }
      HStack {
        Button("Restore Built-in Defaults") { model.restoreBuiltInDefaults() }
          .disabled(model.isBusy || model.snapshot == nil || model.needsReload)
        Spacer()
        Button("Cancel Edits") { model.cancel() }.disabled(model.isBusy || !model.hasChanges).keyboardShortcut(.cancelAction)
        Button("Apply") { model.apply() }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("preferences.apply")
      }
      if model.needsReload || model.snapshot == nil {
        Button(model.hasChanges ? "Discard Edits and Reload" : "Reload Saved Defaults") { model.reload() }.disabled(model.isBusy)
      }
    }.padding(24).frame(width: 560)
      .onAppear { if !model.isBusy && !model.hasChanges { model.reload() } }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        if !model.isBusy && !model.hasChanges { model.reload() }
      }
      .onDisappear { model.cancel() }
  }
}
