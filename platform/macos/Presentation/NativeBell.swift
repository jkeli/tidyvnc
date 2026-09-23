// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit

// Host contract for the remote server bell, so tests can observe it without
// playing sound. Called on MainActor at most once per session delivery turn.
@MainActor public protocol NativeBellSounding: AnyObject {
  func ring()
}
// Production bell: the user's configured system alert sound, as FLTK's fl_beep.
@MainActor public final class NativeSystemBell: NativeBellSounding {
  public init() {}
  public func ring() { NSSound.beep() }
}
