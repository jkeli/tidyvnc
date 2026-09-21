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
  @AuthenticationFieldState<Bool> private var replaceRemembered = false
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
      Text(request.kind == .credentials ? "Authentication required" : "Verify server identity").font(.title2.bold())
      Text(request.serverName).font(.headline).textSelection(.enabled).lineLimit(3).help(request.serverName)
      if request.kind == .credentials {
        Text(request.credentialProtectionMessage)
          .foregroundStyle(request.secure ? Color.secondary : Color.orange)
          .accessibilityIdentifier("authentication.credentialProtection")
        Text("This assessment describes credential protection, not encryption of all desktop traffic.")
          .font(.caption).foregroundStyle(.secondary)
        if request.usernameRequired { TextField("Username", text: $username).textFieldStyle(.roundedBorder) }
        SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
          .focused($passwordFocused).accessibilityIdentifier("authentication.password").onSubmit { submit() }
        if !model.isReverse { Picker("Password lifetime", selection: $retention) {
          Text("Use once").tag(NativeCredentialRetention.useOnce)
          Text("Retain for this session’s reconnect").tag(NativeCredentialRetention.session)
          if credentials.supportsRemembering { Text("Remember on this Mac").tag(NativeCredentialRetention.remember) }
        }.accessibilityIdentifier("authentication.retention").disabled(credentials.isWorking) }
        if model.isReverse {
          Text("This incoming connection uses the password once. Its temporary source port is not a saved server identity.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if retention == .remember {
          Toggle("Replace an existing saved password", isOn: $replaceRemembered)
          Text("Save only after successful authentication. Replacement must be explicitly selected.").font(.caption).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 8) {
          if credentials.hasSessionCredential {
            Button("Use Session Password") { useSession() }
              .disabled(!credentials.canUseSession(request, username: username))
              .accessibilityIdentifier("authentication.useSession")
          }
          if credentials.supportsRemembering {
            HStack {
              Button("Use Saved Password") { password = ""; credentials.useSaved(request, username: username, retention: retention) }
                .accessibilityIdentifier("authentication.useSaved")
              Button("Forget Saved Password", role: .destructive) { credentials.forgetSaved(request, username: username) }
                .accessibilityIdentifier("authentication.forgetSaved")
            }
          }
        }.disabled(credentials.isWorking)
        if credentials.isWorking { ProgressView("Preparing credentials…").controlSize(.small) }
        if let notice = credentials.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
      } else {
        ScrollView {
          TrustDetailsView(request: request, destination: model.authenticationEndpoint, inspection: trustModel.inspection, saved: trustModel.savedInspection, issue: trustModel.issueMessage, isWorking: trustModel.isWorking)
        }.frame(maxHeight: 390)
        if let notice = trustModel.notice { Text(notice).font(.caption).fixedSize(horizontal: false,vertical: true) }
        if trustModel.canSave(request) {
          Text("A saved identity applies only to this destination’s address, port and route. Verify the fingerprint before saving.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false,vertical: true)
          Button(trustModel.replacesSavedKey ? "Replace Saved Key and Connect…" : request.kind == .hostKey ? "Save Server Key and Connect…" : "Save Exception and Connect…") { confirmSave = true }
            .accessibilityIdentifier("authentication.saveTrust")
        }
        if trustModel.needsReload {
          Button("Reload Saved Decisions") { trustModel.reload() }.disabled(trustModel.isWorking)
        }
      }
      if let problem { Text(problem).foregroundStyle(.red).accessibilityIdentifier("authentication.error") }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { password = ""; model.cancel() }.keyboardShortcut(request.kind == .credentials ? .cancelAction : .defaultAction)
          .accessibilityIdentifier("authentication.cancel")
        if request.kind == .credentials {
          Button("Authenticate") { submit() }.disabled(credentials.isWorking).keyboardShortcut(.defaultAction).accessibilityIdentifier("authentication.submit")
        } else {
          Button("Connect Once") { trust() }.disabled(trustModel.isWorking || !NativeTrustPresentation(request).mayConnectOnce).accessibilityIdentifier("authentication.trust")
        }
      }
    }.padding(24).frame(width: 440).onAppear { passwordFocused = request.kind == .credentials }
      .onDisappear { password = ""; username = "" }
      .onExitCommand { password = ""; model.cancel() }
      .confirmationDialog(trustModel.replacesSavedKey ? "Replace the saved key?" : request.kind == .hostKey ? "Save this server key?" : "Save this certificate exception?",isPresented: $confirmSave) {
        Button(trustModel.replacesSavedKey ? "Replace and Connect" : "Save and Connect") { trustModel.saveAndConnect(request) }
        Button("Cancel",role: .cancel) {}.keyboardShortcut(.defaultAction)
      } message: {
        Text("This decision applies to " + model.authenticationEndpoint + (request.kind == .hostKey ? ". It can be forgotten in Saved Server Keys. Verify the fingerprint independently before saving." : ". It can be forgotten in Saved Certificate Decisions. The displayed certificate problems are still present."))
      }
  }
  private func submit() {
    var user = Array(username.utf8), secret = Array(password.utf8); password = ""
    do { try credentials.submit(request, username: &user, password: &secret,
      retention: model.isReverse ? .useOnce : retention == .remember && replaceRemembered ? .replaceRemembered : retention) }
    catch { problem = NativeConnectionIssue(error: error)?.message ?? "This authentication request is no longer active. Cancel and connect again." }
  }
  private func useSession() {
    password = ""
    do { try credentials.useSession(request, username: username) }
    catch { problem = "The session password is no longer available. Enter a password to continue." }
  }
  private func trust() { do { try trustModel.connectOnce(request) } catch { problem = NativeConnectionIssue(error: error)?.message ?? "This authentication request is no longer active. Cancel and connect again." } }
}
