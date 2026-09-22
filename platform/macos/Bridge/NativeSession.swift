// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation
import TidyVNC

@MainActor
public final class NativeSession: ObservableObject {
  public let pointerEventIntervalMilliseconds: UInt32
  public let pointerEventIntervalSource: NativeOptionSource
  public let maxCutText: UInt32
  public let maxCutTextSource: NativeOptionSource
  public let initialWindowStartupPolicy: NativeWindowStartupPolicy
  public let initialWindowStartupSources: [NativeWindowStartupOption:NativeOptionSource]
  public let networkPolicy: NativeNetworkPolicy
  public let networkSources: [NativeNetworkOption:NativeOptionSource]
  public let initialFullscreenPolicy: NativeFullscreenPolicy
  public let initialFullscreenSources: [NativeFullscreenOption:NativeOptionSource]
  public let initialResizeSources: [NativeResizeOption:NativeOptionSource]
  public private(set) var resizeSources: [NativeResizeOption:NativeOptionSource]
  public let initialResizePolicy: NativeRemoteResizePolicy
  @Published public private(set) var resizePolicy: NativeRemoteResizePolicy
  public private(set) var resizePolicyRevision = UUID()
  public lazy var remoteResize = NativeRemoteResizeCoordinator(session:self)
  public func setResizePolicy(_ value: NativeRemoteResizePolicy, expected: UUID) throws {
    guard !isClosing else { throw NativeError(.closing,"Session closing") }
    guard expected == resizePolicyRevision else { throw NativeError(.stale,"Resize settings changed") }
    if value.enabled != resizePolicy.enabled { resizeSources[.enabled] = .session }
    if value.initialSize != resizePolicy.initialSize { resizeSources[.initialSize] = .session }
    resizePolicyRevision = UUID(); resizePolicy = value
  }

  public let initialShared: Bool, initialReconnectOnError: Bool
  public private(set) var reconnectOnErrorEnabled: Bool
  private var sharedSource: NativeOptionSource, reconnectSource: NativeOptionSource
  public let initialSecurityTypes: [UInt32]
  public let initialTLSPriority: String
  public let initialTLSPrioritySource: NativeOptionSource
  public let initialSecuritySource: NativeOptionSource
  public let initialTrustFiles: NativeTrustFiles
  public let initialScaling: NativeScaling?
  public let initialScalingSources: [NativeScalingOption: NativeOptionSource]
  public let initialInput: NativeInputSettings
  public let initialInputSources: [NativeInputOption: NativeOptionSource]
  public private(set) var viewOnlySource: NativeOptionSource
  public private(set) var middleButtonSource: NativeOptionSource
  private let runtime: NativeRuntime
  private let handle: NativeHandle
  private let imageStream = UUID()
  let presentations = NativePresentationPool()
  private var subscription: NativeHandle?
  private var delivery: NativeDelivery?
  private var closeTask: Task<Void, Error>?
  private struct Pending {
    let operation: NativeOperation
    let continuation: CheckedContinuation<NativeCompletion, Error>
    var cancelled = false
  }
  private var pending: [UUID: Pending] = [:]
  @Published public private(set) var snapshot: NativeSnapshot
  public var information: NativeConnectionInformation? {
    !isClosing && snapshot.generation == generation && snapshot.state == .connected ? snapshot.information : nil
  }
  public var informationUpdates: AnyPublisher<NativeConnectionInformation?, Never> {
    $snapshot.map(\.information).removeDuplicates().eraseToAnyPublisher()
  }
  // Image streams replay one retained value to AppKit without sending
  // objectWillChange to the SwiftUI connection shell. Subscribe on MainActor.
  private let frameSubject = CurrentValueSubject<NativeImage?, Never>(nil)
  private let cursorSubject = CurrentValueSubject<NativeImage?, Never>(nil)
  public var frameUpdates: AnyPublisher<NativeImage?, Never> { frameSubject.eraseToAnyPublisher() }
  public var cursorUpdates: AnyPublisher<NativeImage?, Never> { cursorSubject.eraseToAnyPublisher() }
  public private(set) var frame: NativeImage? {
    get { frameSubject.value }
    set {
      guard frameSubject.value !== newValue else { return }
      frameSubject.send(newValue)
      let available = frameSubject.value != nil
      if hasFrame != available { hasFrame = available }
    }
  }
  public private(set) var cursor: NativeImage? {
    get { cursorSubject.value }
    set { if cursorSubject.value !== newValue { cursorSubject.send(newValue) } }
  }
  @Published public private(set) var hasFrame = false
  @Published public private(set) var prompt: NativePrompt?
  @Published public private(set) var deliveryError: NativeError?
  @Published public private(set) var isClosing = false
  @Published public private(set) var isFocused = false
  @Published private(set) var desktopFocusOwner: UUID?
  @Published public private(set) var emulatesMiddleButton = false
  @Published public private(set) var isViewOnly = false
  @Published public private(set) var clipboard: NativeClipboardUpdate?
  @Published public private(set) var clipboardSendEnabled = true
  @Published public private(set) var clipboardReceiveEnabled = true
  public private(set) var generation: UInt64 = 1

