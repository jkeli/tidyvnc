// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import SwiftUI
import TidyVNCNative

@MainActor final class DefaultsImportAvailability: ObservableObject {
  @Published private(set) var canOffer = false
  @Published private(set) var dismissed = false
  private let store: NativePreferencesStore
  private var observation: Task<Void,Never>?, refreshTask: Task<Void,Never>?
  private var stopped = false
  init(store: NativePreferencesStore) { self.store = store; refresh() }
  deinit { observation?.cancel(); refreshTask?.cancel() }
  func refresh() {
    guard !stopped else { return }
    let store = self.store
    if observation == nil {
      observation = Task { [weak self] in
        do {
          for await snapshot in try await store.changes() {
            guard let self, !self.stopped, !Task.isCancelled else { break }
            self.canOffer = !snapshot.isStored
          }
        } catch { if let self, !self.stopped { self.canOffer = false } }
        self?.observation = nil
      }
    }
    guard refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      do {
        let snapshot = try await store.read()
        if let self, !self.stopped, !Task.isCancelled { self.canOffer = !snapshot.isStored }
      } catch { if let self, !self.stopped { self.canOffer = false } }
      self?.refreshTask = nil
    }
  }
  func dismiss() { dismissed = true }
  func stop() { stopped = true; canOffer = false; observation?.cancel(); refreshTask?.cancel() }
  func close() async { stop(); await observation?.value; await refreshTask?.value }
}

struct FirstUseDefaultsImportOffer: View {
  @ObservedObject var availability: DefaultsImportAvailability
  let open: () -> Void
  var body: some View {
    if availability.canOffer && !availability.dismissed {
      VStack(alignment:.leading,spacing:12) {
        Text(String(localized:"import.defaults.have.existing.tidyvnc.defaults.review.an.import.before.opening.your.next.connection", defaultValue:"Have existing TidyVNC defaults? Review an import before opening your next connection window."))
          .font(.callout).fixedSize(horizontal:false,vertical:true)
        HStack {
          Button(String(localized:"import.defaults.review.import", defaultValue:"Review Import…"),action:open).accessibilityIdentifier("import.firstUse")
          Button(String(localized:"history.import.not.now", defaultValue:"Not Now")) { availability.dismiss() }.accessibilityIdentifier("import.notNow")
        }
      }.padding(14).background(.quaternary)
    }
  }
}

struct DefaultsImportView: View {
  @ObservedObject var state: NativeDefaultsImportState
  let displays: @MainActor () -> NativeDisplaySnapshot
  let openConnection: @MainActor () -> Void
  let close: @MainActor () -> Void
  @MainActor private final class ReviewChoices: ObservableObject {
    @Published var acknowledged = false
    @Published var displayNames: [NativeDisplayID:String] = [:]
  }
  @StateObject private var choices = ReviewChoices()

