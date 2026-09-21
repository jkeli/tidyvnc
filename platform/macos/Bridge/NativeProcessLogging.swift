// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import TidyVNC

// Process startup policy, deliberately separate from session/defaults/profile
// configuration. Validation is read-only; only the executable entry point starts
// logging, after complete launch preflight and before constructing any runtime.
public enum NativeProcessLogging {
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
