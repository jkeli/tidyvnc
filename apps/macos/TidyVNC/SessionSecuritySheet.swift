// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct SessionSecuritySheet: View {
  @ObservedObject var model: NativeSessionSecurityDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment:.leading,spacing:12) {
      Text(String(localized:"settings.security.connection.security", defaultValue:"Connection Security")).font(.title2)
      Text(String(localized:"settings.security.apply.while.disconnected.then.connect.again.changes.stay.in.this.window.and", defaultValue:"Apply while disconnected, then connect again. Changes stay in this window and do not update saved defaults or profiles."))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      Text(model.sourceDescription).font(.caption).foregroundStyle(.secondary)
      ScrollView {
        if let inherited = try? model.inherited.selection() {
          SecuritySettingsFields(patch:$model.preferences,inherited:inherited,choices:model.choices,
            inheritance:String(localized:"settings.security.use.this.window.s.initial.settings", defaultValue:"Use this window’s initial settings"),inheritedPriority:model.inherited.tlsPriority ?? "",
            scopeMessage:String(localized:"settings.security.allow.the.methods.the.server.may.negotiate.on.the.next.connection.the", defaultValue:"Allow the methods the server may negotiate on the next connection. The server’s offer order determines the choice."))
        }
        GroupBox(String(localized:"settings.section.certificateFiles", defaultValue:"Certificate Files")) {
          TrustFileSettingsFields(patch:$model.trustFiles,inherited:model.inheritedFiles,
            inheritance:String(localized:"settings.security.use.this.window.s.initial.settings", defaultValue:"Use this window’s initial settings"),contextID:model.id.uuidString,scopeMessage:String(localized:"settings.security.changes.apply.when.this.window.connects.again", defaultValue:"Changes apply when this window connects again.")).padding(8)
        }
      }.frame(minHeight:120,idealHeight:380,maxHeight:380).disabled(model.isBusy || model.needsReload)
      if let error = model.error { Text(error).foregroundStyle(Color.nativeErrorText).fixedSize(horizontal:false,vertical:true) }
      if model.didApply { Text(String(localized:"settings.security.applied.for.the.next.connection.in.this.window", defaultValue:"Applied for the next connection in this window.")).font(.caption).foregroundStyle(.secondary) }
      if model.isBusy { ProgressView(String(localized:"settings.security.checking.security.settings", defaultValue:"Checking security settings…")).controlSize(.small) }
      if model.needsReload { Button(String(localized:"action.discard.edits.reload", defaultValue:"Discard Edits and Reload")) { model.reload() }.disabled(!model.canReload) }
      HStack {
        Spacer()
        if model.isBusy { Button(String(localized:"settings.encoding.session.cancel.apply", defaultValue:"Cancel Apply")) { model.cancelApply() } }
        else { Button(model.hasChanges ? String(localized:"action.cancel", defaultValue:"Cancel") : String(localized:"action.done", defaultValue:"Done")) { model.cancelEdits(); dismiss() }.keyboardShortcut(.cancelAction) }
        Button(String(localized:"action.apply", defaultValue:"Apply")) { model.apply() }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("security.session.apply")
      }
    }.padding(24).frame(width:590).frame(maxHeight:640).interactiveDismissDisabled(model.isBusy)
  }
}
