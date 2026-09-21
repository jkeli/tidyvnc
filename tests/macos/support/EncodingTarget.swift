// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
@testable import TidyVNCNative

@MainActor final class EncodingTarget: NativeEncodingTarget {
  enum Behavior { case normal, failBefore, failAfter, suspendBefore, suspendAfter }
  var encodingGeneration: UInt64 = 1
  var encodingEditable = true
  var options: NativeEncodingOptions
  var behavior: Behavior = .normal
  private(set) var calls = 0
  private var continuation: CheckedContinuation<Void, Never>?
  var isSuspended: Bool { continuation != nil }
  init() throws {
    options = try NativeEncodingOptions(patch: [.init("AutoSelect", "off"), .init("QualityLevel", "3")], source: .appDefaults)
  }
  func readEncoding() throws -> NativeEncodingOptions { options }
  func submitEncoding(_ value: NativeEncodingOptions, generation: UInt64) async throws {
    calls += 1
    guard encodingEditable, generation == encodingGeneration else { throw NativeError(.stale, "Test generation changed") }
    let mode = behavior
    if mode == .failBefore { throw NativeError(.queueFull, "Test queue full") }
    if mode == .suspendBefore { await withCheckedContinuation { continuation = $0 } }
    guard encodingEditable, generation == encodingGeneration else { throw NativeError(.stale, "Test generation changed") }
    if mode == .suspendBefore { try Task.checkCancellation() }
    options = value
    if mode == .failAfter { throw NativeError(.failed, "Test uncertain outcome") }
    if mode == .suspendAfter { await withCheckedContinuation { continuation = $0 } }
    try Task.checkCancellation()
  }
  func release() { let pending = continuation; continuation = nil; pending?.resume() }
}
