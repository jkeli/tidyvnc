// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

private typealias SSHFieldState<Value> = SwiftUI.State<Value>

struct SSHAuthenticationSheet: View {
  @ObservedObject var interaction: NativeSSHInteraction
  let request: NativeSSHQuestion
  let cancel: @MainActor () -> Void
  @SSHFieldState<String> private var response = ""
  @SSHFieldState<String?> private var problem = nil
  @FocusState private var focused: Bool
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text(request.kind == .hostKey ? String(localized:"ssh.verify.ssh.gateway.identity", defaultValue:"Verify SSH gateway identity") : String(localized:"ssh.ssh.gateway.authentication", defaultValue:"SSH gateway authentication")).font(.title2.bold())
      ScrollView {
        details.frame(maxWidth:.infinity,alignment:.leading)
      }.accessibilityIdentifier("ssh.details")
      ViewThatFits(in:.horizontal) {
        HStack { Spacer(); actions.fixedSize() }
        VStack(alignment:.trailing,spacing:8) { actions.fixedSize() }.frame(maxWidth:.infinity,alignment:.trailing)
      }
    }.padding(24).frame(width:460,height:570)
      .onAppear { focused = request.kind == .response }
      .onDisappear { response = "" }
      .onExitCommand { response = ""; cancel() }
  }
  private var details: some View {
    VStack(alignment:.leading,spacing:16) {
      LabeledContent(String(localized:"ssh.gateway", defaultValue:"Gateway")) {
        Text(verbatim:request.gateway.canonicalURI).lineLimit(3).truncationMode(.middle)
          .textSelection(.enabled).help(request.gateway.canonicalURI)
      }
      LabeledContent(String(localized:"ssh.remote.desktop", defaultValue:"Remote desktop")) {
        Text(verbatim:request.endpoint).lineLimit(3).truncationMode(.middle)
          .textSelection(.enabled).help(request.endpoint)
      }
      if let key = request.hostKey {
        LabeledContent(String(localized:"ssh.key.type", defaultValue:"Key type"),value:key.algorithm)
        Text(verbatim:key.fingerprint).font(.system(.body,design:.monospaced)).textSelection(.enabled)
          .accessibilityIdentifier("ssh.fingerprint")
        Text(String(localized:"ssh.verify.this.fingerprint.with.the.gateway.administrator", defaultValue:"Verify this fingerprint with the gateway administrator. Trust and Save lets SSH add this key to your known-hosts file before authentication. A changed saved key is rejected."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Text(String(localized:"ssh.request.from.ssh", defaultValue:"Request from SSH")).font(.headline)
      Text(verbatim:request.text).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
        .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("ssh.prompt")
      if request.kind == .response {
        SecureField(String(localized:"ssh.response", defaultValue:"Response"),text:$response).textFieldStyle(.roundedBorder).focused($focused)
          .onSubmit { submit(response) }.accessibilityIdentifier("ssh.response")
        Text(String(localized:"ssh.used.once.for.this.ssh.request.it", defaultValue:"Used once for this SSH request. It is not saved as a desktop password."))
          .font(.caption).foregroundStyle(.secondary)
      }
      if let problem { Text(problem).foregroundStyle(Color.nativeErrorText).accessibilityIdentifier("ssh.error") }
    }
  }
  @ViewBuilder private var actions: some View {
        Button(String(localized:"action.cancel", defaultValue:"Cancel"),role:.cancel) { response = ""; cancel() }
          .keyboardShortcut(request.kind == .response ? .cancelAction : .defaultAction)
          .accessibilityIdentifier("ssh.cancel")
        if request.kind == .response {
          Button(String(localized:"ssh.continue", defaultValue:"Continue")) { submit(response) }.keyboardShortcut(.defaultAction).accessibilityIdentifier("ssh.submit")
        } else if let key = request.hostKey {
          Button(String(localized:"ssh.trust.and.save", defaultValue:"Trust and Save")) { submit(key.fingerprint) }.accessibilityIdentifier("ssh.trust")
        } else {
          Button(request.kind == .permission ? String(localized:"ssh.allow.once", defaultValue:"Allow Once") : String(localized:"ssh.continue", defaultValue:"Continue")) {
            submit(request.kind == .permission ? "yes" : "")
          }.accessibilityIdentifier("ssh.allow")
        }
  }
  private func submit(_ value: String) {
    var bytes = Array(value.utf8); response = ""
    do { try interaction.respond(request.id,bytes:&bytes) }
    catch { problem = String(localized:"ssh.the.response.could.not.be.submitted.use", defaultValue:"The response could not be submitted. Use at most 1023 UTF-8 bytes without line breaks, or cancel and connect again.") }
  }
}
