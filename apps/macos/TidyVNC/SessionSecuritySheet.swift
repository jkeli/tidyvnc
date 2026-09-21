// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

struct SessionSecuritySheet: View {
  @ObservedObject var model: NativeSessionSecurityDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment:.leading,spacing:12) {
      Text("Connection Security").font(.title2)
      Text("Apply while disconnected, then connect again. Changes stay in this window and do not update saved defaults or profiles.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
      Text(model.sourceDescription).font(.caption).foregroundStyle(.secondary)
      ScrollView {
        if let inherited = try? model.inherited.selection() {
          SecuritySettingsFields(patch:$model.preferences,inherited:inherited,choices:model.choices,
            inheritance:"Use this window’s initial settings",inheritedPriority:model.inherited.tlsPriority ?? "",
            scopeMessage:"Allow the methods the server may negotiate on the next connection. The server’s offer order determines the choice.")
        }
        GroupBox("Certificate Files") {
          TrustFileSettingsFields(patch:$model.trustFiles,inherited:model.inheritedFiles,
            inheritance:"Use this window’s initial settings",contextID:model.id.uuidString,scopeMessage:"Changes apply when this window connects again.").padding(8)
        }
      }.frame(height:380).disabled(model.isBusy || model.needsReload)
      if let error = model.error { Text(error).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
      if model.didApply { Text("Applied for the next connection in this window.").font(.caption).foregroundStyle(.secondary) }
      if model.isBusy { ProgressView("Checking security settings…").controlSize(.small) }
      HStack {
        if model.needsReload { Button("Discard Edits and Reload") { model.reload() }.disabled(!model.canReload) }
        Spacer()
        if model.isBusy { Button("Cancel Apply") { model.cancelApply() } }
        else { Button(model.hasChanges ? "Cancel" : "Done") { model.cancelEdits(); dismiss() }.keyboardShortcut(.cancelAction) }
        Button("Apply") { model.apply() }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("security.session.apply")
      }
    }.padding(24).frame(width:590).interactiveDismissDisabled(model.isBusy)
  }
}
