// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
import TidyVNCNative

func preferencesMessage(_ error: NativePreferencesError) -> String {
  switch error {
  case .futureSchema, .unsupportedFields: return String(localized:"settings.defaults.these.saved.defaults.require.a.newer.version.of.tidyvnc.they.have.been", defaultValue:"These saved defaults require a newer version of TidyVNC. They have been preserved.")
  case .invalidTLSPriority: return String(localized:"settings.defaults.the.tls.priority.expression.is.invalid.correct.it.or.use.the.library", defaultValue:"The TLS priority expression is invalid. Correct it or use the library default. Saved values have been preserved.")
  case .invalidValue: return String(localized:"settings.defaults.a.setting.is.outside.the.supported.range.saved.values.have.been.preserved", defaultValue:"A setting is outside the supported range. Saved values have been preserved.")
  case .unsupportedValue: return String(localized:"settings.defaults.a.saved.setting.is.unavailable.in.this.build.saved.values.have.been", defaultValue:"A saved setting is unavailable in this build. Saved values have been preserved.")
  case .corrupt, .tooLarge: return String(localized:"settings.defaults.saved.defaults.could.not.be.read.they.have.been.preserved", defaultValue:"Saved defaults could not be read. They have been preserved.")
  case .conflict: return String(localized:"settings.defaults.saved.defaults.changed.while.you.were.editing.reload.them.before.applying.changes", defaultValue:"Saved defaults changed while you were editing. Reload them before applying changes.")
  case .denied: return String(localized:"settings.defaults.access.to.saved.defaults.was.denied.check.access.and.try.again", defaultValue:"Access to saved defaults was denied. Check access and try again.")
  case .cancelled: return String(localized:"settings.defaults.the.defaults.operation.was.cancelled.reload.to.check.the.saved.values", defaultValue:"The defaults operation was cancelled. Reload to check the saved values.")
  case .ioFailure: return String(localized:"settings.defaults.the.defaults.operation.could.not.be.confirmed.reload.to.check.the.saved", defaultValue:"The defaults operation could not be confirmed. Reload to check the saved values before retrying.")
  default: return String(localized:"settings.defaults.saved.defaults.are.unavailable.try.again", defaultValue:"Saved defaults are unavailable. Try again.")
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
    } else { Text(String(localized:"settings.defaults.encoding.settings.could.not.be.resolved.reload.the.saved.defaults", defaultValue:"Encoding settings could not be resolved. Reload the saved defaults.")) }
  }
  private let builtIn = NativeSessionConfiguration()
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(String(localized:"settings.defaults.connection.defaults", defaultValue:"Connection Defaults")).font(.title2)
      Text(String(localized:"settings.defaults.these.defaults.apply.to.new.connection.windows.existing.connections.keep.their.own", defaultValue:"These defaults apply to new connection windows. Existing connections keep their own settings."))
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Picker(String(localized:"settings.defaults.section", defaultValue:"Section"),selection:$selection.section) {
        Text(String(localized:"settings.section.clipboard", defaultValue:"Clipboard")).tag(Section.clipboard)
        Text(String(localized:"settings.section.encoding", defaultValue:"Encoding")).tag(Section.encoding)
        Text(String(localized:"settings.section.input", defaultValue:"Input")).tag(Section.input)
        Text(String(localized:"settings.section.scaling", defaultValue:"Scaling")).tag(Section.scaling)
        Text(String(localized:"settings.section.security", defaultValue:"Security")).tag(Section.security)
        Text(String(localized:"settings.section.connection", defaultValue:"Connection")).tag(Section.connection)
        Text(String(localized:"settings.section.remoteResize", defaultValue:"Remote Resize")).tag(Section.remoteResize)
        Text(String(localized:"settings.section.fullscreen", defaultValue:"Fullscreen")).tag(Section.fullscreen)
        if selection.section == .trust { Text(String(localized:"settings.section.certificateFiles", defaultValue:"Certificate Files")).tag(Section.trust) }
      }.pickerStyle(.menu)
        .accessibilityLabel(String(localized:"settings.defaults.section", defaultValue:"Section"))
        .accessibilityIdentifier("preferences.section")
      ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if selection.section == .clipboard {
          GroupBox(String(localized:"settings.section.clipboard", defaultValue:"Clipboard")) {
            VStack(alignment: .leading, spacing: 10) {
              Toggle(String(localized:"settings.defaults.send.clipboard.to.server", defaultValue:"Send clipboard to server"), isOn: Binding(get: { model.values.clipboardSend ?? builtIn.clipboardSend },
                set: { model.values.clipboardSend = $0 })).accessibilityIdentifier("preferences.clipboard.send")
              Text(model.values.clipboardSend == nil ? String(localized:"settings.defaults.uses.the.built.in.default", defaultValue:"Uses the built-in default") : String(localized:"settings.defaults.app.default.override", defaultValue:"App default override")).font(.caption).foregroundStyle(.secondary)
              Toggle(String(localized:"settings.defaults.receive.clipboard.from.server", defaultValue:"Receive clipboard from server"), isOn: Binding(get: { model.values.clipboardReceive ?? builtIn.clipboardReceive },
                set: { model.values.clipboardReceive = $0 })).accessibilityIdentifier("preferences.clipboard.receive")
              Text(model.values.clipboardReceive == nil ? String(localized:"settings.defaults.uses.the.built.in.default", defaultValue:"Uses the built-in default") : String(localized:"settings.defaults.app.default.override", defaultValue:"App default override")).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
          }
        } else if selection.section == .fullscreen {
          FullscreenDefaultsFields(patch:Binding(get:{ model.values.fullscreen ?? .init() },set:{
            if !model.isBusy && !model.needsReload { model.values.fullscreen = $0 == .init() ? nil : $0 }
          }),inherited:.builtIn,inheritance:String(localized:"settings.defaults.built.in.default", defaultValue:"Built-in default")).padding(8)
        } else if selection.section == .remoteResize {
          RemoteResizeSettingsFields(patch:Binding(get: { model.values.remoteResize ?? .init() },set: {
            if !model.isBusy && !model.needsReload { model.values.remoteResize = $0 == .init() ? nil : $0 }
          }),inherited:builtIn.resizePolicy,inheritance:String(localized:"settings.defaults.built.in.default", defaultValue:"Built-in default")).padding(8)
        } else if selection.section == .connection {
          ConnectionSettingsFields(shared:$model.values.shared,reconnectOnError:$model.values.reconnectOnError,
            inheritedShared:builtIn.shared,inheritedReconnectOnError:builtIn.reconnectOnError,inheritance:String(localized:"settings.defaults.built.in.default", defaultValue:"Built-in default")).padding(8)
          Text(String(localized:"settings.defaults.changes.apply.to.new.connection.windows", defaultValue:"Changes apply to new connection windows.")).font(.caption).foregroundStyle(.secondary)
        } else if selection.section == .security {
          Button(String(localized:"settings.defaults.certificate.files", defaultValue:"Certificate Files…")) { selection.section = .trust }.accessibilityIdentifier("security.files")
          Group {
            if let inherited = model.securityDefaults {
              SecuritySettingsFields(patch: Binding(get: { model.values.security ?? NativeSecurityPreferences() },set: {
                if !model.isBusy && !model.needsReload { model.values.security = $0 == NativeSecurityPreferences() ? nil : $0 }
              }),inherited: inherited,choices: model.securityChoices,inheritance: String(localized:"settings.defaults.use.built.in.defaults", defaultValue:"Use built-in defaults")).padding(4)
            }
          }
        } else if selection.section == .trust {
          Button(String(localized:"settings.defaults.authentication.encryption", defaultValue:"Authentication & Encryption")) { selection.section = .security }

          GroupBox(String(localized:"settings.section.certificateFiles", defaultValue:"Certificate Files")) {
            TrustFileSettingsFields(patch: Binding(get: { model.values.trustFiles ?? NativeTrustFiles() }, set: {
              if !model.isBusy && !model.needsReload { model.values.trustFiles = $0 == NativeTrustFiles() ? nil : $0 }
            }), inherited: NativeTrustFiles(), inheritance: String(localized:"settings.defaults.use.built.in.default", defaultValue:"Use built-in default"), contextID: "defaults").padding(8)
          }
        } else if selection.section == .scaling {
          GroupBox(String(localized:"settings.section.scaling", defaultValue:"Scaling")) {
            ScalingDefaultsFields(patch: Binding(get: { model.values.scaling ?? NativeScalingPreferences() }, set: {
              model.values.scaling = $0 == NativeScalingPreferences() ? nil : $0
            }), inherited: .builtIn, inheritance: String(localized:"settings.defaults.use.built.in.default", defaultValue:"Use built-in default")).padding(8)
          }
        } else if selection.section == .input {
          GroupBox(String(localized:"settings.section.input", defaultValue:"Input")) {
            InputDefaultsFields(patch: Binding(get: { model.values.input ?? NativeInputPreferences() }, set: {
              model.values.input = $0 == NativeInputPreferences() ? nil : $0
            }), inherited: NativeInputSettings(), inheritance: String(localized:"settings.defaults.use.built.in.default", defaultValue:"Use built-in default")).padding(8)
          }
        } else { GroupBox(String(localized:"settings.section.encoding", defaultValue:"Encoding")) { encodingFields.padding(8) } }
      }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(minHeight: 180, idealHeight: fieldHeight, maxHeight: fieldHeight, alignment: .top)
        .disabled(model.isBusy || model.snapshot == nil || model.needsReload)
      if let error = model.error {
        VStack(alignment: .leading, spacing: 8) {
          Text(preferencesMessage(error)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("preferences.error")
          if model.needsReload || model.snapshot == nil { reloadButton }
        }
      }
      if model.isBusy { ProgressView(String(localized:"settings.defaults.updating.defaults", defaultValue:"Updating defaults…")).controlSize(.small) }
      ViewThatFits(in: .horizontal) {
        HStack { restoreButton.fixedSize(); Spacer(); commitButtons.fixedSize() }
        VStack(alignment: .leading, spacing: 10) {
          restoreButton
          HStack { Spacer(); commitButtons }
        }
      }
      if model.error == nil && (model.needsReload || model.snapshot == nil) { reloadButton }
    }.padding(24).frame(width: 560).frame(maxHeight: 640)
      .onAppear { if !model.isBusy && !model.hasChanges { model.reload() } }
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
        if !model.isBusy && !model.hasChanges { model.reload() }
      }
      .onDisappear { model.cancel() }
  }
  private var fieldHeight: CGFloat {
    selection.section == .input || selection.section == .scaling || selection.section == .trust || selection.section == .security ? 380 : 330
  }
  private var restoreButton: some View {
    Button(String(localized:"settings.defaults.restore.built.in.defaults", defaultValue:"Restore Built-in Defaults")) { model.restoreBuiltInDefaults() }
      .disabled(model.isBusy || model.snapshot == nil || model.needsReload)
  }
  private var commitButtons: some View {
    HStack {
      Button(String(localized:"settings.defaults.cancel.edits", defaultValue:"Cancel Edits")) { model.cancel() }.disabled(model.isBusy || !model.hasChanges).keyboardShortcut(.cancelAction)
      Button(String(localized:"action.apply", defaultValue:"Apply")) { model.apply() }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("preferences.apply")
    }
  }
  private var reloadButton: some View {
    Button(model.hasChanges ? String(localized:"action.discard.edits.reload", defaultValue:"Discard Edits and Reload") : String(localized:"settings.defaults.reload.saved.defaults", defaultValue:"Reload Saved Defaults")) { model.reload() }.disabled(model.isBusy)
  }
}
