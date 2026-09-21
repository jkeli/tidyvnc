// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import TidyVNC

extension tidyvnc_message_limits: ABIValue {}
public enum NativeMessageLimits {
  public static func defaultMaxCutText() throws -> UInt32 {
    var value = abi(tidyvnc_message_limits.self)
    try checked { tidyvnc_message_limits_init(&value,$0) }
    return value.max_cut_text
  }
}