  public func connectionOptions() throws -> NativeConnectionOptions {
    var value = abi(tidyvnc_sharing.self)
    try checked { tidyvnc_session_sharing(handle.raw,&value,$0) }
    return .init(shared:value.shared != 0,reconnectOnError:reconnectOnErrorEnabled,editable:value.editable != 0,
      revision:value.revision,generation:value.generation,sharedSource:sharedSource,reconnectSource:reconnectSource)
  }
  public func setConnectionOptions(shared: Bool, reconnectOnError: Bool, expected: NativeConnectionOptions) throws {
    guard !isClosing else { throw NativeError(.closing,"Session closing") }
    var revision: UInt64 = 0
    try checked { tidyvnc_session_set_shared(handle.raw,expected.generation,expected.revision,shared ? 1 : 0,&revision,$0) }
    if shared != expected.shared { sharedSource = .session }
    if reconnectOnError != expected.reconnectOnError { reconnectSource = .session }
    reconnectOnErrorEnabled = reconnectOnError; objectWillChange.send()
  }
  public func securityConfiguration() throws -> NativeSessionSecurity {
    var value = abi(tidyvnc_security_configuration.self)
    try checked { tidyvnc_session_security(handle.raw,&value,$0) }
    return NativeSessionSecurity(revision:value.revision,generation:value.generation,editable:value.editable != 0,
      preferences:.init(types:securityText(value.types),tlsPriority:securityText(value.tls_priority)),
      trustFiles:.init(caFile:securityText(value.ca_file),crlFile:securityText(value.crl_file)))
  }
  // Callers preflight syntax off MainActor. The core atomically checks both
  // identities and refuses active attempts, including setup and terminal drain.
  public func setSecurity(_ preferences: NativeSecurityPreferences, trustFiles: NativeTrustFiles,
                          expected: NativeSessionSecurity) throws {
    guard let types = preferences.types, let priority = preferences.tlsPriority,
          let ca = trustFiles.caFile, let crl = trustFiles.crlFile else { throw NativeError(.invalidArgument,"Unresolved security settings") }
    guard !isClosing else { throw NativeError(.closing,"Session closing") }
    try trustFiles.validate()
    _ = try withText(types) { types in try withText(priority) { priority in
      try withText(ca) { ca in try withText(crl) { crl in
        var value = abi(tidyvnc_security_update.self), revision: UInt64 = 0
        value.types = types; value.tls_priority = priority; value.ca_file = ca; value.crl_file = crl
        try checked { tidyvnc_session_set_security(handle.raw,expected.generation,expected.revision,&value,&revision,$0) }
      }}
    }}
    objectWillChange.send()
  }
  init(runtime: NativeRuntime, configuration: NativeSessionConfiguration) throws {
    var inputTiming = abi(tidyvnc_input_timing.self)
    try checked { tidyvnc_input_timing_init(&inputTiming,$0) }
    if let interval = configuration.pointerEventIntervalMilliseconds { inputTiming.pointer_interval_ms = interval }
    pointerEventIntervalMilliseconds = inputTiming.pointer_interval_ms
    pointerEventIntervalSource = configuration.pointerEventIntervalSource ?? (configuration.pointerEventIntervalMilliseconds == nil ? .compiled : .session)
    var messageLimits = abi(tidyvnc_message_limits.self)
    try checked { tidyvnc_message_limits_init(&messageLimits,$0) }
    if let limit = configuration.maxCutText { messageLimits.max_cut_text = limit }
    maxCutText = messageLimits.max_cut_text
    maxCutTextSource = configuration.maxCutTextSource ?? (configuration.maxCutText == nil ? .compiled : .session)
    initialWindowStartupPolicy = configuration.windowStartupPolicy; initialWindowStartupSources = configuration.windowStartupSources
    networkPolicy = configuration.networkPolicy; networkSources = configuration.networkSources
    initialFullscreenPolicy = configuration.fullscreenPolicy; initialFullscreenSources = configuration.fullscreenSources
    initialResizeSources = configuration.resizeSources; resizeSources = configuration.resizeSources
    initialResizePolicy = configuration.resizePolicy; resizePolicy = configuration.resizePolicy
    initialShared = configuration.shared; initialReconnectOnError = configuration.reconnectOnError
    reconnectOnErrorEnabled = configuration.reconnectOnError
    sharedSource = configuration.sharedSource; reconnectSource = configuration.reconnectSource
    // Validate all host input values before allocating a session handle.
    guard configuration.input.shortcutModifiers.rawValue & ~15 == 0 else { throw NativeError(.invalidArgument, "Invalid shortcut modifiers") }
    initialTrustFiles = NativeTrustFiles(caFile: configuration.caFile, crlFile: configuration.crlFile)
    initialScaling = configuration.scaling; initialScalingSources = configuration.scalingSources
    initialInput = configuration.input; initialInputSources = configuration.inputSources
    viewOnlySource = configuration.inputSources[.viewOnly] ?? .compiled
    middleButtonSource = configuration.inputSources[.emulateMiddle] ?? .compiled
    self.runtime = runtime
    var options = abi(tidyvnc_session_options.self)
    try checked { tidyvnc_session_options_init(&options, $0) }
    if let types = configuration.securityTypes {
      guard types.count <= 32 else { throw NativeError(.invalidArgument, "Too many security types") }
      options.security_count = UInt32(types.count)
      withUnsafeMutableBytes(of: &options.security_types) { bytes in
        let target = bytes.bindMemory(to: UInt32.self)
        for index in target.indices { target[index] = index < types.count ? types[index] : 0 }
      }
    }
    initialSecurityTypes = withUnsafeBytes(of: options.security_types) { Array($0.bindMemory(to: UInt32.self).prefix(Int(options.security_count))) }
    initialTLSPriority = configuration.tlsPriority
    initialTLSPrioritySource = configuration.tlsPrioritySource ?? (configuration.tlsPriority.isEmpty ? .compiled : .session)
    initialSecuritySource = configuration.securitySource ?? (configuration.securityTypes == nil ? .compiled : .session)
    options.prompt_timeout_ms = configuration.promptTimeoutMilliseconds
    options.event_capacity = configuration.eventCapacity; options.command_capacity = configuration.commandCapacity
    options.framebuffer_bytes = configuration.framebufferBytes; options.publication_bytes = configuration.publicationBytes
    var raw: UInt64 = 0
    try withText(configuration.tlsPriority) { priority in
      try withText(configuration.caFile) { ca in
        try withText(configuration.crlFile) { crl in
          options.tls_priority = priority; options.ca_file = ca; options.crl_file = crl
          try checked { tidyvnc_session_create_with_message_limits(runtime.handle.raw, &options, configuration.encoding?.handle.raw ?? 0, &inputTiming, &messageLimits, &raw, $0) }
        }
      }
    }
    let owner = NativeHandle(adopting: raw); handle = owner
    var current = abi(tidyvnc_snapshot.self)
    try checked { tidyvnc_session_snapshot(owner.raw, &current, $0) }; snapshot = NativeSnapshot(current)
    try checked { tidyvnc_session_clipboard_policy(owner.raw, current.generation, configuration.clipboardSend ? 1 : 0, configuration.clipboardReceive ? 1 : 0, $0) }
    if configuration.shared {
      var policy = abi(tidyvnc_sharing.self), revision: UInt64 = 0
      try checked { tidyvnc_session_sharing(owner.raw,&policy,$0) }
      try checked { tidyvnc_session_set_shared(owner.raw,policy.generation,policy.revision,1,&revision,$0) }
    }
    clipboardSendEnabled = configuration.clipboardSend; clipboardReceiveEnabled = configuration.clipboardReceive
    try checked { tidyvnc_session_input_policy(owner.raw, configuration.input.viewOnly ? 1 : 0, configuration.input.emulateMiddle ? 1 : 0, $0) }
    isViewOnly = configuration.input.viewOnly; emulatesMiddleButton = configuration.input.emulateMiddle
    let context = NativeDelivery { [weak self] id, generation in self?.receive(subscription: id, generation: generation) }
    delivery = context
    var callbacks = abi(tidyvnc_callbacks.self)
    callbacks.context = Unmanaged.passUnretained(context).toOpaque()
    callbacks.retain_context = retainNativeDelivery; callbacks.release_context = releaseNativeDelivery
    callbacks.ready = readyNativeDelivery
    var subscribed: UInt64 = 0
    _ = try withExtendedLifetime(context) { try checked { tidyvnc_session_subscribe(owner.raw, &callbacks, &subscribed, $0) } }
    subscription = NativeHandle(adopting: subscribed)
  }

