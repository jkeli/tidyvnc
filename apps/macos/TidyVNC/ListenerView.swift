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
      Text("Listen for Connections").font(.title2.bold())
      Text("Start a listener, then ask the remote VNC server to connect to this Mac. Each accepted connection opens its own window.")
        .fixedSize(horizontal:false,vertical:true).foregroundStyle(.secondary)
      HStack {
        Text("TCP port")
        TextField("5500",text:$model.port).textFieldStyle(.roundedBorder).frame(width:100)
          .accessibilityIdentifier("listener.port").disabled(!model.canStart)
          .onSubmit { model.start() }
        Toggle("IPv4",isOn:$model.ipv4).disabled(!model.canStart).accessibilityIdentifier("listener.ipv4")
        Toggle("IPv6",isOn:$model.ipv6).disabled(!model.canStart).accessibilityIdentifier("listener.ipv6")
        Spacer()
        if model.canStop {
          Button("Stop Listening") { model.stop() }.accessibilityIdentifier("listener.stop")
        } else {
          Button("Start Listening") { model.start() }.disabled(!model.canStart).accessibilityIdentifier("listener.start")
        }
      }
      Text(status).font(.headline).accessibilityIdentifier("listener.status")
      if !model.addresses.isEmpty {
        ForEach(Array(model.addresses.enumerated()),id:\.offset) { _,address in
          Text("\(address.host.contains(":") ? "IPv6" : "IPv4") port \(String(address.port))")
            .monospacedDigit().textSelection(.enabled)
        }
      }
      if let issue = model.issue { Text(issue).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("listener.error") }
      Divider()
      HStack { Text("Incoming Connections").font(.headline); Spacer(); Text("\(model.incoming.count)").foregroundStyle(.secondary) }
      ScrollView {
        VStack(alignment:.leading,spacing:12) {
          if model.incoming.isEmpty { Text("No incoming connections are waiting.").foregroundStyle(.secondary).padding(.vertical,12) }
          ForEach(model.incoming) { peer in
            HStack {
              VStack(alignment:.leading,spacing:4) {
                Text(peer.address.host).font(.headline).textSelection(.enabled)
                Text("Source port \(String(peer.address.port))").font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if model.reserved.contains(peer.id) { ProgressView("Opening…").controlSize(.small) }
              else {
                Button("Reject") { model.reject(peer) }.disabled(!model.canAccept(peer))
                  .accessibilityIdentifier("listener.reject.\(peer.id)")
                Button("Accept") { model.accept(peer) }.disabled(!model.canAccept(peer))
                  .accessibilityIdentifier("listener.accept.\(peer.id)")
              }
            }.padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }.frame(minHeight:130)
      Text("Waiting connections expire after 30 seconds. Stopping the listener leaves accepted connections open. Incoming connections use connection-only passwords and trust decisions; they are not saved to history.")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
    }.padding(24).frame(minWidth:660,minHeight:472)
  }
  private var status: String {
    switch model.phase {
    case .idle: "Ready to listen"
    case .starting: "Starting listener…"
    case .listening: "Listening for connections"
    case .stopping: "Stopping listener…"
    case .stopped: "Listener stopped"
    case .failed: "Listener could not continue"
    }
  }
}

private struct ListenerPreparationView: View {
  @ObservedObject var model: ListenerModel
  @ObservedObject var preparation: NativeSessionDefaults
  @ObservedObject var displays: NativeDisplayService
  var body: some View {
    ScrollView {
      VStack(alignment:.leading,spacing:16) {
        Text("Listen for Connections").font(.title2.bold())
        Text("IPv4: \(model.ipv4 ? "enabled" : "disabled") · IPv6: \(model.ipv6 ? "enabled" : "disabled")")
        if model.preparationCancelled {
          Text("Listener launch cancelled. Close this window and reopen the file to try again.")
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
          Button("Reload Connection File") { preparation.load() }.disabled(model.closing)
        } else if preparation.error != nil {
          Text("Saved defaults could not be loaded. Retry, or review the file using built-in defaults.")
          Button("Retry Defaults") { preparation.load() }.disabled(model.closing)
          Button("Use Built-in Defaults") { preparation.useBuiltInDefaults() }.disabled(model.closing)
        } else { ProgressView("Loading listener settings…") }
      }.frame(maxWidth:.infinity,alignment:.leading).padding(24)
    }.frame(minWidth:660,minHeight:472)
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
    window.title = "Listen for Connections"; window.isReleasedWhenClosed = false
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
