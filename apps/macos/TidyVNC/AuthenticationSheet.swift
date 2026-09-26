// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import SwiftUI
import TidyVNCNative

// Select the property-wrapper type rather than the newer SDK State macro. This
// keeps the macOS 14 implementation usable with the Command Line Tools compiler.
private typealias AuthenticationFieldState<Value> = SwiftUI.State<Value>

struct AuthenticationSheet: View {
  @ObservedObject var model: ConnectionModel
  @ObservedObject var session: NativeSession
  let request: NativePrompt
  @ObservedObject var trustModel: NativeCertificateTrust
  @ObservedObject var credentials: NativeAuthenticationCredentials
  @AuthenticationFieldState<NativeCredentialRetention> private var retention = .useOnce
  init(model: ConnectionModel, session: NativeSession, request: NativePrompt, retention: NativeCredentialRetention = .useOnce, trustModel: NativeCertificateTrust? = nil) {
    self.model = model; self.session = session; self.request = request; self.credentials = model.credentials; self.trustModel = trustModel ?? model.trust
    _retention = AuthenticationFieldState(wrappedValue: retention)
  }
  @AuthenticationFieldState<String> private var username = ""
  @AuthenticationFieldState<String> private var password = ""
  @AuthenticationFieldState<String?> private var problem: String?
  @AuthenticationFieldState<Bool> private var confirmSave = false
  @FocusState private var passwordFocused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(request.kind == .credentials ? String(localized:"authentication.authentication.required", defaultValue:"Authentication required") : String(localized:"authentication.verify.server.identity", defaultValue:"Verify server identity")).font(.title2.bold())
      Text(request.serverName).font(.headline).textSelection(.enabled).lineLimit(3).help(request.serverName)
      if request.kind == .credentials {
        Text(request.credentialProtectionMessage)
          .foregroundStyle(request.secure ? Color.secondary : Color.nativeWarningText)
          // Sheet sizing may round a line short; wrapped warnings must never truncate.
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("authentication.credentialProtection")
        Text(String(localized:"authentication.this.assessment.describes.credential.protection.not.encryption", defaultValue:"This assessment describes credential protection, not encryption of all desktop traffic."))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if request.usernameRequired { TextField(String(localized:"authentication.username", defaultValue:"Username"), text: $username).textFieldStyle(.roundedBorder) }
        SecureField(String(localized:"authentication.password", defaultValue:"Password"), text: $password).textFieldStyle(.roundedBorder)
          .focused($passwordFocused).accessibilityIdentifier("authentication.password").onSubmit { submit() }
        if !model.isReverse { VStack(alignment:.leading,spacing:6) {
          Text(String(localized:"authentication.password.lifetime", defaultValue:"Password lifetime"))
          Picker(String(localized:"authentication.password.lifetime", defaultValue:"Password lifetime"), selection: $retention) {
          Text(String(localized:"authentication.use.once", defaultValue:"Use once")).tag(NativeCredentialRetention.useOnce)
          Text(String(localized:"authentication.retain.for.this.session.s.reconnect", defaultValue:"Retain for this session’s reconnect")).tag(NativeCredentialRetention.session)
          if credentials.supportsRemembering { Text(String(localized:"authentication.remember.on.this.mac", defaultValue:"Remember on this Mac")).tag(NativeCredentialRetention.remember) }
          }.labelsHidden().frame(maxWidth:.infinity)
            .accessibilityIdentifier("authentication.retention").disabled(credentials.isWorking)
        } }
        if model.isReverse {
          Text(String(localized:"authentication.this.incoming.connection.uses.the.password.once", defaultValue:"This incoming connection uses the password once. Its temporary source port is not a saved server identity."))
            .font(.caption).foregroundStyle(.secondary)
        }
        if retention == .remember {
          Text(String(localized:"authentication.saved.once.the.server.accepts.it.replacing.any.password", defaultValue:"Saved once the server accepts it, replacing any password saved for this server.")).font(.caption).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 8) {
          if credentials.hasSessionCredential {
            Button(String(localized:"authentication.use.session.password", defaultValue:"Use Session Password")) { useSession() }
              .disabled(!credentials.canUseSession(request, username: username))
              .accessibilityIdentifier("authentication.useSession")
          }
          if credentials.supportsRemembering {
            VStack(alignment:.leading,spacing:8) {
              Button(String(localized:"authentication.use.saved.password", defaultValue:"Use Saved Password")) { password = ""; credentials.useSaved(request, username: username, retention: retention) }
                .accessibilityIdentifier("authentication.useSaved")
              Button(String(localized:"authentication.forget.saved.password", defaultValue:"Forget Saved Password"), role: .destructive) { credentials.forgetSaved(request, username: username) }
                .accessibilityIdentifier("authentication.forgetSaved")
            }
          }
        }.disabled(credentials.isWorking)
        if credentials.isWorking { ProgressView(String(localized:"authentication.preparing.credentials", defaultValue:"Preparing credentials…")).controlSize(.small) }
        if let notice = credentials.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
      } else {
        ScrollView {
          TrustDetailsView(request: request, destination: model.authenticationEndpoint, inspection: trustModel.inspection, saved: trustModel.savedInspection, issue: trustModel.issueMessage, isWorking: trustModel.isWorking)
        }.frame(maxHeight: 390)
        if let notice = trustModel.notice { Text(notice).font(.caption).fixedSize(horizontal: false,vertical: true) }
        if trustModel.canSave(request) {
          Text(String(localized:"authentication.a.saved.identity.applies.only.to.this", defaultValue:"A saved identity applies only to this destination’s address, port and route. Verify the fingerprint before saving."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
          let saveTitle = trustModel.replacesSavedKey ? String(localized:"authentication.replace.saved.key.and.connect", defaultValue:"Replace Saved Key and Connect…") : request.kind == .hostKey ? String(localized:"authentication.save.server.key.and.connect", defaultValue:"Save Server Key and Connect…") : String(localized:"authentication.save.exception.and.connect", defaultValue:"Save Exception and Connect…")
          ViewThatFits(in: .horizontal) {
            Button(saveTitle) { confirmSave = true }.fixedSize()
              .accessibilityIdentifier("authentication.saveTrust")
            VStack(alignment: .leading, spacing: 6) {
              Text(saveTitle).fixedSize(horizontal: false, vertical: true)
              Button(String(localized:"authentication.review.decision", defaultValue:"Review Decision…")) { confirmSave = true }
                .accessibilityLabel(saveTitle)
                .accessibilityIdentifier("authentication.saveTrust")
            }
          }
        }
        if trustModel.needsReload {
          Button(String(localized:"authentication.reload.saved.decisions", defaultValue:"Reload Saved Decisions")) { trustModel.reload() }.disabled(trustModel.isWorking)
        }
      }
      if let problem { Text(problem).foregroundStyle(Color.nativeErrorText).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("authentication.error") }
      HStack {
        Spacer()
        Button(String(localized:"action.cancel", defaultValue:"Cancel"), role: .cancel) { password = ""; model.cancel() }.keyboardShortcut(request.kind == .credentials ? .cancelAction : .defaultAction)
          .accessibilityIdentifier("authentication.cancel")
        if request.kind != .credentials {
          // Escape cancels too. onExitCommand alone needs a focused control, which
          // this sheet (no text field) has only with keyboard navigation turned on.
          Button { password = ""; model.cancel() } label: { EmptyView() }.keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0).opacity(0).focusable(false).accessibilityHidden(true)
        }
        if request.kind == .credentials {
          Button(String(localized:"authentication.authenticate", defaultValue:"Authenticate")) { submit() }.disabled(credentials.isWorking).keyboardShortcut(.defaultAction).accessibilityIdentifier("authentication.submit")
        } else {
          Button(String(localized:"authentication.connect.once", defaultValue:"Connect Once")) { trust() }.disabled(trustModel.isWorking || !NativeTrustPresentation(request).mayConnectOnce).accessibilityIdentifier("authentication.trust")
        }
      }
    }.padding(24).frame(width: 440).onAppear { passwordFocused = request.kind == .credentials }
      .onDisappear { password = ""; username = "" }
      .onExitCommand { password = ""; model.cancel() }
      .confirmationDialog(trustModel.replacesSavedKey ? String(localized:"authentication.replace.the.saved.key", defaultValue:"Replace the saved key?") : request.kind == .hostKey ? String(localized:"authentication.save.this.server.key", defaultValue:"Save this server key?") : String(localized:"authentication.save.this.certificate.exception", defaultValue:"Save this certificate exception?"),isPresented: $confirmSave) {
        Button(trustModel.replacesSavedKey ? String(localized:"authentication.replace.and.connect", defaultValue:"Replace and Connect") : String(localized:"authentication.save.and.connect", defaultValue:"Save and Connect")) { trustModel.saveAndConnect(request) }
        Button(String(localized:"action.cancel", defaultValue:"Cancel"),role: .cancel) {}.keyboardShortcut(.defaultAction)
      } message: {
        Text(request.kind == .hostKey ? String(localized:"authentication.confirm.key.scope", defaultValue:"This decision applies to \(model.authenticationEndpoint). It can be forgotten in Saved Server Keys. Verify the fingerprint independently before saving.") : String(localized:"authentication.confirm.certificate.scope", defaultValue:"This decision applies to \(model.authenticationEndpoint). It can be forgotten in Saved Certificate Decisions. The displayed certificate problems are still present."))
      }
  }
  private func submit() {
    var user = Array(username.utf8), secret = Array(password.utf8); password = ""
    do { try credentials.submit(request, username: &user, password: &secret,
      retention: model.isReverse ? .useOnce : retention) }
    catch { problem = NativeConnectionIssue(error: error)?.message ?? String(localized:"authentication.this.authentication.request.is.no.longer.active", defaultValue:"This authentication request is no longer active. Cancel and connect again.") }
  }
  private func useSession() {
    password = ""
    do { try credentials.useSession(request, username: username) }
    catch { problem = String(localized:"authentication.the.session.password.is.no.longer.available", defaultValue:"The session password is no longer available. Enter a password to continue.") }
  }
  private func trust() { do { try trustModel.connectOnce(request) } catch { problem = NativeConnectionIssue(error: error)?.message ?? String(localized:"authentication.this.authentication.request.is.no.longer.active", defaultValue:"This authentication request is no longer active. Cancel and connect again.") } }
}