  private func begin(_ origin: NativeImportOrigin) {
    let snapshot = displays()
    choices.displayNames = Dictionary(snapshot.displays.map { ($0.id,$0.name) },uniquingKeysWith:{ first,_ in first })
    choices.acknowledged = false
    state.begin(origin:origin,legacyDisplays:(try? snapshot.documentMonitorOrder()) ?? [],
      availableDisplays:snapshot.error == nil ? snapshot.displays.map(\.id) : [])
  }
  private func category(_ value: NativeDefaultsImportCategory) -> String {
    switch value {
    case .connection: String(localized:"import.defaults.connection.behavior", defaultValue:"Connection behavior")
    case .clipboard: String(localized:"import.defaults.clipboard.sharing", defaultValue:"Clipboard sharing")
    case .encoding: String(localized:"import.defaults.encoding.and.image.quality", defaultValue:"Encoding and image quality")
    case .input: String(localized:"import.defaults.keyboard.pointer.and.cursor", defaultValue:"Keyboard, pointer and cursor")
    case .scaling: String(localized:"import.defaults.desktop.scaling", defaultValue:"Desktop scaling")
    case .fullscreen: String(localized:"import.defaults.fullscreen.displays", defaultValue:"Fullscreen displays")
    }
  }
  private func notice(_ value: NativeDefaultsImportNotice) -> String {
    switch value.kind {
    case .excluded: String(localized:"import.defaults.not.imported", defaultValue:"Not imported")
    case .unknown: String(localized:"import.defaults.unknown.setting.not.imported", defaultValue:"Unknown setting; not imported")
    case .platformOnly: String(localized:"import.defaults.unavailable.on.macos.not.imported", defaultValue:"Unavailable on macOS; not imported")
    case .displayMapping: String(localized:"import.defaults.monitor.numbers.converted.to.the.displays.listed.below", defaultValue:"Monitor numbers converted to the displays listed below")
    case .inactiveCursor: String(localized:"import.defaults.hidden.cursor.preserved.inactive.system.cursor.shape.omitted", defaultValue:"Hidden cursor preserved; inactive System cursor shape omitted")
    }
  }
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      Text(state.mapping != nil ? String(localized:"import.defaults.choose.displays.for.imported.defaults", defaultValue:"Choose Displays for Imported Defaults") : state.review == nil ? String(localized:"import.defaults.import.connection.defaults", defaultValue:"Import Connection Defaults") : String(localized:"import.defaults.review.defaults.import", defaultValue:"Review Defaults Import"))
        .font(.title2).accessibilityIdentifier("import.title")
      if let mapping = state.mapping {
        DefaultsImportMappingView(mapping:mapping,displays:displays,issue:state.issue,
          resolve:{ assignments in
            let snapshot = displays()
            choices.displayNames = Dictionary(snapshot.displays.map { ($0.id,$0.name) },uniquingKeysWith:{ first,_ in first })
            choices.acknowledged = false
            state.resolveMapping(mapping.id,assignments:assignments,availableDisplays:snapshot.error == nil ? snapshot.displays.map(\.id) : [])
          },cancel:{ state.cancel(mapping.id) }).id(mapping.id)
      } else if let review = state.review {
        reviewContent(review)
      } else if state.isLoading || state.isWriting || state.hasPending {
        ProgressView(state.isWriting ? String(localized:"import.defaults.saving.imported.defaults", defaultValue:"Saving imported defaults…") : String(localized:"import.defaults.reading.defaults", defaultValue:"Reading defaults…"))
          .accessibilityIdentifier("import.progress")
        Spacer()
        if !state.isWriting, let id = state.requestID {
          Button(String(localized:"action.cancel", defaultValue:"Cancel")) { state.cancel(id) }.keyboardShortcut(.cancelAction).accessibilityIdentifier("import.cancel")
        }
      } else if state.imported != nil {
        Label(String(localized:"import.defaults.defaults.imported", defaultValue:"Defaults imported"),systemImage:"checkmark.circle").font(.headline).accessibilityIdentifier("import.success")
        Text(String(localized:"import.defaults.open.a.new.connection.window.to.use.these.defaults.existing.windows.keep", defaultValue:"Open a new connection window to use these defaults. Existing windows keep their own settings."))
        Text(String(localized:"import.defaults.the.original.settings.file.was.left.unchanged", defaultValue:"The original settings file was left unchanged.")).foregroundStyle(.secondary)
        Spacer()
        HStack {
          Button(String(localized:"action.done", defaultValue:"Done"),action:close).keyboardShortcut(.cancelAction)
          Spacer()
          Button(String(localized:"import.defaults.new.connection", defaultValue:"New Connection")) { openConnection(); close() }.keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("import.newConnection")
        }
      } else {
        ScrollView {
          VStack(alignment:.leading,spacing:16) {
            Text(String(localized:"import.defaults.bring.ordinary.connection.settings.into.this.native.app.saved.native.defaults.take", defaultValue:"Bring ordinary connection settings into this native app. Saved native defaults take precedence and cannot be replaced by import."))
            Text(String(localized:"import.defaults.passwords.server.addresses.security.settings.certificate.files.trust.decisions.and.tunnel.commands", defaultValue:"Passwords, server addresses, security settings, certificate files, trust decisions and tunnel commands are excluded. Recent server addresses are not included."))
              .foregroundStyle(.secondary)
            Text(String(localized:"history.import.choose.a.source.to.review", defaultValue:"Choose a source to review:")).font(.headline)
            Button(String(localized:"import.defaults.review.current.tidyvnc.defaults", defaultValue:"Review Current TidyVNC Defaults")) { begin(.currentXDG) }
              .keyboardShortcut(.defaultAction).accessibilityIdentifier("import.current")
            Text(String(localized:"import.defaults.reads.the.existing.tidyvnc.configuration.location.including.an.absolute.xdg.override", defaultValue:"Reads the existing TidyVNC configuration location, including an absolute XDG override."))
              .font(.caption).foregroundStyle(.secondary)
            Button(String(localized:"import.defaults.review.legacy.defaults", defaultValue:"Review Legacy Defaults")) { begin(.legacy) }.accessibilityIdentifier("import.legacy")
            Text(String(localized:"import.defaults.an.explicit.separate.choice.existing.tidyvnc.defaults.take.precedence.over.legacy.files", defaultValue:"An explicit, separate choice. Existing TidyVNC defaults take precedence over legacy files."))
              .font(.caption).foregroundStyle(.secondary)
          }.frame(maxWidth:.infinity,alignment:.leading)
        }
        if state.foundNoSource {
          Text(String(localized:"import.defaults.no.defaults.file.was.found.for.that.source.choose.another.source.or", defaultValue:"No defaults file was found for that source. Choose another source or close this window."))
            .accessibilityIdentifier("import.absent")
        }
        if let issue = state.issue {
          Text(issue).foregroundStyle(.red).accessibilityIdentifier("import.error")
        }
        Text(String(localized:"import.defaults.imports.are.a.one.time.copy.native.defaults.are.saved.by.this", defaultValue:"Imports are a one-time copy. Native defaults are saved by this app; changes are not synchronized with the original files."))
          .font(.caption).foregroundStyle(.secondary)
        Button(String(localized:"history.import.close", defaultValue:"Close"),action:close).keyboardShortcut(.cancelAction).accessibilityIdentifier("import.close")
      }
    }
    .fixedSize(horizontal:false,vertical:false)
    .padding(24).frame(minWidth:640,minHeight:572,alignment:.topLeading)
    .background(Color(nsColor:.windowBackgroundColor))
  }
  private func reviewContent(_ review: NativeDefaultsImportReview) -> some View {
    let proposal = review.proposal
    return Group {
      Text(proposal.origin == .currentXDG ? String(localized:"import.defaults.source.current.tidyvnc.defaults", defaultValue:"Source: current TidyVNC defaults") : String(localized:"import.defaults.source.legacy.defaults", defaultValue:"Source: legacy defaults")).font(.headline)
      Text(review.source.path).font(.caption).textSelection(.enabled).lineLimit(3)
        .accessibilityIdentifier("import.source")
      ScrollView {
        VStack(alignment:.leading,spacing:12) {
          Text(String(localized:"import.defaults.settings.to.import", defaultValue:"Settings to import")).font(.headline)
          if proposal.categories.isEmpty {
            Text(String(localized:"import.defaults.this.file.contains.no.supported.ordinary.settings.to.import", defaultValue:"This file contains no supported ordinary settings to import."))
          } else {
            ForEach(NativeDefaultsImportCategory.allCases.filter { proposal.categories.contains($0) },id:\.self) {
              Text(category($0))
            }
          }
          if !proposal.notices.isEmpty {
            Divider()
            Text(String(localized:"import.defaults.omissions.and.conversions", defaultValue:"Omissions and conversions")).font(.headline)
            ForEach(Array(proposal.notices.enumerated()),id:\.offset) { _,value in
              Text(String(localized:"import.defaults.notice", defaultValue:"Line \(value.line.formatted()), \(value.name): \(notice(value))")).font(.callout)
                .fixedSize(horizontal:false,vertical:true)
            }
          }
          if proposal.notices.contains(where:{ $0.kind == .displayMapping }) {
            Text(String(localized:"import.defaults.displays.for.imported.defaults", defaultValue:"Displays for imported defaults")).font(.headline)
            ForEach(review.monitorNumbers,id:\.self) { number in
              let id = review.monitorMapping?[number] ?? (number <= review.legacyDisplays.count ? review.legacyDisplays[number-1] : nil)
              let name = id.map { choices.displayNames[$0] ?? $0.rawValue } ?? String(localized:"document.unavailable.display", defaultValue:"Unavailable display")
              Text(String(localized:"document.monitor.file.assignment", defaultValue:"File monitor \(number.formatted()): \(name)"))
            }
            Text(review.monitorMapping == nil ? String(localized:"import.defaults.numbering.follows.the.current.arrangement.left.to.right.and.then.top.to", defaultValue:"Numbering follows the current arrangement, left to right and then top to bottom. Change assignments if this file came from another arrangement.") : String(localized:"import.defaults.these.are.the.display.assignments.you.chose.for.imported.defaults", defaultValue:"These are the display assignments you chose for imported defaults."))
              .font(.caption).foregroundStyle(.secondary)
            if state.canEditMapping {
              Button(String(localized:"document.change.display.assignments", defaultValue:"Change Display Assignments…")) {
                let snapshot = displays()
                choices.acknowledged = false
                state.editMapping(review.id,legacyDisplays:(try? snapshot.documentMonitorOrder()) ?? [],
                  availableDisplays:snapshot.error == nil ? snapshot.displays.map(\.id) : [])
              }.accessibilityIdentifier("import.mapping.edit")
            }
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
      }.accessibilityIdentifier("import.details")
      if !proposal.notices.isEmpty {
        Toggle(String(localized:"import.defaults.i.reviewed.the.omissions.and.conversions", defaultValue:"I reviewed the omissions and conversions."),isOn:$choices.acknowledged)
          .accessibilityIdentifier("import.acknowledge")
      }
      Text(String(localized:"import.defaults.import.saves.this.reviewed.copy.for.new.connection.windows.and.leaves.the", defaultValue:"Import saves this reviewed copy for new connection windows and leaves the source file unchanged."))
        .font(.caption).foregroundStyle(.secondary)
      if let issue = state.issue { Text(issue).foregroundStyle(.red).accessibilityIdentifier("import.error") }
      HStack {
        Button(String(localized:"action.cancel", defaultValue:"Cancel")) { state.cancel(review.id) }.keyboardShortcut(.cancelAction).accessibilityIdentifier("import.cancel")
        Spacer()
        Button(String(localized:"import.defaults.import.defaults", defaultValue:"Import Defaults")) {
          let snapshot = displays()
          let current = review.monitorMapping == nil ? (try? snapshot.documentMonitorOrder()) ?? [] :
            snapshot.error == nil ? snapshot.displays.map(\.id) : []
          state.approve(review.id,acknowledging:Set(proposal.notices.map(\.line)),
            currentDisplays:current)
        }.disabled(proposal.categories.isEmpty || (!proposal.notices.isEmpty && !choices.acknowledged))
          .keyboardShortcut(.defaultAction).accessibilityIdentifier("import.approve")
      }
    }
  }
}

private struct DefaultsImportMappingView: View {
  let mapping: NativeDefaultsImportMapping
  let displays: @MainActor () -> NativeDisplaySnapshot
  let issue: String?
  let resolve: ([Int:NativeDisplayID]) -> Void
  let cancel: () -> Void
  @MainActor private final class Choices: ObservableObject {
    @Published var snapshot: NativeDisplaySnapshot?
    @Published var assignments: [Int:NativeDisplayID] = [:]
  }
  @StateObject private var choices = Choices()
  private var complete: Bool {
    guard let snapshot = choices.snapshot, snapshot.error == nil else { return false }
    return mapping.numbers.allSatisfy { number in
      guard let id = choices.assignments[number] else { return false }
      return snapshot.display(id) != nil
    }
  }
  var body: some View {
    ScrollView {
      VStack(alignment:.leading,spacing:16) {
        Text(String(localized:"import.defaults.choose.a.connected.display.for.each.monitor.number.in.these.defaults.you", defaultValue:"Choose a connected display for each monitor number in these defaults. You will review the settings before importing."))
        Text(mapping.source.path).font(.caption).textSelection(.enabled).lineLimit(3)
        VStack(alignment:.leading,spacing:12) {
          ForEach(mapping.numbers,id:\.self) { number in
            let label = String(localized:"document.monitor.file.label", defaultValue:"File monitor \(number.formatted())")
            Text(label).fixedSize(horizontal:false,vertical:true)
            Picker(label,selection:Binding(get:{ choices.assignments[number]?.rawValue },
              set:{ choices.assignments[number] = $0.map(NativeDisplayID.init) })) {
              Text(String(localized:"document.choose.a.display", defaultValue:"Choose a display")).tag(nil as String?)
              ForEach(choices.snapshot?.displays ?? [],id:\.id) { display in
                Text(display.name).tag(display.id.rawValue as String?)
              }
              if let id = choices.assignments[number], choices.snapshot?.display(id) == nil {
                Text(String(localized:"document.disconnected.display", defaultValue:"Disconnected display")).tag(id.rawValue as String?)
              }
            }.labelsHidden().accessibilityLabel(label).accessibilityIdentifier("import.mapping.monitor.\(number)")
          }
        }.frame(maxWidth:.infinity,alignment:.leading)
        Text(String(localized:"import.defaults.several.monitor.numbers.may.use.the.same.display.that.display.will.be", defaultValue:"Several monitor numbers may use the same display; that display will be selected once. Review the settings and omissions before importing. The source file stays unchanged."))
          .font(.caption).foregroundStyle(.secondary)
      }.frame(maxWidth:.infinity,alignment:.leading)
    }
    if let issue { Text(issue).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true) }
    else if choices.snapshot?.error != nil || choices.snapshot?.displays.isEmpty != false {
      Text(String(localized:"document.display.information.is.unavailable.connect.a.display.and.refresh.before.continuing", defaultValue:"Display information is unavailable. Connect a display and refresh before continuing.")).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
    }
    Button(String(localized:"document.refresh.displays", defaultValue:"Refresh Displays")) { choices.snapshot = displays() }
    HStack {
      Button(String(localized:"action.cancel", defaultValue:"Cancel"),action:cancel).keyboardShortcut(.cancelAction)
      Spacer()
      Button(String(localized:"import.defaults.review.defaults", defaultValue:"Review Defaults")) { resolve(choices.assignments) }.disabled(!complete)
        .keyboardShortcut(.defaultAction).accessibilityIdentifier("import.mapping.review")
    }.onAppear { choices.snapshot = displays(); choices.assignments = mapping.suggested }
  }
}

