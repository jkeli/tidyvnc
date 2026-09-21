// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC

@MainActor
public final class NativeRuntime {
  let handle: NativeHandle
  private struct WeakSession { weak var value: NativeSession? }
  private var sessions: [WeakSession] = []
  private struct WeakListener { weak var value: NativeListener? }
  private var listeners: [WeakListener] = []
  private var shutdownTask: Task<Void, Error>?
  public init(sessionCapacity: UInt32 = 16) throws {
    var options = abi(tidyvnc_runtime_options.self)
    try checked { tidyvnc_runtime_options_init(&options, $0) }
    options.session_capacity = sessionCapacity
    options.required_features = UInt64(TIDYVNC_FEATURE_RUNTIME | TIDYVNC_FEATURE_TCP_UNIX_CONNECT |
      TIDYVNC_FEATURE_EVENT_POLL | TIDYVNC_FEATURE_IMAGES | TIDYVNC_FEATURE_INPUT |
      TIDYVNC_FEATURE_PROMPTS | TIDYVNC_FEATURE_CALLBACKS | TIDYVNC_FEATURE_GEOMETRY | TIDYVNC_FEATURE_CLIPBOARD | TIDYVNC_FEATURE_ENCODING | TIDYVNC_FEATURE_ENDPOINT_VALIDATION | TIDYVNC_FEATURE_SCALING | TIDYVNC_FEATURE_TILE_RENDERER | TIDYVNC_FEATURE_DAMAGE_GEOMETRY | TIDYVNC_FEATURE_CURSOR_RENDERER | TIDYVNC_FEATURE_INPUT_POLICY | TIDYVNC_FEATURE_SHORTCUTS | TIDYVNC_FEATURE_INPUT_RELEASE | TIDYVNC_FEATURE_CONNECTION_INFO | TIDYVNC_FEATURE_ENDPOINT_IDENTITY | TIDYVNC_FEATURE_PROMPT_SECURITY | TIDYVNC_FEATURE_CERTIFICATE_POLICY | TIDYVNC_FEATURE_HOST_KEY_ENCODING | TIDYVNC_FEATURE_REQUIRED_TLS_FILES | TIDYVNC_FEATURE_SECURITY_SELECTION | TIDYVNC_FEATURE_TLS_PRIORITY_VALIDATION | TIDYVNC_FEATURE_SECURITY_RECONFIGURATION | TIDYVNC_FEATURE_SHARED_SESSION | TIDYVNC_FEATURE_DESKTOP_LAYOUT | TIDYVNC_FEATURE_DISPLAY_LAYOUT) | UInt64(TIDYVNC_FEATURE_CANVAS_GEOMETRY) | UInt64(TIDYVNC_FEATURE_INPUT_TIMING) | UInt64(TIDYVNC_FEATURE_MESSAGE_LIMITS) | UInt64(TIDYVNC_FEATURE_WINDOW_GEOMETRY)
    var raw: UInt64 = 0; try checked { tidyvnc_runtime_create(&options, &raw, $0) }
    handle = NativeHandle(adopting: raw)
  }
  public func makeSession(configuration: NativeSessionConfiguration = .init()) throws -> NativeSession {
    guard shutdownTask == nil else { throw NativeError(.closing, "Runtime is shutting down") }
    let session = try NativeSession(runtime: self, configuration: configuration)
    sessions.removeAll { $0.value == nil }; sessions.append(WeakSession(value: session)); return session
  }
  // A session owns its runtime; this registry is weak and cannot create a cycle.
  public func makeListener(options: NativeListenOptions = .init()) throws -> NativeListener {
    guard shutdownTask == nil else { throw NativeError(.closing,"Runtime is shutting down") }
    let listener = try NativeListener(runtime:self,options:options)
    listeners.removeAll { $0.value == nil }; listeners.append(WeakListener(value:listener)); return listener
  }
  // Begin closing every session before awaiting any one of them.
  public func shutdown() async throws {
    if let shutdownTask { return try await shutdownTask.value }
    let closing = sessions.compactMap(\.value)
    let tasks = listeners.compactMap(\.value).map { $0.beginClose() } + closing.map { $0.beginClose() }
    let owner = handle
    let task = Task {
      try checked { tidyvnc_runtime_shutdown(owner.raw, $0) }
      var failure: (any Error)?
      for task in tasks { do { try await task.value } catch { if failure == nil { failure = error } } }
      do { try await waitForNativeDrain(owner, .runtime) } catch { if failure == nil { failure = error } }
      if let failure { throw failure }
    }
    shutdownTask = task; try await task.value
  }
  deinit { _ = tidyvnc_runtime_shutdown(handle.raw, nil) }
}
