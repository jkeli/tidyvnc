// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
import TidyVNCNative

struct ListenerView: View {
  @ObservedObject var model: ListenerModel
  var body: some View {
    Group {
      if let preparation = model.preparation, !preparation.isReady, let displays = model.displays {
        ListenerPreparationView(model:model,preparation:preparation,displays:displays)
      } else { listener }
    }.background(Color(nsColor:.windowBackgroundColor))
  }
  private var listener: some View {
    VStack(alignment:.leading,spacing:18) {
      Text(String(localized:"listener.listen.for.connections", defaultValue:"Listen for Connections")).font(.title2.bold())
      ViewThatFits(in:.horizontal) {
        HStack { networkControls; Spacer(); listenAction }
        VStack(alignment:.leading,spacing:12) { networkControls; listenAction }
      }
      ScrollView {
        VStack(alignment:.leading,spacing:18) {
          Text(String(localized:"listener.start.a.listener.then.ask.the.remote.vnc.server.to.connect.to", defaultValue:"Start a listener, then ask the remote VNC server to connect to this Mac. Each accepted connection opens its own window."))
            .fixedSize(horizontal:false,vertical:true).foregroundStyle(.secondary)
          Text(status).font(.headline).accessibilityIdentifier("listener.status")
          if !model.addresses.isEmpty {
            ForEach(Array(model.addresses.enumerated()),id:\.offset) { _,address in
              Text(String(localized:"listener.address.port", defaultValue:"\(address.host.contains(":") ? "IPv6" : "IPv4") port \(String(address.port))"))
                .monospacedDigit().textSelection(.enabled)
            }
          }
          if let issue = model.issue { Text(issue).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("listener.error") }
          Divider()
          HStack { Text(String(localized:"listener.incoming.connections", defaultValue:"Incoming Connections")).font(.headline); Spacer(); Text(model.incoming.count.formatted()).foregroundStyle(.secondary) }
          VStack(alignment:.leading,spacing:12) {
            if model.incoming.isEmpty { Text(String(localized:"listener.no.incoming.connections.are.waiting", defaultValue:"No incoming connections are waiting.")).foregroundStyle(.secondary).padding(.vertical,12) }
            ForEach(model.incoming) { peer in
              VStack(alignment:.leading,spacing:12) {
                VStack(alignment:.leading,spacing:4) {
                  Text(peer.address.host).font(.headline).textSelection(.enabled)
                  Text(String(localized:"listener.source.port", defaultValue:"Source port \(String(peer.address.port))")).font(.caption).foregroundStyle(.secondary)
                }
                if model.reserved.contains(peer.id) { ProgressView(String(localized:"listener.opening", defaultValue:"Opening…")).controlSize(.small) }
                else {
                  HStack {
                    Button(String(localized:"listener.reject", defaultValue:"Reject")) { model.reject(peer) }.disabled(!model.canAccept(peer))
                      .accessibilityIdentifier("listener.reject.\(peer.id)")
                    Button(String(localized:"listener.accept", defaultValue:"Accept")) { model.accept(peer) }.disabled(!model.canAccept(peer))
                      .accessibilityIdentifier("listener.accept.\(peer.id)")
                  }
                }
              }.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            }
          }.frame(maxWidth:.infinity,alignment:.leading)
          Text(String(localized:"listener.waiting.connections.expire.after.30.seconds.stopping.the.listener.leaves.accepted.connections", defaultValue:"Waiting connections expire after 30 seconds. Stopping the listener leaves accepted connections open. Incoming connections use connection-only passwords and trust decisions; they are not saved to history."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.frame(maxWidth:.infinity,alignment:.leading)
      }
    }.padding(24).frame(minWidth:660,minHeight:472)
  }
  private var networkControls: some View {
    HStack {
      Text(String(localized:"listener.tcp.port", defaultValue:"TCP port"))
      TextField(text:$model.port,prompt:Text(verbatim:"5500")) { Text(String(localized:"listener.tcp.port", defaultValue:"TCP port")) }
        .labelsHidden().textFieldStyle(.roundedBorder).frame(width:100)
        .accessibilityIdentifier("listener.port").disabled(!model.canStart)
        .accessibilityLabel(String(localized:"listener.tcp.port", defaultValue:"TCP port"))
        .onSubmit { model.start() }
      Toggle(isOn:$model.ipv4) { Text(verbatim:"IPv4") }.disabled(!model.canStart).accessibilityIdentifier("listener.ipv4")
      Toggle(isOn:$model.ipv6) { Text(verbatim:"IPv6") }.disabled(!model.canStart).accessibilityIdentifier("listener.ipv6")
    }
  }
  @ViewBuilder private var listenAction: some View {
    if model.canStop {
      Button(String(localized:"listener.stop.listening", defaultValue:"Stop Listening")) { model.stop() }.accessibilityIdentifier("listener.stop")
    } else {
      Button(String(localized:"listener.start.listening", defaultValue:"Start Listening")) { model.start() }.disabled(!model.canStart).accessibilityIdentifier("listener.start")
    }
  }
  private var status: String {
    switch model.phase {
    case .idle: String(localized:"listener.ready.to.listen", defaultValue:"Ready to listen")
    case .starting: String(localized:"listener.starting.listener", defaultValue:"Starting listener…")
    case .listening: String(localized:"listener.listening.for.connections", defaultValue:"Listening for connections")
    case .stopping: String(localized:"listener.stopping.listener", defaultValue:"Stopping listener…")
    case .stopped: String(localized:"listener.listener.stopped", defaultValue:"Listener stopped")
    case .failed: String(localized:"listener.listener.could.not.continue", defaultValue:"Listener could not continue")
    }
  }
}

private struct ListenerPreparationView: View {
  @ObservedObject var model: ListenerModel
  @ObservedObject var preparation: NativeSessionDefaults
  @ObservedObject var displays: NativeDisplayService
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text(String(localized:"listener.listen.for.connections", defaultValue:"Listen for Connections")).font(.title2.bold())
      Text(String(localized:"listener.families", defaultValue:"IPv4: \(model.ipv4 ? String(localized:"listener.family.enabled", defaultValue:"enabled") : String(localized:"listener.family.disabled", defaultValue:"disabled")) · IPv6: \(model.ipv6 ? String(localized:"listener.family.enabled", defaultValue:"enabled") : String(localized:"listener.family.disabled", defaultValue:"disabled"))"))
      if model.preparationCancelled {
        Text(String(localized:"listener.listener.launch.cancelled.close.this.window.and.reopen.the.file.to.try", defaultValue:"Listener launch cancelled. Close this window and reopen the file to try again."))
      } else if let mapping = preparation.documentMapping {
        DocumentMonitorMappingView(mapping:mapping,displays:displays,issue:preparation.documentIssue,
          resolve:{ preparation.resolveDocumentMapping(mapping.id,assignments:$0) },
          cancel:{ model.cancelDocument(mapping.id,mapping:true) }).id(mapping.id)
      } else if let review = preparation.documentReview {
        DocumentReviewView(review:review,displays:displays,
          editMapping:{ preparation.editDocumentMapping(review.id) },
          accept:{ model.acceptDocument(review.id) },cancel:{ model.cancelDocument(review.id) },listening:true)
      } else if let issue = preparation.documentIssue ?? preparation.invocationIssue {
        Text(issue).foregroundStyle(.red).accessibilityIdentifier("listener.document.error")
        Button(String(localized:"listener.reload.connection.file", defaultValue:"Reload Connection File")) { preparation.load() }.disabled(model.closing)
      } else if preparation.error != nil {
        Text(String(localized:"listener.saved.defaults.could.not.be.loaded.retry.or.review.the.file.using", defaultValue:"Saved defaults could not be loaded. Retry, or review the file using built-in defaults."))
        Button(String(localized:"listener.retry.defaults", defaultValue:"Retry Defaults")) { preparation.load() }.disabled(model.closing)
        Button(String(localized:"settings.inheritance.use.builtin.defaults", defaultValue:"Use Built-in Defaults")) { preparation.useBuiltInDefaults() }.disabled(model.closing)
      } else { ProgressView(String(localized:"listener.loading.listener.settings", defaultValue:"Loading listener settings…")) }
    }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).padding(24)
      .frame(minWidth:660,minHeight:472)
  }
}