// Each presentation owns a fresh state. Closing revokes its callbacks immediately
// and retains the controller until all IO has drained; reopening cannot revive it.
@MainActor final class DefaultsImportWindowController: NSWindowController, NSWindowDelegate {
  let state: NativeDefaultsImportState
  private(set) var isClosing = false
  private var closing: Task<Void,Never>?
  private var hosting: NSHostingController<DefaultsImportView>?
  private let onClosed: @MainActor (DefaultsImportWindowController) -> Void
  init(service: any NativeDefaultsImportServing, displays: @escaping @MainActor () -> NativeDisplaySnapshot,
       openConnection: @escaping @MainActor () -> Void,
       onClosed: @escaping @MainActor (DefaultsImportWindowController) -> Void) {
    state = NativeDefaultsImportState(service:service); self.onClosed = onClosed
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:660,height:640),
      styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
    window.title = String(localized:"import.defaults.import.connection.defaults", defaultValue:"Import Connection Defaults"); window.isReleasedWhenClosed = false
    super.init(window:window)
    window.delegate = self
    let content = NSHostingController(rootView:DefaultsImportView(state:state,displays:displays,
      openConnection:openConnection,close:{ [weak self] in self?.close() }))
    // Propagate the view’s content floor; an empty sizing policy resets an
    // explicitly assigned AppKit minimum after the host completes layout.
    content.sizingOptions = [.minSize]
    hosting = content; window.contentViewController = content
    window.setContentSize(NSSize(width:660,height:640))
    window.center()
  }
  required init?(coder: NSCoder) { nil }
  func contentSizeThatFits(_ size: NSSize) -> NSSize? { hosting?.sizeThatFits(in:size) }
  override func showWindow(_ sender: Any?) {
    guard !isClosing else { return }
    super.showWindow(sender); window?.makeKeyAndOrderFront(sender)
  }
  func windowWillClose(_ notification: Notification) {
    beginClosing()
  }
  private func beginClosing() {
    guard !isClosing else { return }
    isClosing = true; state.stop()
    closing = Task { @MainActor in
      await state.close()
      window?.contentViewController = nil; hosting = nil
      onClosed(self)
    }
  }
  func shutdown() async {
    close(); beginClosing(); await closing?.value
  }
}
