// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import TidyVNC

extension tidyvnc_input_timing: ABIValue {}
public enum NativePointerTiming {
  public static func defaultMilliseconds() throws -> UInt32 {
    var value = abi(tidyvnc_input_timing.self)
    try checked { tidyvnc_input_timing_init(&value,$0) }
    return value.pointer_interval_ms
  }
}
