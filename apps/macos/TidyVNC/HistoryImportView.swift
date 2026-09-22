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
        Text(String(localized:"history.import.have.a.recent.server.list.review.a.separate.history.import", defaultValue:"Have a recent-server list? Review a separate history import."))
          .font(.callout).fixedSize(horizontal:false,vertical:true)
        Spacer()
        Button(String(localized:"history.import.review.history", defaultValue:"Review History…"),action:open).accessibilityIdentifier("historyImport.firstUse")
        Button(String(localized:"history.import.not.now", defaultValue:"Not Now")) { history.dismissImportOffer() }.accessibilityIdentifier("historyImport.notNow")
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
      Text(state.review == nil ? String(localized:"history.import.import.recent.connections", defaultValue:"Import Recent Connections") : String(localized:"history.import.review.history.import", defaultValue:"Review History Import"))
        .font(.title2).accessibilityIdentifier("historyImport.title")
      if let review = state.review {
        reviewContent(review)
      } else if state.isLoading || state.isWriting || state.hasPending {
        ProgressView(state.isWriting ? String(localized:"history.import.saving.imported.history", defaultValue:"Saving imported history…") : String(localized:"history.import.reading.history", defaultValue:"Reading history…"))
        Spacer()
        if !state.isWriting, let id = state.requestID {
          Button(String(localized:"action.cancel", defaultValue:"Cancel")) { state.cancel(id) }.keyboardShortcut(.cancelAction)
        }
      } else if let imported = state.imported {
        Label(String(localized:"history.import.history.imported", defaultValue:"History imported"),systemImage:"checkmark.circle").font(.headline)
          .accessibilityIdentifier("historyImport.success")
        Text(String(localized:"history.import.success.count", defaultValue:"Server addresses available in Recent Connections: \((imported.recentEndpoints.count).formatted()). Select an address when you want to connect."))
        Text(String(localized:"history.import.your.saved.profiles.and.the.original.history.file.were.left.unchanged", defaultValue:"Your saved profiles and the original history file were left unchanged.")).foregroundStyle(.secondary)
        Spacer()
        Button(String(localized:"action.done", defaultValue:"Done"),action:close).keyboardShortcut(.defaultAction)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text(String(localized:"history.import.copy.recent.server.addresses.into.this.app.this.is.separate.from.importing", defaultValue:"Copy recent server addresses into this app. This is separate from importing connection defaults and does not start a connection."))
            Text(String(localized:"history.import.native.history.takes.precedence.including.history.you.previously.cleared.existing.saved.profiles", defaultValue:"Native history takes precedence, including history you previously cleared. Existing saved profiles are preserved.")).foregroundStyle(.secondary)
            Text(String(localized:"history.import.choose.a.source.to.review", defaultValue:"Choose a source to review:")).font(.headline)
            Button(String(localized:"history.import.review.current.tidyvnc.history", defaultValue:"Review Current TidyVNC History")) { begin(.currentXDG) }
              .keyboardShortcut(.defaultAction).accessibilityIdentifier("historyImport.current")
            Text(String(localized:"history.import.reads.the.existing.tidyvnc.history.location.including.an.absolute.xdg.state.override", defaultValue:"Reads the existing TidyVNC history location, including an absolute XDG state override."))
              .font(.caption).foregroundStyle(.secondary)
            Button(String(localized:"history.import.review.legacy.history", defaultValue:"Review Legacy History")) { begin(.legacy) }.accessibilityIdentifier("historyImport.legacy")
            Text(String(localized:"history.import.an.explicit.separate.choice.existing.tidyvnc.history.takes.precedence.over.legacy.files", defaultValue:"An explicit, separate choice. Existing TidyVNC history takes precedence over legacy files."))
              .font(.caption).foregroundStyle(.secondary)
            if state.foundNoSource {
              Text(String(localized:"history.import.no.history.file.was.found.for.that.source.choose.another.source.or", defaultValue:"No history file was found for that source. Choose another source or close this window."))
                .accessibilityIdentifier("historyImport.absent")
            }
            if let issue = state.issue { Text(issue).foregroundStyle(.red).accessibilityIdentifier("historyImport.error") }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        Text(String(localized:"history.import.import.is.a.one.time.copy.changes.are.not.synchronized.with.the", defaultValue:"Import is a one-time copy. Changes are not synchronized with the original file."))
          .font(.caption).foregroundStyle(.secondary)
        Button(String(localized:"history.import.close", defaultValue:"Close"),action:close).keyboardShortcut(.cancelAction)
      }
    }.padding(24).frame(minWidth:640,minHeight:572,alignment:.topLeading)
      .background(Color(nsColor:.windowBackgroundColor))
  }
  private func reviewContent(_ review: NativeHistoryImportReview) -> some View {
    let proposal = review.proposal
    return Group {
      Text(proposal.origin == .currentXDG ? String(localized:"history.import.source.current.tidyvnc.history", defaultValue:"Source: current TidyVNC history") : String(localized:"history.import.source.legacy.history", defaultValue:"Source: legacy history")).font(.headline)
      Text(review.source.path).font(.caption).textSelection(.enabled).lineLimit(3)
      ScrollView {
        VStack(alignment:.leading,spacing:12) {
          Text(String(localized:"history.import.address.count", defaultValue:"Server addresses to import (\((proposal.endpoints.count).formatted()))")).font(.headline)
          if proposal.endpoints.isEmpty { Text(String(localized:"history.import.this.file.contains.no.server.addresses.to.import", defaultValue:"This file contains no server addresses to import.")) }
          ForEach(Array(proposal.endpoints.enumerated()),id:\.offset) { index,endpoint in
            Text(String(localized:"history.import.address.row", defaultValue:"\((index+1).formatted()). \(endpoint)")).textSelection(.enabled)
              .fixedSize(horizontal:false,vertical:true)
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }.accessibilityIdentifier("historyImport.details")
      if proposal.requiresOmissionReview {
        Text(String(localized:"history.import.omitted.counts", defaultValue:"Omitted entries — duplicates: \((proposal.duplicateCount).formatted()); older entries beyond the 20-address limit: \((proposal.omittedOlderCount).formatted())."))
          .font(.callout).fixedSize(horizontal:false,vertical:true)
        Toggle(String(localized:"history.import.i.reviewed.the.omitted.entries", defaultValue:"I reviewed the omitted entries."),isOn:$choices.acknowledged)
          .accessibilityIdentifier("historyImport.acknowledge")
      }
      Text(String(localized:"history.import.import.preserves.the.listed.order.and.address.spelling.no.connection.will.be", defaultValue:"Import preserves the listed order and address spelling. No connection will be started."))
        .font(.caption).foregroundStyle(.secondary)
      if let issue = state.issue { Text(issue).foregroundStyle(.red).accessibilityIdentifier("historyImport.error") }
      HStack {
        Button(String(localized:"action.cancel", defaultValue:"Cancel")) { state.cancel(review.id) }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(String(localized:"history.import.import.history", defaultValue:"Import History")) { state.approve(review.id,acknowledgingOmissions:choices.acknowledged) }
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
    window.title = String(localized:"history.import.import.recent.connections", defaultValue:"Import Recent Connections"); window.isReleasedWhenClosed = false
    super.init(window:window)
    window.delegate = self
    let content = NSHostingController(rootView:HistoryImportView(state:state,close:{ [weak self] in self?.close() }))
    content.sizingOptions = [.minSize]
    hosting = content; window.contentViewController = content
    window.setContentSize(NSSize(width:660,height:640))
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
