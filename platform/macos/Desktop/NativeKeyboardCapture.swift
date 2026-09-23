// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import NativeKeyMap

// Distinguishes the missing Accessibility grant (user-actionable) from a tap that
// could not be created or enabled even though the process is trusted.
enum NativeKeyboardCaptureStart: Equatable { case active, accessibilityRequired, failed }
@MainActor protocol NativeKeyboardCapturing: AnyObject {
  var isActive: Bool { get }
  func start() -> NativeKeyboardCaptureStart
  func stop()
}
@MainActor final class NativeKeyboardCapture: NativeKeyboardCapturing {
  // The C tap callback has no context pointer or host state. Disposal disables
  // and invalidates its main-run-loop source before releasing the resources.
  private final class Resource {
    let raw: UnsafeMutableRawPointer
    init(_ raw: UnsafeMutableRawPointer) { self.raw = raw }
    deinit { native_macos_keyboard_capture_destroy(raw) }
  }
  private var resource: Resource?
  var isActive: Bool { resource.map { native_macos_keyboard_capture_active($0.raw) != 0 } ?? false }
  func start() -> NativeKeyboardCaptureStart {
    if isActive { return .active }
    resource = nil
    guard native_macos_keyboard_capture_trusted() != 0 else { return .accessibilityRequired }
    guard let raw = native_macos_keyboard_capture_create() else { return .failed }
    resource = Resource(raw)
    guard isActive else { resource = nil; return .failed }
    return .active
  }
  func stop() { resource = nil }
}
