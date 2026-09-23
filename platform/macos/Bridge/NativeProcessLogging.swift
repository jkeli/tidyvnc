// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import TidyVNC
import Foundation

// Process startup policy, deliberately separate from session/defaults/profile
// configuration. Validation is read-only; only the executable entry point starts
// logging, after complete launch preflight and before constructing any runtime.
public enum NativeProcessLogging {
  // Measured local dimensions only. Logging failure must never affect resizing.
  static func viewport(width: Double, height: Double, scale: Double) {
    let values = [width,height,width * scale,height * scale].map { floor($0) }
    guard scale.isFinite, scale > 0,
          values.allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= Double(Int32.max) }) else { return }
    _ = tidyvnc_logging_viewport(UInt32(values[0]),UInt32(values[1]),UInt32(values[2]),UInt32(values[3]),nil)
  }
  public static let defaultPolicy = "*:stderr:30"
  public static func validate(_ policy: String) throws {
    try policy.utf8CString.withUnsafeBufferPointer { buffer in
      let bytes = tidyvnc_bytes(data:UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to:UInt8.self),
                                length:UInt64(buffer.count-1))
      try checked { tidyvnc_logging_validate(bytes,$0) }
    }
  }
  public static func selection(_ options: NativeInvocationOptions) throws -> String {
    var selected = defaultPolicy
    for field in options.assignments where field.name == "Log" {
      try validate(field)
      selected = field.value
    }
    return selected
  }
  static func validate(_ field: NativeInvocationAssignment) throws {
    do { try validate(field.value) }
    catch {
      let reason: NativeInvocationResolutionFailure.Reason = (error as? NativeError)?.status == .unsupported ? .unsupportedOption : .invalidValue
      throw NativeInvocationResolutionFailure(reason:reason,argument:field.argument)
    }
  }
  public static func start(_ options: NativeInvocationOptions) throws {
    let policy = try selection(options)
    try policy.utf8CString.withUnsafeBufferPointer { buffer in
      let bytes = tidyvnc_bytes(data:UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to:UInt8.self),
                                length:UInt64(buffer.count-1))
      try checked { tidyvnc_logging_configure(bytes,$0) }
    }
  }
}