@MainActor final class ListenerWindowController: NSWindowController, NSWindowDelegate {
  let model: ListenerModel
  private var cleanup: Task<Void,Never>?
  private(set) var isClosing = false
  private var hosting: NSHostingController<ListenerView>?
  private let onClosed: @MainActor (ListenerWindowController) -> Void
  private let onActivate: @MainActor () -> Void
  init(model: ListenerModel,onActivate: @escaping @MainActor () -> Void = {},onClosed: @escaping @MainActor (ListenerWindowController) -> Void) {
    self.model = model; self.onClosed = onClosed; self.onActivate = onActivate
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:560),
      styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    window.title = String(localized:"listener.listen.for.connections", defaultValue:"Listen for Connections"); window.isReleasedWhenClosed = false
    super.init(window:window); window.delegate = self
    let content = NSHostingController(rootView:ListenerView(model:model)); content.sizingOptions = [.minSize]
    hosting = content; window.contentViewController = content
    window.setContentSize(NSSize(width:700,height:560)); window.center()
  }
  required init?(coder:NSCoder) { nil }
  func contentSizeThatFits(_ size: NSSize) -> NSSize? { hosting?.sizeThatFits(in:size) }
  override func showWindow(_ sender:Any?) {
    guard !isClosing else { return }; super.showWindow(sender); window?.makeKeyAndOrderFront(sender)
  }
  func windowWillClose(_ notification:Notification) { beginClose() }
  func windowDidBecomeKey(_ notification:Notification) { onActivate() }
  private func beginClose() {
    guard !isClosing else { return }; isClosing = true; model.requestClose()
    cleanup = Task { @MainActor in
      await model.close(); window?.contentViewController = nil; hosting = nil; onClosed(self)
    }
  }
  func shutdown() async { close(); beginClose(); await cleanup?.value }
}
