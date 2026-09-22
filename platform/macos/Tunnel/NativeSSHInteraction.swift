// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Combine
import Foundation

public struct NativeSSHAuthentication: Sendable {
  public let helper: URL
  public let interaction: NativeSSHInteraction
  public init(helper: URL, interaction: NativeSSHInteraction) {
    self.helper = helper; self.interaction = interaction
  }
}

public struct NativeSSHQuestion: Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public enum Kind: UInt8, Sendable { case response = 1, permission = 2, notification = 3, hostKey = 4 }
  public let id = UUID()
  public let gateway: NativeSSHGateway
  public let endpoint: String
  public let kind: Kind
  // OpenSSH/remote text is displayed as plain, untrusted text. It never chooses
  // an endpoint, credential key, command, or automatic affirmative response.
  public let text: String
  public let hostKey: NativeSSHHostKey?
  init(gateway: NativeSSHGateway, endpoint: String, kind: Kind, text: String, hostKey: NativeSSHHostKey? = nil) {
    self.gateway = gateway; self.endpoint = endpoint; self.kind = kind; self.text = text; self.hostKey = hostKey
  }
  public var description: String { "NativeSSHQuestion(<redacted>)" }
  public var debugDescription: String { description }
}

@MainActor public final class NativeSSHInteraction: ObservableObject {
  @Published public private(set) var question: NativeSSHQuestion?
  private var pending: CheckedContinuation<NativeCredentialSecret?,Never>?
  private var stopped = false
  public init() {}
  public func ask(_ question: NativeSSHQuestion) async -> NativeCredentialSecret? {
    guard !stopped, pending == nil, !Task.isCancelled else { return nil }
    return await withTaskCancellationHandler {
      guard !Task.isCancelled else { return nil }
      return await withCheckedContinuation { continuation in
        pending = continuation; self.question = question
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel(question.id) }
    }
  }
  // Consume caller bytes on every outcome. SSH reads at most 1023 bytes and
  // terminates on CR/LF; reject values it would silently truncate.
  public func respond(_ id: UUID, bytes: inout [UInt8]) throws {
    defer { bytes.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base,$0.count,0,$0.count) } } }
    guard question?.id == id, pending != nil, !stopped else { throw NativeError(.stale,"Inactive SSH request") }
    guard bytes.count <= 1023, !bytes.contains(0), !bytes.contains(10), !bytes.contains(13) else {
      throw NativeTunnelError.invalidRequest
    }
    if question?.kind == .hostKey {
      guard let key = question?.hostKey, bytes.elementsEqual(key.fingerprint.utf8) else { throw NativeTunnelError.invalidRequest }
    }
    let secret = try NativeCredentialSecret(consuming:&bytes)
    let continuation = pending; pending = nil; question = nil
    continuation?.resume(returning:secret)
  }
  public func cancel(_ id: UUID) {
    guard question?.id == id else { return }
    let continuation = pending; pending = nil; question = nil; continuation?.resume(returning:nil)
  }
  public func cancel() { if let question { cancel(question.id) } }
  public func stop() { stopped = true; cancel() }
  deinit { pending?.resume(returning:nil) }
}
