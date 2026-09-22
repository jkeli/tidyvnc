// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeAskpass

private final class AskpassResponse: @unchecked Sendable {
  let ready = DispatchSemaphore(value:0)
  private let lock = NSLock()
  private var secret: NativeCredentialSecret?
  func finish(_ value: NativeCredentialSecret?) { lock.withLock { secret = value }; ready.signal() }
  func take() -> NativeCredentialSecret? { lock.withLock { defer { secret = nil }; return secret } }
}

// Blocking local socket reads run on one utility worker. close only requests
// shutdown and awaits its drain; no socket read or worker join runs on MainActor.
final class NativeSSHAskpass: @unchecked Sendable {
  typealias Handler = @Sendable (NativeSSHQuestion) async -> NativeCredentialSecret?
  private let lock = NSLock()
  private let request: NativeSSHTunnelRequest
  private let handler: Handler
  private let hostKeyLookupName: String
  private var server: OpaquePointer?
  private var pending: Task<Void,Never>?
  private var stopped = false, finished = false
  private var waiters: [CheckedContinuation<Void,Never>] = []
  init(directory: String, request: NativeSSHTunnelRequest, hostKeyLookupName: String? = nil, handler: @escaping Handler) throws {
    guard let server = directory.withCString({ tidy_askpass_open($0) }) else { throw NativeTunnelError.privateSocketUnavailable }
    self.server = server; self.request = request; self.handler = handler
    self.hostKeyLookupName = hostKeyLookupName ?? (request.gatewayPort == 22 ? request.gatewayHost : "[\(request.gatewayHost)]:\(request.gatewayPort)")
    DispatchQueue(label:"io.github.jkeli.tidyvnc.ssh-askpass",qos:.utility).async { [self] in run() }
  }
  func stop() {
    let pending = lock.withLock {
      stopped = true
      if let server { tidy_askpass_cancel(server) }
      return self.pending
    }
    pending?.cancel()
  }
  func close() async {
    stop()
    await withCheckedContinuation { continuation in
      let done = lock.withLock { if finished { return true }; waiters.append(continuation); return false }
      if done { continuation.resume() }
    }
  }
  private func run() {
    guard let server = lock.withLock({ self.server }) else { return }
    var hostKey: NativeSSHHostKey?
    defer {
      let waiters = lock.withLock {
        tidy_askpass_destroy(server); self.server = nil; finished = true
        let values = self.waiters; self.waiters.removeAll(); return values
      }
      for waiter in waiters { waiter.resume() }
    }
    while true {
      var bytes = [UInt8](repeating:0,count:Int(TIDY_ASKPASS_PROMPT_LIMIT)), length: UInt32 = 0, rawKind: UInt8 = 0
      let result = bytes.withUnsafeMutableBufferPointer { tidy_askpass_receive(server,&rawKind,$0.baseAddress,&length) }
      if result < 0 { return }
      if result == 0 { continue }
      guard let text = String(bytes:bytes.prefix(Int(length)),encoding:.utf8),
            !text.unicodeScalars.contains(where:{ $0.value < 32 && $0.value != 9 && $0.value != 10 }) else {
        _ = tidy_askpass_reply(server,nil,0,0); continue
      }
      if rawKind == 4 {
        hostKey = NativeSSHHostKey(record:text,expectedHostname:hostKeyLookupName)
        // Observation alone neither prompts nor supplies a trusted host key.
        _ = tidy_askpass_reply(server,nil,0,1); continue
      }
      guard var kind = NativeSSHQuestion.Kind(rawValue:rawKind) else { _ = tidy_askpass_reply(server,nil,0,0); continue }
      var reviewedKey: NativeSSHHostKey?
      if text.hasPrefix("The authenticity of host '") {
        guard kind == .response, let hostKey, hostKey.matchesConfirmation(text) else {
          _ = tidy_askpass_reply(server,nil,0,0); continue
        }
        kind = .hostKey; reviewedKey = hostKey
      }
      let question = NativeSSHQuestion(gateway:request.gateway,endpoint:request.endpoint,kind:kind,text:text,hostKey:reviewedKey)
      let response = AskpassResponse(), handler = handler
      let task = Task {
        let value = await handler(question)
        if Task.isCancelled { value?.clear(); response.finish(nil) }
        else { response.finish(value) }
      }
      let stop = lock.withLock { pending = task; return stopped }
      if stop { task.cancel() }
      let deadline = ContinuousClock.now.advanced(by:.seconds(300))
      while response.ready.wait(timeout:.now() + .milliseconds(50)) != .success {
        if tidy_askpass_peer_alive(server) == 0 || ContinuousClock.now >= deadline { task.cancel() }
      }
      let secret = response.take()
      var answer = (try? secret?.copyBytes()) ?? []
      // A cancelled/closed peer gets no response, including when its handler
      // raced a user answer. No secret enters errors, argv, environment or files.
      _ = answer.withUnsafeBufferPointer { tidy_askpass_reply(server,$0.baseAddress,UInt32($0.count),secret == nil ? 0 : 1) }
      answer.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base,$0.count,0,$0.count) } }
      secret?.clear()
      lock.withLock { pending = nil }
    }
  }
}