  public func connect(endpoint: String) async throws -> NativeCompletion {
    try await submit(advancesGeneration: true) { operation, error in
      var options = abi(tidyvnc_connect_options.self)
      let status = tidyvnc_connect_options_init(&options, error)
      guard status == UInt32(TIDYVNC_OK) else { return status }
      options.ipv4 = networkPolicy.ipv4 ? 1 : 0; options.ipv6 = networkPolicy.ipv6 ? 1 : 0
      return withText(endpoint) { bytes in
        options.endpoint = bytes; return tidyvnc_session_connect(handle.raw, &options, operation, error)
      }
    }
  }
  public func disconnect() async throws -> NativeCompletion {
    try await submit { tidyvnc_session_disconnect(handle.raw, generation, $0, $1) }
  }
  // The caller owns a ready tunnel until this session's transport has drained.
  // Durable credential/trust owners must use endpoint + routeIdentity as well.
  public func connect(endpoint: String, through localEndpoint: String, routeIdentity: String) async throws -> NativeCompletion {
    var raw: UInt64 = 0
    _ = try withText(endpoint) { endpoint in
      try withText(routeIdentity) { route in
        try checked { tidyvnc_endpoint_create(endpoint,route,0,&raw,$0) }
      }
    }
    let target = NativeHandle(adopting:raw)
    return try await submit(advancesGeneration:true) { operation,error in
      var options = abi(tidyvnc_connect_options.self)
      let status = tidyvnc_connect_options_init(&options,error)
      guard status == UInt32(TIDYVNC_OK) else { return status }
      options.ipv4 = networkPolicy.ipv4 ? 1 : 0; options.ipv6 = networkPolicy.ipv6 ? 1 : 0
      return withText(localEndpoint) { bytes in
        options.endpoint = bytes
        return tidyvnc_session_connect_routed(handle.raw,target.raw,&options,operation,error)
      }
    }
  }
  func acceptIncoming(listener: NativeHandle, incoming: UInt64) async throws -> NativeCompletion {
    try await submit(advancesGeneration:true) { tidyvnc_listener_accept(listener.raw,incoming,handle.raw,$0,$1) }
  }
  public func refresh() async throws -> NativeCompletion {
    try await submit { tidyvnc_session_refresh(handle.raw, generation, $0, $1) }
  }
  public func desktopLayout() throws -> NativeRemoteDesktop {
    var value = abi(tidyvnc_desktop_layout.self)
    try checked { tidyvnc_session_desktop_layout(handle.raw, generation, &value, $0) }
    return try NativeRemoteDesktop(value)
  }
  public func requestDesktopLayout(_ layout: NativeRemoteLayout, expectedGeneration: UInt64) async throws -> NativeCompletion {
    try await resize(layout,expectedGeneration:expectedGeneration,automatic:false)
  }
  func requestAutomaticDesktopLayout(_ layout: NativeRemoteLayout, expectedGeneration: UInt64) async throws -> NativeCompletion {
    try await resize(layout,expectedGeneration:expectedGeneration,automatic:true)
  }
  private func resize(_ layout: NativeRemoteLayout, expectedGeneration: UInt64, automatic: Bool) async throws -> NativeCompletion {
    try await submit { operation, error in
      let status = layout.withABI { tidyvnc_session_request_desktop_layout(handle.raw, expectedGeneration, $0, operation, error) }
      if status == UInt32(TIDYVNC_OK) && !automatic { remoteResize.manualRequest() }
      return status
    }
  }
  public func encodingOptions() throws -> NativeEncodingOptions {
    var raw: UInt64 = 0
    try checked { tidyvnc_session_encoding(handle.raw, &raw, $0) }
    return NativeEncodingOptions(owning: raw)
  }
  public func applyEncoding(_ options: NativeEncodingOptions, expectedGeneration: UInt64? = nil) async throws -> NativeCompletion {
    try await submit { tidyvnc_session_apply_encoding(handle.raw, expectedGeneration ?? generation, options.handle.raw, $0, $1) }
  }
  public func offerClipboard(_ text: String, origin: NativeClipboardText? = nil, changeID: UInt64 = 0, expectedGeneration: UInt64? = nil) async throws -> NativeCompletion {
    try await submit { operation, error in
      withText(text) { tidyvnc_session_clipboard_offer(handle.raw, expectedGeneration ?? generation, $0, origin?.handle.raw ?? 0, changeID, operation, error) }
    }
  }
  public func clearClipboard(expectedGeneration: UInt64? = nil) async throws -> NativeCompletion {
    try await submit { tidyvnc_session_clipboard_clear(handle.raw, expectedGeneration ?? generation, $0, $1) }
  }
  public func setClipboardPolicy(send: Bool, receive: Bool) throws {
    try checked { tidyvnc_session_clipboard_policy(handle.raw, generation, send ? 1 : 0, receive ? 1 : 0, $0) }
    clipboardSendEnabled = send; clipboardReceiveEnabled = receive
  }
  public func validateClipboard(_ route: NativeClipboardRoute, sending: Bool) throws {
    var value = route.abiValue
    try checked { tidyvnc_session_clipboard_check(handle.raw, &value, sending ? 1 : 0, $0) }
  }
  private func submit(advancesGeneration: Bool = false,
    _ send: (UnsafeMutablePointer<tidyvnc_operation>, UnsafeMutablePointer<tidyvnc_error>) -> UInt32) async throws -> NativeCompletion {
    let token = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      guard !isClosing else { throw NativeError(.closing, "Session is closing") }
      return try await withCheckedThrowingContinuation { continuation in
        do {
          var operation = abi(tidyvnc_operation.self)
          try checked { send(&operation, $0) }
          if advancesGeneration {
            generation = operation.generation; remoteResize.beginAttempt(generation:generation,policy:resizePolicy); frame = nil; cursor = nil; prompt = nil; deliveryError = nil
            clipboard = nil; if desktopFocusOwner != nil { desktopFocusOwner = nil }; isFocused = false
          }
          pending[token] = Pending(operation: NativeOperation(id: operation.operation, generation: operation.generation), continuation: continuation)
        } catch { continuation.resume(throwing: error) }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel(token) }
    }
  }
  private func cancel(_ token: UUID) {
    guard var request = pending[token] else { return }
    request.cancelled = true; pending[token] = request
    // Cancellation is best effort after admission. Even if native work already
    // committed, consume its one completion before resuming the cancelled await.
    _ = tidyvnc_session_cancel_operation(handle.raw, request.operation.generation, request.operation.id, nil)
  }
  private func complete(_ event: tidyvnc_event) {
    guard let token = pending.first(where: { $0.value.operation.id == event.operation && $0.value.operation.generation == event.snapshot.generation })?.key,
          let request = pending.removeValue(forKey: token) else { return }
    if request.cancelled { request.continuation.resume(throwing: CancellationError()); return }
    let current = NativeSnapshot(event.snapshot)
    if event.result == UInt32(TIDYVNC_OPERATION_SUCCEEDED) {
      request.continuation.resume(returning: NativeCompletion(operation: request.operation, snapshot: current))
    } else {
      request.continuation.resume(throwing: NativeCommandFailure(operation: request.operation,
        result: NativeCommandFailure.Result(rawValue: event.result) ?? .failed,
        reason: NativeCommandFailure.Reason(rawValue: event.failure) ?? .none, nativeResult: event.native_result, snapshot: current))
    }
  }
  private func receive(subscription id: UInt64, generation deliveredGeneration: UInt64) {
    guard !isClosing, subscription?.raw == id, deliveredGeneration == generation else { return }
    do {
      var event = abi(tidyvnc_event.self)
      var consumed = 0
      while consumed < 128 {
        guard try checked(allowing: [.ok, .noChange], { tidyvnc_session_take_event(handle.raw, &event, $0) }) == .ok else { break }
        consumed += 1
        if event.kind == UInt32(TIDYVNC_EVENT_COMPLETION) { complete(event) }
      }
      // A large configured event queue or a fast producer must not monopolize
      // MainActor. Continue next turn even if no new producer wake arrives.
      if consumed == 128 { delivery?.signal(subscription: id, generation: generation) }
      var current = abi(tidyvnc_snapshot.self)
      try checked { tidyvnc_session_snapshot(handle.raw, &current, $0) }
      if current.generation == generation {
        var info = abi(tidyvnc_connection_info.self)
        let status = try checked(allowing: [.ok, .notConnected, .stale]) {
          tidyvnc_session_information(handle.raw, generation, &info, $0)
        }
        let next = status == .ok ? NativeConnectionInformation(info) : nil
        let value = NativeSnapshot(status == .ok ? info.snapshot : current, information: next)
        if snapshot != value { snapshot = value }
        if snapshot.state != .authenticating && prompt != nil { prompt = nil }
      }
      var view = abi(tidyvnc_view_update.self)
      if try checked(allowing: [.ok, .noChange], { tidyvnc_session_take_view(handle.raw, &view, $0) }) == .ok {
        // Own both handles before any fallible conversion. Stale data is released
        // here, never installed in the current generation's observable state.
        let frameOwner = view.frame == 0 ? nil : NativeHandle(adopting: view.frame)
        let cursorOwner = view.cursor == 0 ? nil : NativeHandle(adopting: view.cursor)
        if view.generation == generation {
          if view.frame_changed != 0 {
            let previous = frame?.sequence ?? 0
            frame = try frameOwner.map { try NativeImage(owning: $0, previousSequence: previous,
              damage: NativePixelRect(x: view.damage_x, y: view.damage_y, width: view.damage_width, height: view.damage_height),
              streamID: imageStream) }
          }
          if view.cursor_changed != 0 { cursor = try cursorOwner.map { try NativeImage(owning: $0) } }
        }
      }
      var rawPrompt: UInt64 = 0
      if try checked(allowing: [.ok, .noChange], { tidyvnc_session_take_prompt(handle.raw, &rawPrompt, $0) }) == .ok {
        let value = try NativePrompt(adopting: rawPrompt)
        if value.generation == generation { prompt = value }
      }
      var clipboardUpdate = abi(tidyvnc_clipboard_update.self)
      if try checked(allowing: [.ok, .noChange], { tidyvnc_session_take_clipboard(handle.raw, &clipboardUpdate, $0) }) == .ok {
        let value = try NativeClipboardUpdate(clipboardUpdate)
        // Invalidations need not carry a route. The current snapshot and wake
        // generation already guard publication; native writes recheck the token.
        if value.kind == .invalidated || value.route.generation == generation { clipboard = value }
      }
      if [.closed, .failed].contains(snapshot.state) {
        frame = nil; cursor = nil; prompt = nil
        clipboard = nil; if desktopFocusOwner != nil { desktopFocusOwner = nil }; isFocused = false
      }
    } catch {
      deliveryError = error as? NativeError ?? NativeError(.internalFailure, "Native delivery failed")
      // A consumer failure must not strand an async operation whose event was
      // consumed or lose bounded mailbox progress indefinitely.
      _ = beginClose()
    }
  }

  public func setFocused(_ focused: Bool) throws {
    try checked { tidyvnc_session_focus(handle.raw, generation, focused ? 1 : 0, $0) }
    if !focused && desktopFocusOwner != nil { desktopFocusOwner = nil }
    if isFocused != focused { isFocused = focused }
  }
  // A losing/destroyed surface may release only its own scoped focus interval.
  // Live view callbacks can also revoke explicitly unscoped legacy focus; delayed
  // destruction cannot. Native focus acquisition always installs an owner. Moving
  // focus between surfaces drains held remote input before the new surface gains
  // it. The false/true interval also invalidates pending clipboard routing.
  func setDesktopFocused(_ focused: Bool, owner: UUID, releaseUnowned: Bool = false) throws {
    if !focused {
      if desktopFocusOwner == owner || (releaseUnowned && desktopFocusOwner == nil && isFocused) { try setFocused(false) }
      return
    }
    guard !isClosing else { throw NativeError(.closing,"Session is closing") }
    if desktopFocusOwner != owner {
      if isFocused { try setFocused(false) }
      desktopFocusOwner = owner
    }
    do { try setFocused(true) }
    catch { if desktopFocusOwner == owner { desktopFocusOwner = nil }; throw error }
  }
  public func setViewOnly(_ enabled: Bool) throws {
    try checked { tidyvnc_session_view_only(handle.raw, enabled ? 1 : 0, $0) }
    if isViewOnly != enabled { viewOnlySource = .session; isViewOnly = enabled }
  }
  public func sendKey(id: UInt32, keysym: UInt32, keycode: UInt32 = 0, down: Bool) throws {
    try checked { tidyvnc_session_key(handle.raw, generation, id, keysym, keycode, down ? 1 : 0, $0) }
  }
  public func releaseInput() throws { try checked { tidyvnc_session_release_input(handle.raw, generation, $0) } }
  public func setInputPolicy(viewOnly: Bool, emulateMiddle: Bool) throws {
    try checked { tidyvnc_session_input_policy(handle.raw, viewOnly ? 1 : 0, emulateMiddle ? 1 : 0, $0) }
    if isViewOnly != viewOnly { viewOnlySource = .session; isViewOnly = viewOnly }
    if emulatesMiddleButton != emulateMiddle { middleButtonSource = .session; emulatesMiddleButton = emulateMiddle }
  }
  public func sendPointer(x: Int32, y: Int32, buttons: UInt32) throws {
    try checked { tidyvnc_session_pointer(handle.raw, generation, x, y, buttons, $0) }
  }
  // Arrays are caller-owned mutable UTF-8, not immutable String passwords. The
  // C boundary wipes the submitted storage; Swift/runtime copies are not erased.
  public func replyCredentials(to request: NativePrompt, username: inout [UInt8], password: inout [UInt8]) throws {
    defer {
      for index in username.indices { username[index] = 0 }
      for index in password.indices { password[index] = 0 }
    }
    _ = try username.withUnsafeMutableBufferPointer { user in
      try password.withUnsafeMutableBufferPointer { secret in
        try checked { tidyvnc_session_reply_credentials(handle.raw, request.id, request.generation,
          tidyvnc_mutable_bytes(data: user.baseAddress, length: UInt64(user.count)),
          tidyvnc_mutable_bytes(data: secret.baseAddress, length: UInt64(secret.count)), $0) }
      }
    }
    if prompt?.id == request.id { prompt = nil }
  }
  // Captured legacy environment bytes need not be UTF-8. The typed user-facing
  // credential API above retains its UTF-8 contract; neither path persists input.
  public func replyCredentialBytes(to request: NativePrompt, username: inout [UInt8], password: inout [UInt8]) throws {
    defer {
      for index in username.indices { username[index] = 0 }
      for index in password.indices { password[index] = 0 }
    }
    _ = try username.withUnsafeMutableBufferPointer { user in
      try password.withUnsafeMutableBufferPointer { secret in
        try checked { tidyvnc_session_reply_credential_bytes(handle.raw,request.id,request.generation,
          tidyvnc_mutable_bytes(data:user.baseAddress,length:UInt64(user.count)),
          tidyvnc_mutable_bytes(data:secret.baseAddress,length:UInt64(secret.count)),$0) }
      }
    }
    if prompt?.id == request.id { prompt = nil }
  }
  // The shared core decodes one legacy block and verifies a current password-
  // only prompt. No plaintext Swift String or durable retention is introduced.
  public func replyPasswordFile(to request: NativePrompt, block: inout [UInt8]) throws {
    defer { for index in block.indices { block[index] = 0 } }
    _ = try block.withUnsafeMutableBufferPointer { bytes in
      try checked { tidyvnc_session_reply_password_file(handle.raw,request.id,request.generation,
        tidyvnc_mutable_bytes(data:bytes.baseAddress,length:UInt64(bytes.count)),$0) }
    }
    if prompt?.id == request.id { prompt = nil }
  }
  public func replyTrust(to request: NativePrompt, allowed: Bool) throws {
    try checked { tidyvnc_session_reply_trust(handle.raw, request.id, request.generation, allowed ? 1 : 0, $0) }
    if prompt?.id == request.id { prompt = nil }
  }
  func beginClose() -> Task<Void, Error> {
    if let closeTask { return closeTask }
    isClosing = true; delivery?.invalidate(); presentations.stop()
    let owner = handle, subscribed = subscription, context = delivery
    let rendering = presentations, resizing = remoteResize
    resizing.stop()
    // Invalidate observable routing before any suspension or native cancellation.
    prompt = nil; frame = nil; cursor = nil; clipboard = nil; if desktopFocusOwner != nil { desktopFocusOwner = nil }; isFocused = false
    let operations = pending; pending.removeAll()
    for request in operations.values { request.continuation.resume(throwing: NativeError(.closing, "Session closed")) }
    _ = tidyvnc_session_close(owner.raw, nil)
    if let subscribed { _ = tidyvnc_subscription_unsubscribe(subscribed.raw, nil) }
    var closing = abi(tidyvnc_snapshot.self)
    if tidyvnc_session_snapshot(owner.raw, &closing, nil) == UInt32(TIDYVNC_OK) {
      snapshot = NativeSnapshot(closing, stateOverride: .disconnecting)
    }
    let task = Task { [weak self] in
      var failure: (any Error)?
      do { try await waitForNativeDrain(owner, .session) } catch { failure = error }
      if let subscribed {
        do { try await waitForNativeDrain(subscribed, .subscription) } catch { if failure == nil { failure = error } }
      }
      await context?.drain(); await resizing.close(); await rendering.close()
      var final = abi(tidyvnc_snapshot.self)
      if tidyvnc_session_snapshot(owner.raw, &final, nil) == UInt32(TIDYVNC_OK) { self?.snapshot = NativeSnapshot(final) }
      if let failure { throw failure }
    }
    closeTask = task; return task
  }
  public func close() async throws { try await beginClose().value }
  deinit {
    let rendering = presentations
    Task { @MainActor in await rendering.close() }
    delivery?.invalidate()
    if let subscription { _ = tidyvnc_subscription_unsubscribe(subscription.raw, nil) }
    _ = tidyvnc_session_close(handle.raw, nil)
    for request in pending.values { request.continuation.resume(throwing: NativeError(.closing, "Session released")) }
  }
}
