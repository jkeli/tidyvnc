// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

func encodingDraftMessage(_ error: NativeEncodingDraftError) -> String {
  switch error {
  case .unavailable: return "Encoding settings are available while this connection is connected."
  case .invalidValue: return "The encoding value is invalid. Check the value and try again."
  case .unsupportedValue: return "This encoding is unavailable in this build. Choose an available encoding."
  case .changed: return "The connection or its settings changed. Reload before applying your edits."
  case .cancelled: return "Apply was cancelled. Some changes may already have taken effect. Reload to check the current settings."
  case .applyFailed: return "The change could not be confirmed. Reload to check the current settings before retrying."
  }
}

struct SessionEncodingSheet: View {
  @ObservedObject var model: NativeSessionEncodingDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Connection Encoding").font(.title2)
      Text("Changes apply only to this connection and are kept when it reconnects. App defaults and other connections are unchanged.")
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if !model.values.isEmpty {
        GroupBox("Encoding") {
          EncodingSettingsFields(values: model.values, schema: model.schema, choices: model.choices,
            liveOnly: true, setValue: model.setEncoding).padding(8)
        }.disabled(model.isBusy || model.needsReload || !model.isAvailable)
      }
      if let error = model.error {
        Text(encodingDraftMessage(error)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("encoding.error")
      }
      if model.didApply {
        Text("Settings applied to this connection. Image quality can change as updates arrive.")
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if model.isBusy { ProgressView("Applying encoding settings…").controlSize(.small) }
      HStack {
        if model.needsReload {
          Button(model.hasChanges ? "Discard Edits and Reload" : "Reload Current Settings") { model.reload() }
            .disabled(!model.canReload)
        }
        Spacer()
        if model.isBusy { Button("Cancel Apply") { model.cancelApply() } }
        else {
          Button(model.hasChanges ? "Cancel" : "Done") { model.cancelEdits(); dismiss() }.keyboardShortcut(.cancelAction)
        }
        Button("Apply") { model.apply() }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("encoding.apply")
      }
    }.padding(24).frame(width: 590)
      .onAppear { if model.values.isEmpty { model.reload() } }
      .interactiveDismissDisabled(model.isBusy)
  }
}
