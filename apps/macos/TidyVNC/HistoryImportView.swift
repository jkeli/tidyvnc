// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine
import SwiftUI
import TidyVNCNative

struct FirstUseHistoryImportOffer: View {
  @ObservedObject var history: NativeRecentHistory
  let open: () -> Void
  var body: some View {
    if history.canImportHistory && !history.importOfferDismissed {
      HStack(spacing:12) {
        Text("Have a recent-server list? Review a separate history import.")
          .font(.callout).fixedSize(horizontal:false,vertical:true)
        Spacer()
        Button("Review History…",action:open).accessibilityIdentifier("historyImport.firstUse")
        Button("Not Now") { history.dismissImportOffer() }.accessibilityIdentifier("historyImport.notNow")
      }.padding(14).background(.quaternary)
    }
  }
}

struct HistoryImportView: View {
  @ObservedObject var state: NativeHistoryImportState
  let close: @MainActor () -> Void
  @MainActor private final class ReviewChoices: ObservableObject {
    @Published var acknowledged = false
  }
  @StateObject private var choices = ReviewChoices()
  private func begin(_ origin: NativeImportOrigin) {
    choices.acknowledged = false
    state.begin(origin:origin)
  }
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text(state.review == nil ? "Import Recent Connections" : "Review History Import")
        .font(.title2).accessibilityIdentifier("historyImport.title")
      if let review = state.review {
        reviewContent(review)
      } else if state.isLoading || state.isWriting || state.hasPending {
        ProgressView(state.isWriting ? "Saving imported history…" : "Reading history…")
        Spacer()
        if !state.isWriting, let id = state.requestID {
          Button("Cancel") { state.cancel(id) }.keyboardShortcut(.cancelAction)
        }
      } else if let imported = state.imported {
        Label("History imported",systemImage:"checkmark.circle").font(.headline)
          .accessibilityIdentifier("historyImport.success")
        Text("\(imported.recentEndpoints.count) server addresses are available in Recent Connections. Select an address when you want to connect.")
        Text("Your saved profiles and the original history file were left unchanged.").foregroundStyle(.secondary)
        Spacer()
        Button("Done",action:close).keyboardShortcut(.defaultAction)
      } else {
        Text("Copy recent server addresses into this app. This is separate from importing connection defaults and does not start a connection.")
        Text("Native history takes precedence, including history you previously cleared. Existing saved profiles are preserved.").foregroundStyle(.secondary)
        Text("Choose a source to review:").font(.headline)
        Button("Review Current TidyVNC History") { begin(.currentXDG) }
          .keyboardShortcut(.defaultAction).accessibilityIdentifier("historyImport.current")
        Text("Reads the existing TidyVNC history location, including an absolute XDG state override.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Review Legacy History") { begin(.legacy) }.accessibilityIdentifier("historyImport.legacy")
        Text("An explicit, separate choice. Existing TidyVNC history takes precedence over legacy files.")
          .font(.caption).foregroundStyle(.secondary)
        if state.foundNoSource {
          Text("No history file was found for that source. Choose another source or close this window.")
            .accessibilityIdentifier("historyImport.absent")
        }
        if let issue = state.issue { Text(issue).foregroundStyle(.red).accessibilityIdentifier("historyImport.error") }
        Spacer()
        Text("Import is a one-time copy. Changes are not synchronized with the original file.")
          .font(.caption).foregroundStyle(.secondary)
        Button("Close",action:close).keyboardShortcut(.cancelAction)
      }
    }.padding(24).frame(minWidth:600,minHeight:520,alignment:.topLeading)
      .background(Color(nsColor:.windowBackgroundColor))
  }
  private func reviewContent(_ review: NativeHistoryImportReview) -> some View {
    let proposal = review.proposal
    return Group {
      Text(proposal.origin == .currentXDG ? "Source: current TidyVNC history" : "Source: legacy history").font(.headline)
      Text(review.source.path).font(.caption).textSelection(.enabled).lineLimit(3)
      ScrollView {
        VStack(alignment:.leading,spacing:12) {
          Text("Server addresses to import (\(proposal.endpoints.count))").font(.headline)
          if proposal.endpoints.isEmpty { Text("This file contains no server addresses to import.") }
          ForEach(Array(proposal.endpoints.enumerated()),id:\.offset) { index,endpoint in
            Text("\(index+1). \(endpoint)").textSelection(.enabled)
              .fixedSize(horizontal:false,vertical:true)
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }.accessibilityIdentifier("historyImport.details")
      if proposal.requiresOmissionReview {
        Text("Omitted: \(proposal.duplicateCount) duplicate entries and \(proposal.omittedOlderCount) older entries beyond the 20-address limit.")
          .font(.callout).fixedSize(horizontal:false,vertical:true)
        Toggle("I reviewed the omitted entries.",isOn:$choices.acknowledged)
          .accessibilityIdentifier("historyImport.acknowledge")
      }
      Text("Import preserves the listed order and address spelling. No connection will be started.")
        .font(.caption).foregroundStyle(.secondary)
      if let issue = state.issue { Text(issue).foregroundStyle(.red).accessibilityIdentifier("historyImport.error") }
      HStack {
        Button("Cancel") { state.cancel(review.id) }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Import History") { state.approve(review.id,acknowledgingOmissions:choices.acknowledged) }
          .disabled(proposal.endpoints.isEmpty || (proposal.requiresOmissionReview && !choices.acknowledged))
          .keyboardShortcut(.defaultAction).accessibilityIdentifier("historyImport.approve")
      }
    }
  }
}

// A presentation owns its state until all IO drains. The destination is reloaded
// after success and after close, including a write whose acceptance was uncertain.
@MainActor final class HistoryImportWindowController: NSWindowController, NSWindowDelegate {
  let state: NativeHistoryImportState
  private(set) var isClosing = false
  private var closing: Task<Void,Never>?
  private var hosting: NSHostingController<HistoryImportView>?
  private var observation: AnyCancellable?
  private let onClosed: @MainActor (HistoryImportWindowController) -> Void
  init(service: any NativeHistoryImportServing, reloadHistory: @escaping @MainActor () -> Void,
       onClosed: @escaping @MainActor (HistoryImportWindowController) -> Void) {
    state = NativeHistoryImportState(service:service); self.onClosed = onClosed
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:640),
      styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    window.title = "Import Recent Connections"; window.isReleasedWhenClosed = false
    super.init(window:window)
    window.delegate = self
    let content = NSHostingController(rootView:HistoryImportView(state:state,close:{ [weak self] in self?.close() }))
    content.sizingOptions = []
    hosting = content; window.contentViewController = content
    window.setContentSize(NSSize(width:660,height:640)); window.minSize = NSSize(width:640,height:600)
    window.center()
    observation = state.$imported.compactMap { $0 }.sink { _ in reloadHistory() }
  }
  required init?(coder: NSCoder) { nil }
  func contentSizeThatFits(_ size: NSSize) -> NSSize? { hosting?.sizeThatFits(in:size) }
  override func showWindow(_ sender: Any?) {
    guard !isClosing else { return }
    super.showWindow(sender); window?.makeKeyAndOrderFront(sender)
  }
  func windowWillClose(_ notification: Notification) { beginClosing() }
  private func beginClosing() {
    guard !isClosing else { return }
    isClosing = true; state.stop()
    closing = Task { @MainActor in
      await state.close()
      observation = nil; window?.contentViewController = nil; hosting = nil
      onClosed(self)
    }
  }
  func shutdown() async { close(); beginClosing(); await closing?.value }
}
