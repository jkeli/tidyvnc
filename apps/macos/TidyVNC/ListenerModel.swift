// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation
import TidyVNCNative

@MainActor final class ListenerModel: ObservableObject {
  enum Phase { case idle, starting, listening, stopping, stopped, failed }
  @Published var port = "5500"
  @Published var ipv4 = true
  @Published var ipv6 = true
  @Published private(set) var phase: Phase = .idle
  @Published private(set) var incoming: [NativeIncomingPeer] = []
  @Published private(set) var addresses: [NativeListenerAddress] = []
  @Published private(set) var reserved: Set<UInt64> = []
  @Published private(set) var issue: String?
  @Published private(set) var preparationCancelled = false
  let preparation: NativeSessionDefaults?
  let displays: NativeDisplayService?
  private let ownsDisplays: Bool
  private let requiresPreparation: Bool
  private var preparationObservations: Set<AnyCancellable> = []
  private let runtime: NativeRuntime
  private let open: @MainActor (ReverseConnectionRequest) -> Bool
  private let invocation: NativeInvocationRequest?
  private var launchCredentials: NativeLaunchCredentialInputs?
  private var launchPending: Bool
  private var listener: NativeListener?
  private var observations: Set<AnyCancellable> = []
  private var cleanup: Task<Void,Never>?
  private var epoch: UInt64 = 0
  private(set) var closing = false
  init(runtime: NativeRuntime, launch: NativeInvocationLaunch? = nil,
       preferences: NativePreferencesStore? = nil, displays: NativeDisplayService? = nil,
       documentReader: any NativeDocumentReading = NativeDocumentFileReader(),
       open: @escaping @MainActor (ReverseConnectionRequest) -> Bool) {
    self.runtime = runtime; self.open = open
    invocation = launch?.listen == nil ? nil : launch?.invocation
    if let request = invocation { launchCredentials = launch?.credentials ?? (try? NativeLaunchCredentialInputs.fileOnly(request)) }
    else { launchCredentials = nil }
    launchPending = launch?.listen != nil
    requiresPreparation = launch?.listen != nil && launch?.document != nil
    ownsDisplays = requiresPreparation && displays == nil
    let screens = requiresPreparation ? (displays ?? NativeDisplayService()) : displays
    self.displays = screens
    if requiresPreparation, let preferences, let launch {
      preparation = NativeSessionDefaults(runtime:runtime,store:preferences,invocation:launch.invocation,
        document:launch.document,documentReader:documentReader,documentDisplays:{ [weak screens] in
          screens?.refresh(); return (try? screens?.snapshot.documentMonitorOrder()) ?? []
        },documentAvailableDisplays:{ [weak screens] in
          screens?.refresh(); return screens?.snapshot.displays.map(\.id) ?? []
        },purpose:.listener)
    } else { preparation = nil }
    if let options = launch?.listen { port = String(options.port); ipv4 = options.ipv4; ipv6 = options.ipv6 }
    if requiresPreparation && preparation == nil { issue = String(localized:"listener.saved.defaults.are.unavailable.reopen.the.application.to.review.this.listener.file", defaultValue:"Saved defaults are unavailable. Reopen the application to review this listener file.") }
    preparation?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in:&preparationObservations)
  }
  // Scene publication may repeat. Only the first appearance may bind on behalf
  // of the command line; Stop and window close revoke that request permanently.
  func startLaunchIfNeeded() {
    guard launchPending, !closing else { return }; launchPending = false
    if requiresPreparation { preparation?.load() } else { start() }
  }
  func acceptDocument(_ id: UUID) {
    guard !closing, !preparationCancelled, let preparation, preparation.documentReview?.id == id else { return }
    preparation.acceptDocument(id)
    guard preparation.isReady, let port = preparation.prepared?.document?.listenPort else { return }
    self.port = String(port)
    start()
  }
  func cancelDocument(_ id: UUID, mapping: Bool = false) {
    guard !closing, let preparation,
      (mapping ? preparation.documentMapping?.id : preparation.documentReview?.id) == id else { return }
    launchCredentials?.clear(); launchCredentials = nil
    if mapping { preparation.cancelDocumentMapping(id) } else { preparation.cancelDocument(id) }
  }
  var canStart: Bool { !closing && cleanup == nil && !preparationCancelled &&
    (!requiresPreparation || preparation?.isReady == true) && [.idle,.stopped,.failed].contains(phase) }
  var canStop: Bool { !closing && [.starting,.listening].contains(phase) }
  func start() {
    guard canStart else { return }
    let input = port.trimmingCharacters(in:.whitespacesAndNewlines)
    guard let selected = NativeListenPort.parse(input) else {
      issue = String(localized:"listener.enter.a.tcp.port.from.0.to.65535.port.0.chooses.an", defaultValue:"Enter a TCP port from 0 to 65535. Port 0 chooses an available port."); return
    }
    guard ipv4 || ipv6 else { issue = String(localized:"listener.enable.ipv4.or.ipv6.to.listen.for.connections", defaultValue:"Enable IPv4 or IPv6 to listen for connections."); return }
    var options = NativeListenOptions(); options.port = selected; options.ipv4 = ipv4; options.ipv6 = ipv6
    issue = nil; phase = .starting; addresses = []; incoming = []; reserved = []
    // A failed/stopped predecessor must finish closing before its port is rebound.
    let previous = listener; listener = nil; observations.removeAll()
    epoch &+= 1; let ticket = epoch
    cleanup = Task { @MainActor [weak self] in
      if let previous { try? await previous.close() }
      guard let self, self.epoch == ticket, !self.closing else { return }
      self.cleanup = nil
      do {
        let owner = try self.runtime.makeListener(options:options); self.listener = owner
        owner.$snapshot.sink { [weak self, weak owner] value in
          guard let self, let owner, self.listener === owner, !self.closing else { return }
          self.addresses = value.addresses
          switch value.state {
          case .starting: self.phase = .starting
          case .listening: self.phase = .listening
          case .stopping: self.phase = .stopping
          case .closed: self.phase = .stopped
          case .failed:
            self.phase = .failed
            switch value.failure {
            case .bind: self.issue = String(localized:"listener.the.listener.could.not.bind.this.port.check.whether.another.listener.is", defaultValue:"The listener could not bind this port. Check whether another listener is using it, or choose a different port.")
            case .eventOverflow: self.issue = String(localized:"listener.the.incoming.connection.queue.filled.before.it.could.be.processed.start.the", defaultValue:"The incoming connection queue filled before it could be processed. Start the listener again.")
            default: self.issue = String(localized:"listener.the.listener.stopped.because.it.could.not.receive.incoming.connections.start.it", defaultValue:"The listener stopped because it could not receive incoming connections. Start it again to retry.")
            }
          }
        }.store(in:&self.observations)
        owner.$incoming.sink { [weak self, weak owner] peers in
          guard let self, let owner, self.listener === owner, !self.closing else { return }
          self.incoming = peers; self.reserved.formIntersection(Set(peers.map(\.id)))
        }.store(in:&self.observations)
        owner.$deliveryError.compactMap { $0 }.sink { [weak self] _ in
          self?.issue = String(localized:"listener.listener.updates.could.not.be.delivered.stop.and.restart.the.listener", defaultValue:"Listener updates could not be delivered. Stop and restart the listener.")
        }.store(in:&self.observations)
      } catch {
        self.phase = .failed; self.issue = String(localized:"listener.the.listener.could.not.start.check.its.port.and.network.settings.then", defaultValue:"The listener could not start. Check its port and network settings, then retry.")
      }
    }
  }
  func canAccept(_ peer: NativeIncomingPeer) -> Bool { !closing && phase == .listening && incoming.contains(peer) && !reserved.contains(peer.id) }
  func accept(_ peer: NativeIncomingPeer) {
    guard canAccept(peer), let listener else { return }
    if let configuration = preparation?.prepared?.configuration, configuration.fullscreenPolicy.mode == .selected,
       !configuration.fullscreenPolicy.selectedDisplays.isEmpty {
      displays?.refresh()
      let available = Set(displays?.snapshot.displays.map(\.id) ?? [])
      guard displays?.snapshot.error == nil, Set(configuration.fullscreenPolicy.selectedDisplays).isSubset(of:available) else {
        issue = String(localized:"listener.a.reviewed.display.is.disconnected.reconnect.it.or.close.this.listener.and", defaultValue:"A reviewed display is disconnected. Reconnect it, or close this listener and reopen the file to choose displays."); return
      }
    }
    issue = nil
    reserved.insert(peer.id)
    if open(.init(listener:listener,peer:peer,invocation:invocation,credentials:launchCredentials,prepared:preparation?.prepared)) {
      launchCredentials = nil
    } else {
      reserved.remove(peer.id); issue = String(localized:"listener.a.connection.window.could.not.be.opened.try.again.or.reject.the", defaultValue:"A connection window could not be opened. Try again or reject the incoming connection.")
    }
  }
  func reject(_ peer: NativeIncomingPeer) {
    guard canAccept(peer), let listener else { return }
    do { try listener.reject(peer) }
    catch { issue = String(localized:"listener.this.incoming.connection.is.no.longer.available", defaultValue:"This incoming connection is no longer available.") }
  }
  func stop() {
    launchPending = false; launchCredentials?.clear(); launchCredentials = nil
    if requiresPreparation && preparation?.isReady != true {
      preparationCancelled = true; preparation?.stop()
    }
    guard canStop else { return }
    phase = .stopping; incoming = []; reserved = []
    epoch &+= 1; let ticket = epoch
    let prior = cleanup, owner = listener
    observations.removeAll(); listener = nil
    cleanup = Task { @MainActor [weak self] in
      await prior?.value
      try? await owner?.close()
      guard let self, self.epoch == ticket else { return }
      self.incoming = []; self.reserved = []; self.phase = .stopped; self.cleanup = nil
    }
  }
  func requestClose() {
    guard !closing else { return }
    launchPending = false; launchCredentials?.clear(); launchCredentials = nil
    if canStop { stop() }
    closing = true; epoch &+= 1
    preparation?.stop(); preparationObservations.removeAll()
    if ownsDisplays { displays?.stop() }
    let prior = cleanup, owner = listener; listener = nil; observations.removeAll()
    let preparation = preparation
    incoming = []; reserved = []
    cleanup = Task {
      await prior?.value
      try? await owner?.close()
      await preparation?.close()
    }
  }
  func close() async { requestClose(); await cleanup?.value }
}
