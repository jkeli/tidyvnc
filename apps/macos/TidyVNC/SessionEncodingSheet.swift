// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

func encodingDraftMessage(_ error: NativeEncodingDraftError) -> String {
  switch error {
  case .unavailable: return String(localized:"settings.encoding.session.encoding.settings.are.available.while.this.connection.is.connected", defaultValue:"Encoding settings are available while this connection is connected.")
  case .invalidValue: return String(localized:"settings.encoding.session.the.encoding.value.is.invalid.check.the.value.and.try.again", defaultValue:"The encoding value is invalid. Check the value and try again.")
  case .unsupportedValue: return String(localized:"settings.encoding.session.this.encoding.is.unavailable.in.this.build.choose.an.available.encoding", defaultValue:"This encoding is unavailable in this build. Choose an available encoding.")
  case .changed: return String(localized:"settings.encoding.session.the.connection.or.its.settings.changed.reload.before.applying.your.edits", defaultValue:"The connection or its settings changed. Reload before applying your edits.")
  case .cancelled: return String(localized:"settings.encoding.session.apply.was.cancelled.some.changes.may.already.have.taken.effect.reload.to", defaultValue:"Apply was cancelled. Some changes may already have taken effect. Reload to check the current settings.")
  case .applyFailed: return String(localized:"settings.encoding.session.the.change.could.not.be.confirmed.reload.to.check.the.current.settings", defaultValue:"The change could not be confirmed. Reload to check the current settings before retrying.")
  }
}

struct SessionEncodingSheet: View {
  @ObservedObject var model: NativeSessionEncodingDraft
  let dismiss: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(String(localized:"settings.encoding.session.connection.encoding", defaultValue:"Connection Encoding")).font(.title2)
      Text(String(localized:"settings.encoding.session.changes.apply.only.to.this.connection.and.are.kept.when.it.reconnects", defaultValue:"Changes apply only to this connection and are kept when it reconnects. App defaults and other connections are unchanged."))
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if !model.values.isEmpty {
        GroupBox(String(localized:"settings.section.encoding", defaultValue:"Encoding")) {
          EncodingSettingsFields(values: model.values, schema: model.schema, choices: model.choices,
            liveOnly: true, setValue: model.setEncoding).padding(8)
        }.disabled(model.isBusy || model.needsReload || !model.isAvailable)
      }
      if let error = model.error {
        Text(encodingDraftMessage(error)).foregroundStyle(Color.nativeErrorText).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("encoding.error")
      }
      if model.needsReload {
        Button(model.hasChanges ? String(localized:"action.discard.edits.reload", defaultValue:"Discard Edits and Reload") : String(localized:"settings.encoding.session.reload.current.settings", defaultValue:"Reload Current Settings")) { model.reload() }
          .disabled(!model.canReload)
      }
      if model.didApply {
        Text(String(localized:"settings.encoding.session.settings.applied.to.this.connection.image.quality.can.change.as.updates.arrive", defaultValue:"Settings applied to this connection. Image quality can change as updates arrive."))
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if model.isBusy { ProgressView(String(localized:"settings.encoding.session.applying.encoding.settings", defaultValue:"Applying encoding settings…")).controlSize(.small) }
      HStack {
        Spacer()
        if model.isBusy { Button(String(localized:"settings.encoding.session.cancel.apply", defaultValue:"Cancel Apply")) { model.cancelApply() } }
        else {
          Button(model.hasChanges ? String(localized:"action.cancel", defaultValue:"Cancel") : String(localized:"action.done", defaultValue:"Done")) { model.cancelEdits(); dismiss() }.keyboardShortcut(.cancelAction)
        }
        Button(String(localized:"action.apply", defaultValue:"Apply")) { model.apply() }.disabled(!model.canApply).keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("encoding.apply")
      }
    }.padding(24).frame(width: 590)
      .onAppear { if model.values.isEmpty { model.reload() } }
      .interactiveDismissDisabled(model.isBusy)
  }
}
