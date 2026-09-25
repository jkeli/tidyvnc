// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
import TidyVNCNative

struct ConnectionContent: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var model: ConnectionModel
  @ObservedObject var session: NativeSession
  let displays: NativeDisplayService
  let importAvailability: DefaultsImportAvailability?
  let openImport: () -> Void
  let openHistoryImport: () -> Void
  var body: some View {
    let visibleSheet = presentedSheet
    let problem = model.connectionProblem
    VStack(spacing: 0) {
      if showsConnectionSetup {
        if !model.isReverse, session.snapshot.state == .idle, model.defaults?.profile == nil, model.defaults?.documentRequest == nil,
           !model.busy {
          if let importAvailability { FirstUseDefaultsImportOffer(availability:importAvailability,open:openImport) }
          if let history = model.history { FirstUseHistoryImportOffer(history:history,open:openHistoryImport) }
        }
        HStack(spacing: 12) {
          Image(systemName: "display").foregroundStyle(.secondary).accessibilityHidden(true)
          TextField(String(localized:"profiles.server.address", defaultValue:"Server address"), text: $model.endpoint).textFieldStyle(.roundedBorder)
            .help(model.isReverse ? String(localized:"app.source.address.of.this.incoming.connection.it.is.not.an.outbound.destination", defaultValue:"Source address of this incoming connection; it is not an outbound destination.") : String(localized:"profiles.enter.host.display.host.port.ipv6.display.or.a.unix.socket.path", defaultValue:"Enter host:display, host::port, [IPv6]:display, or a Unix socket path."))
            .accessibilityIdentifier("connection.endpoint").disabled(!model.canEditDestination)
            .onSubmit { model.connect() }
          if model.busy {
            ProgressView().controlSize(.small)
            Button(String(localized:"action.cancel", defaultValue:"Cancel")) { model.cancel() }.accessibilityIdentifier("connection.cancel")
          } else if !model.isReverse {
            Button(String(localized:"document.connect", defaultValue:"Connect")) { model.connect() }.disabled(!model.canConnect).keyboardShortcut(.defaultAction)
              .accessibilityIdentifier("connection.connect")
          }
        }.padding(.horizontal,14).padding(.top,14).padding(.bottom,8)
        EndpointIssueView(issue: model.endpointIssue).padding(.horizontal, 14)
        if !model.isReverse {
          VStack(alignment:.leading,spacing:4) {
            TextField(String(localized:"profiles.ssh.gateway.optional", defaultValue:"SSH gateway (optional)"),text:$model.sshGatewayText).textFieldStyle(.roundedBorder)
              .disabled(!model.canEditDestination).accessibilityIdentifier("connection.sshGateway")
              .help(String(localized:"profiles.enter.user.host.or.ssh.user.host.port.leave.empty.for.a", defaultValue:"Enter user@host or ssh://user@host:port. Leave empty for a direct connection."))
            if let issue = model.gatewayIssue { Text(issue).foregroundStyle(Color.nativeErrorText).font(.caption) }
            if !model.sshGatewayText.isEmpty {
              Text(String(localized:"profiles.ssh.reads.supported.settings.from.ssh.config.commands.and.proxy.hops.are", defaultValue:"SSH reads supported settings from ~/.ssh/config. Commands and proxy hops are unavailable. Passwords are used once; new Ed25519/RSA/ECDSA gateway keys require approval. Changed keys are rejected."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
          }.padding(.horizontal,14).padding(.bottom,8)
        }
        if model.isReverse {
          Text(String(localized:"app.incoming.connection.to.reconnect.ask.the.server.to.connect.to.the.listener", defaultValue:"Incoming connection. To reconnect, ask the server to connect to the listener again. Passwords, trust decisions and this temporary address are not saved."))
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal,14).padding(.bottom,8)
            .accessibilityIdentifier("connection.reverse")
        }
        if let history = model.history { RecentHistoryStatus(model: history).padding(.horizontal, 14) }
        if let profile = model.defaults?.profile {
          Text(String(localized:"app.profile.source", defaultValue:"Settings from profile: \(profile.name)")).font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
        }
      }
      if let notice = model.credentials.notice {
        HStack {
          Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true)
          Spacer()
          Button(String(localized:"document.dismiss", defaultValue:"Dismiss")) { model.credentials.dismissNotice() }
        }.padding(.horizontal, 14).padding(.vertical, 8).accessibilityIdentifier("credentials.notice")
      }
      Divider()
      ZStack {
        NativeDesktop(session: session, displays: displays, scaling: model.scaling, input: model.input, commands: model.desktopCommands, fullscreen: model.fullscreen, onContextMenu: { view in
          let popup = DesktopContextMenu(model: model)
          withExtendedLifetime(popup) { popup.show(in: view) }
        }) { model.message = $0 }
        if !session.hasFrame {
          ViewThatFits(in: .vertical) {
            ContentUnavailableView(placeholderTitle, systemImage: "display", description: Text(placeholderDescription))
            VStack(spacing: 4) {
              Text(placeholderTitle).font(.headline)
              if !placeholderDescription.isEmpty { Text(placeholderDescription).font(.caption) }
            }.fixedSize(horizontal: false, vertical: true).padding(12)
          }.foregroundStyle(.white).allowsHitTesting(false)
        }
      }.overlay(alignment: .topTrailing) {
        if model.showsStatistics, let information = session.information {
          ConnectionStatisticsOverlay(information: information).padding(12)
        }
      }.clipped()
      if model.showsStatusBar {
        Divider()
        HStack {
          Text(status).accessibilityIdentifier("connection.status")
          Spacer()
          if let message = model.fullscreen.message {
            Text(message).foregroundStyle(Color.nativeWarningText).lineLimit(1).help(message).accessibilityIdentifier("fullscreen.status")
          }
          if let message = model.desktopCommands.windowMessage {
            Text(message).foregroundStyle(Color.nativeWarningText).lineLimit(1).help(message).accessibilityIdentifier("window.commandStatus")
          }
          if model.desktopCommands.keyboardCaptured {
            Text(String(localized:"app.keyboard.captured", defaultValue:"Keyboard captured")).accessibilityIdentifier("keyboard.captured")
          } else if let message = model.desktopCommands.captureMessage {
            Text(message).foregroundStyle(Color.nativeWarningText).lineLimit(1).help(message).accessibilityIdentifier("keyboard.captureStatus")
          }
          if let message = session.remoteResize.message {
            Text(message).foregroundStyle(Color.nativeWarningText).lineLimit(1).help(message).accessibilityIdentifier("remoteResize.status")
          }
          if let message = model.clipboardMessage {
            Text(message).foregroundStyle(Color.nativeWarningText).lineLimit(1).help(message).accessibilityIdentifier("clipboard.status")
          }
          if session.snapshot.width > 0 { Text(String(localized:"information.desktop.size", defaultValue:"\((session.snapshot.width).formatted()) × \((session.snapshot.height).formatted())")).monospacedDigit() }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
      }
    }
    .toolbar { connectionToolbar }
    .sheet(item: Binding(get: { visibleSheet }, set: { value in
      // Dismiss only the editor that created this binding. A delayed dismissal
      // must not cancel a newer editor or an authentication prompt.
      guard value == nil, session.prompt == nil else { return }
      switch visibleSheet {
      case .fullscreen(let draft) where model.fullscreenDraft === draft: model.closeFullscreen()
      case .resizePolicy(let draft) where model.resizePolicyDraft === draft: model.closeResizePolicy()
      case .remoteResize(let draft) where model.remoteResizeDraft === draft: model.closeRemoteResize()
      case .connectionOptions(let draft) where model.connectionOptionsDraft === draft: model.closeConnectionOptions()
      case .security(let draft) where model.securityDraft === draft: model.closeSecurity()
      case .encoding(let draft) where model.encodingDraft === draft: model.closeEncoding()
      case .information(let id) where model.informationID == id: model.closeInformation()
      case .input(let draft) where model.inputDraft === draft: model.closeInput()
      case .scaling(let draft) where model.scalingDraft === draft: model.closeScaling()
      default: break
      }
    })) { sheet in
      switch sheet {
      case .ssh(let request):
        SSHAuthenticationSheet(interaction:model.sshInteraction,request:request,cancel:model.cancel).interactiveDismissDisabled()
      case .authentication(let request):
        AuthenticationSheet(model: model, session: session, request: request).interactiveDismissDisabled()
      case .information:
        ConnectionInformationSheet(endpoint: model.endpoint, session: session, copy: model.copyToPasteboard, dismiss: model.closeInformation)
      case .input(let draft):
        InputSettingsSheet(model: draft, dismiss: model.closeInput)
      case .scaling(let draft):
        ScalingSettingsSheet(model: draft, dismiss: model.closeScaling)
      case .fullscreen(let draft):
        FullscreenSettingsSheet(model:draft,dismiss:model.closeFullscreen)
      case .resizePolicy(let draft):
        RemoteResizePolicySheet(model:draft,dismiss:model.closeResizePolicy)
      case .remoteResize(let draft):
        RemoteResizeSheet(model:draft,dismiss:model.closeRemoteResize)
      case .connectionOptions(let draft):
        SessionConnectionSheet(model:draft,dismiss:model.closeConnectionOptions)
      case .security(let draft):
        SessionSecuritySheet(model:draft,dismiss:model.closeSecurity)
      case .encoding(let draft):
        SessionEncodingSheet(model: draft, dismiss: model.closeEncoding)
      }
    }
    .alert(problem?.issue.title ?? String(localized:"app.connection.problem", defaultValue:"Connection Problem"), isPresented: Binding(
      get: { !model.documentSave.hasPending && model.fullscreen.phase == .windowed && (problem != nil || model.message != nil) },
      set: { visible in
        if !visible {
          if let problem { model.hideConnectionProblem(problem.id) }
          else { model.message = nil }
        }
      })) {
      if let problem {
        if model.offersRetryConnection(problem) {
          Button(String(localized:"app.retry", defaultValue:"Retry")) { model.retryConnection(problem) }
            .disabled(!model.canRetryConnection(problem))
            .accessibilityIdentifier("connection.retry")
        }
        Button(String(localized:"action.cancel", defaultValue:"Cancel"), role: .cancel) { model.dismissConnectionProblem(problem.id) }
          .keyboardShortcut(.defaultAction)
      } else {
        Button(String(localized:"app.ok", defaultValue:"OK"), role: .cancel) { model.message = nil }.keyboardShortcut(.defaultAction)
      }
    } message: {
      Text(problem?.issue.message ?? model.message ?? "")
    }
  }
  private var showsConnectionSetup: Bool {
    ![.connected, .disconnecting].contains(session.snapshot.state)
  }
  @ToolbarContentBuilder private var connectionToolbar: some ToolbarContent {
    ToolbarItemGroup {
      if showsConnectionSetup, let history = model.history {
        RecentConnectionsButton(model: history, canSelect:model.canEditDestination) { model.selectDestination($0) }
      }
      if showsConnectionSetup, !model.isReverse { Button { openWindow(id: "profiles") } label: { Image(systemName: "folder") }
        .help(String(localized:"app.saved.profiles.title", defaultValue:"Saved profiles")).accessibilityLabel(String(localized:"app.saved.profiles.title", defaultValue:"Saved profiles")).accessibilityIdentifier("connection.profiles")
      }
      Menu {
        Toggle(String(localized:"settings.defaults.send.clipboard.to.server", defaultValue:"Send clipboard to server"), isOn: Binding(get: { session.clipboardSendEnabled }, set: { setClipboard(send: $0) }))
          .accessibilityIdentifier("clipboard.send")
        Toggle(String(localized:"settings.defaults.receive.clipboard.from.server", defaultValue:"Receive clipboard from server"), isOn: Binding(get: { session.clipboardReceiveEnabled }, set: { setClipboard(receive: $0) }))
          .accessibilityIdentifier("clipboard.receive")
        if let defaults = model.defaults {
          Divider()
          Text(String(localized:"app.clipboard.send.source", defaultValue:"Send: \(source(defaults.overrides.clipboardSend, defaults.profile?.settings.clipboardSend, defaults.inherited.clipboardSend, document:defaults.documentResolution?.fieldLines["SendClipboard"] != nil))"))
          Text(String(localized:"app.clipboard.receive.source", defaultValue:"Receive: \(source(defaults.overrides.clipboardReceive, defaults.profile?.settings.clipboardReceive, defaults.inherited.clipboardReceive, document:defaults.documentResolution?.fieldLines["AcceptClipboard"] != nil))"))
        }
      } label: { Image(systemName: "doc.on.clipboard") }
        .fixedSize().help(String(localized:"app.clipboard.sharing.for.this.connection", defaultValue:"Clipboard sharing for this connection")).accessibilityLabel(String(localized:"import.defaults.clipboard.sharing", defaultValue:"Clipboard sharing"))
        .accessibilityIdentifier("clipboard.options")
        .disabled(model.defaults?.isReady != true)
      Menu { DesktopActions(model: model) } label: { Image(systemName: "ellipsis.circle") }
        .fixedSize().help(String(localized:"app.connection.actions", defaultValue:"Connection actions")).accessibilityLabel(String(localized:"app.connection.actions", defaultValue:"Connection actions"))
        .accessibilityIdentifier("connection.actions")
      Button { model.openInput() } label: { Image(systemName: "keyboard") }
        .disabled(!model.canOpenInput).help(String(localized:"app.input.settings.for.this.connection", defaultValue:"Input settings for this connection"))
        .accessibilityLabel(String(localized:"app.input.settings", defaultValue:"Input settings")).accessibilityIdentifier("connection.input")
      Button { model.openScaling() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
        .disabled(!model.canOpenScaling).help(String(localized:"app.scaling.settings.for.this.connection", defaultValue:"Scaling settings for this connection"))
        .accessibilityLabel(String(localized:"app.scaling.settings", defaultValue:"Scaling settings")).accessibilityIdentifier("connection.scaling")
      Button { model.openEncoding() } label: { Image(systemName: "slider.horizontal.3") }
        .disabled(!model.canOpenEncoding).help(String(localized:"app.encoding.settings.for.this.connection", defaultValue:"Encoding settings for this connection"))
        .accessibilityLabel(String(localized:"app.encoding.settings", defaultValue:"Encoding settings")).accessibilityIdentifier("connection.encoding")
    }
    ToolbarItem(id: "connection.disconnect", placement: .primaryAction) {
      if !showsConnectionSetup {
        Button { model.disconnect() } label: {
          Label(String(localized:"app.disconnect", defaultValue:"Disconnect"), systemImage: "stop.circle")
        }
        .labelStyle(.iconOnly)
        .help(String(localized:"app.disconnect", defaultValue:"Disconnect"))
        .accessibilityIdentifier("connection.disconnect")
        .disabled(model.busy || model.closing || session.snapshot.state != .connected)
      }
    }
  }
  private enum Sheet: Identifiable {
    case ssh(NativeSSHQuestion)
    case fullscreen(NativeFullscreenDraft)
    case resizePolicy(NativeRemoteResizePolicyDraft)
    case remoteResize(NativeRemoteResizeDraft)
    case security(NativeSessionSecurityDraft), connectionOptions(NativeConnectionDraft)
    case authentication(NativePrompt), encoding(NativeSessionEncodingDraft), scaling(NativeScalingDraft), input(NativeInputDraft), information(UUID)
    var id: String {
      switch self {
      case .ssh(let request): return "ssh-\(request.id)"
      case .authentication(let request): return "authentication-\(request.generation)-\(request.id)"
      case .information(let id): return "information-\(id)"
      case .input(let draft): return "input-\(draft.id)"
      case .scaling(let draft): return "scaling-\(draft.id)"
      case .fullscreen(let draft): return "fullscreen-\(draft.id)"
      case .resizePolicy(let draft): return "resize-policy-\(draft.id)"
      case .remoteResize(let draft): return "remote-resize-\(draft.id)"
      case .connectionOptions(let draft): return "connection-options-\(draft.id)"
      case .security(let draft): return "security-\(draft.id)"
      case .encoding(let draft): return "encoding-\(draft.id)"
      }
    }
  }
  private var presentedSheet: Sheet? {
    if let question = model.sshInteraction.question { return .ssh(question) }
    if let prompt = session.prompt { return .authentication(prompt) }
    if let id = model.informationID { return .information(id) }
    if let draft = model.inputDraft { return .input(draft) }
    if let draft = model.fullscreenDraft { return .fullscreen(draft) }
    if let draft = model.resizePolicyDraft { return .resizePolicy(draft) }
    if let draft = model.remoteResizeDraft { return .remoteResize(draft) }
    if let draft = model.scalingDraft { return .scaling(draft) }
    if let draft = model.connectionOptionsDraft { return .connectionOptions(draft) }
    if let draft = model.securityDraft { return .security(draft) }
    if let draft = model.encodingDraft { return .encoding(draft) }
    return nil
  }
  private func setClipboard(send: Bool? = nil, receive: Bool? = nil) {
    do { try model.defaults?.setClipboard(send: send, receive: receive); model.clipboardMessage = nil }
    catch { model.clipboardMessage = String(localized:"app.clipboard.settings.could.not.be.changed.try.again", defaultValue:"Clipboard settings could not be changed. Try again.") }
  }
  private func source(_ override: Bool?, _ profile: Bool?, _ inherited: Bool?, document: Bool) -> String {
    override != nil ? String(localized:"settings.encoding.connection.override", defaultValue:"Connection override") : document ? String(localized:"settings.encoding.connection.file", defaultValue:"Connection file") : profile != nil ? String(localized:"settings.encoding.profile", defaultValue:"Profile") : inherited != nil ? String(localized:"settings.encoding.app.default", defaultValue:"App default") : String(localized:"settings.defaults.built.in.default", defaultValue:"Built-in default")
  }
  private var placeholderTitle: String {
    session.snapshot.state == .idle ? String(localized:"help.guide.connect.title", defaultValue:"Connect to a desktop") : status
  }
  private var placeholderDescription: String {
    session.snapshot.state == .idle ? String(localized:"app.enter.a.vnc.server.address.to.begin", defaultValue:"Enter a VNC server address to begin.") : ""
  }
  private var status: String {
    switch session.snapshot.state {
    case .idle: return String(localized:"app.ready", defaultValue:"Ready")
    case .resolving: return String(localized:"app.resolving.server", defaultValue:"Resolving server…")
    case .connecting, .negotiating: return String(localized:"app.connecting", defaultValue:"Connecting…")
    case .authenticating: return String(localized:"app.waiting.for.authentication", defaultValue:"Waiting for authentication")
    case .connected: return String(localized:"app.connected", defaultValue:"Connected")
    case .disconnecting: return String(localized:"app.disconnecting", defaultValue:"Disconnecting…")
    case .closed: return String(localized:"app.disconnected", defaultValue:"Disconnected")
    case .failed: return String(localized:"app.connection.failed", defaultValue:"Connection failed")
    }
  }
}

