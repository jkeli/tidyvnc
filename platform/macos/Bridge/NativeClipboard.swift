// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC

extension tidyvnc_clipboard_route: ABIValue {}
extension tidyvnc_clipboard_update: ABIValue {}
extension tidyvnc_clipboard_info: ABIValue {}
public struct NativeClipboardRoute: Sendable, Equatable {
  public let sessionIdentity: UInt64
  public let generation: UInt64, focusRevision: UInt64, policyRevision: UInt64
  init(_ value: tidyvnc_clipboard_route) {
    sessionIdentity = value.session
    generation = value.generation; focusRevision = value.focus_revision; policyRevision = value.policy_revision
  }
  var abiValue: tidyvnc_clipboard_route {
    var value = abi(tidyvnc_clipboard_route.self)
    value.session = sessionIdentity
    value.generation = generation; value.focus_revision = focusRevision; value.policy_revision = policyRevision
    return value
  }
}
// Immutable String plus retained thread-safe C lease; no borrowed span escapes.
// Keeping the handle preserves the shared core byte budget and remote provenance.
public final class NativeClipboardText: @unchecked Sendable {
  let handle: NativeHandle
  public let text: String
  public let fromRemote: Bool
  public let route: NativeClipboardRoute
  init(adopting raw: UInt64) throws {
    let owner = NativeHandle(adopting: raw)
    var value = abi(tidyvnc_clipboard_info.self)
    try checked { tidyvnc_clipboard_get(owner.raw, &value, $0) }
    guard let text = String(data: try copyBytes(value.text), encoding: .utf8) else {
      throw NativeError(.invalidArgument, "Invalid clipboard text encoding")
    }
    self.text = text; fromRemote = value.from_remote != 0; route = NativeClipboardRoute(value.route); handle = owner
  }
}
public struct NativeClipboardUpdate: Sendable {
  public enum Kind: UInt32, Sendable { case offered = 1, text, unavailable, invalidated, rejected }
  public let kind: Kind
  public let result: NativeStatus
  public let sequence: UInt64
  public let route: NativeClipboardRoute
  public let text: NativeClipboardText?
  init(_ value: tidyvnc_clipboard_update) throws {
    // Adopt before interpreting metadata so a conversion failure cannot leak.
    text = value.text == 0 ? nil : try NativeClipboardText(adopting: value.text)
    kind = Kind(rawValue: value.kind) ?? .rejected
    result = NativeStatus(rawValue: value.result) ?? .internalFailure
    sequence = value.sequence; route = NativeClipboardRoute(value.route)
  }
}
