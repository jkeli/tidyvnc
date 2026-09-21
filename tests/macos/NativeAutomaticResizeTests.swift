// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message:message) } }
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<2500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"automatic resize timeout")
}
func viewport(_ width: Double, _ height: Double = 2, scale: Double = 1, unscaled: Bool = true, device: Bool = false, available: Bool = true) -> NativeResizeViewport {
  .init(width:width,height:height,scale:scale,unscaled:unscaled,devicePixels:device,available:available)
}
@MainActor func quiet(_ peer: UnsafeMutableRawPointer, _ count: UInt32) async throws {
  try await Task.sleep(for:.milliseconds(220)); try check(native_resize_peer_count(peer) == count,"unexpected automatic request")
}
@MainActor func run() async throws {
  let runtime = try NativeRuntime(), session = try runtime.makeSession()
  let peer = native_resize_peer_create()!, owner = UUID(), otherPeer = native_resize_peer_create()!
  defer { native_resize_peer_destroy(peer); native_resize_peer_destroy(otherPeer) }
  let other = try runtime.makeSession()
  other.remoteResize.update(owner:owner,viewport:viewport(35))
  _ = try await other.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(otherPeer))")
  try await until { other.snapshot.width == 35 }
  let coordinator = session.remoteResize
  coordinator.update(owner:owner,viewport:viewport(3,unscaled:false))
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peer))")
  try await until { session.snapshot.supportsResize }; try await quiet(peer,0)
  for width in 3...12 { coordinator.update(owner:owner,viewport:viewport(Double(width))) }
  try await until { session.snapshot.width == 12 }; try await quiet(peer,1)
  native_resize_peer_reply(peer,UInt32.max)
  coordinator.update(owner:owner,viewport:viewport(13)); try await until { native_resize_peer_count(peer) == 2 }
  coordinator.update(owner:owner,viewport:viewport(14)); coordinator.update(owner:owner,viewport:viewport(15))
  try await quiet(peer,2)
  try session.setResizePolicy(.init(enabled:false),expected:session.resizePolicyRevision)
  try await quiet(peer,2)
  try session.setResizePolicy(.init(),expected:session.resizePolicyRevision)
  native_resize_peer_reply(peer,0)
  try await until { session.snapshot.width == 15 }; try await quiet(peer,3)
  try session.setViewOnly(true); coordinator.update(owner:owner,viewport:viewport(16)); try await quiet(peer,3)
  try session.setViewOnly(false); try await until { session.snapshot.width == 16 }
  try session.setResizePolicy(.init(enabled:false),expected:session.resizePolicyRevision)
  coordinator.update(owner:owner,viewport:viewport(17)); try await quiet(peer,4)
  try session.setResizePolicy(.init(),expected:session.resizePolicyRevision); try await until { session.snapshot.width == 17 }
  coordinator.update(owner:owner,viewport:viewport(10.9,2.9,scale:2,device:true)); try await until { session.snapshot.width == 21 && session.snapshot.height == 5 }
  coordinator.update(owner:owner,viewport:viewport(.infinity)); try await quiet(peer,6)
  coordinator.update(owner:owner,viewport:viewport(70000)); try await quiet(peer,6)
  coordinator.update(owner:owner,viewport:viewport(18,available:false)); try await quiet(peer,6)
  coordinator.update(owner:owner,viewport:viewport(18)); try await until { session.snapshot.width == 18 }
  let manual = try NativeRemoteLayout(width:30,height:2,screens:[.init(id:7,x:0,y:0,width:30,height:2)])
  _ = try await session.requestDesktopLayout(manual,expectedGeneration:session.generation); try await quiet(peer,8)
  try check(session.snapshot.width == 30,"manual size survives until viewport changes")
  coordinator.update(owner:owner,viewport:viewport(19)); try await until { session.snapshot.width == 19 }
  native_resize_peer_reply(peer,1); coordinator.update(owner:owner,viewport:viewport(20))
  try await until { coordinator.message != nil }; try await quiet(peer,10)
  let replacement = UUID(); coordinator.attach(owner:replacement)
  native_resize_peer_reply(peer,0); coordinator.update(owner:replacement,viewport:viewport(22))
  coordinator.update(owner:owner,viewport:viewport(23)); coordinator.detach(owner:owner)
  try await until { session.snapshot.width == 22 }; try await quiet(peer,11)
  coordinator.update(owner:replacement,viewport:viewport(24)); coordinator.detach(owner:replacement)
  try await quiet(peer,11)
  coordinator.attach(owner:replacement); coordinator.update(owner:replacement,viewport:viewport(25))
  native_resize_peer_reply(peer,UInt32.max); try await until { native_resize_peer_count(peer) == 12 }
  try check(other.snapshot.width == 35 && native_resize_peer_count(otherPeer) == 1,"automatic policies and view identities are session scoped")
  try await session.close(); try await other.close(); try await runtime.shutdown()
  print("PASS coalescing, pending follow-up, eligibility, pixel units, manual override, rejection, view replacement and close")
}
@MainActor func initialAndView() async throws {
  _ = NSApplication.shared
  let runtime = try NativeRuntime()
  var config = NativeSessionConfiguration(); config.resizePolicy = try .init(initialSize:"0008x0004")
  try check(config.resizePolicy.initialSize == "8x4","canonical initial dimensions")
  for text in ["0x2","65536x1","2X3","2x3extra"," 2x3","2x","1.5x3"] {
    do { _ = try NativeRemoteResizePolicy(initialSize:text); throw Failure(message:"invalid initial dimensions") } catch is NativeError {}
  }
  let session = try runtime.makeSession(configuration:config), owner = UUID()
  let first = native_resize_peer_create()!, second = native_resize_peer_create()!
  defer { native_resize_peer_destroy(first); native_resize_peer_destroy(second) }
  session.remoteResize.update(owner:owner,viewport:viewport(10,6,unscaled:false))
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(first))")
  try await until { session.snapshot.width == 8 }; try await quiet(first,1)
  // Live initial-size edits are reserved for the next accepted connection.
  let draft = NativeRemoteResizePolicyDraft(session:session), stale = NativeRemoteResizePolicyDraft(session:session)
  draft.initialSize = "9x5"; try check(draft.apply(),"live policy applied")
  stale.enabled = false; try check(!stale.canApply && !stale.apply(),"stale policy revision refused")
  try await quiet(first,1)
  session.remoteResize.update(owner:owner,viewport:viewport(10,6))
  try await until { session.snapshot.width == 10 }; try await quiet(first,2)
  _ = try await session.disconnect()
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(second))")
  try await until { session.snapshot.width == 9 }; try await quiet(second,1)
  let window = NSWindow(contentRect:NSRect(x:0,y:0,width:40,height:30),styleMask:.borderless,backing:.buffered,defer:false)
  window.isReleasedWhenClosed = false
  let view = NativeDesktopView(frame:window.contentLayoutRect); view.scaling = "100"
  window.contentView = view; view.bind(session); view.layout()
  try await until { session.snapshot.width == 40 && session.snapshot.height == 30 }
  NotificationCenter.default.post(name:NSWindow.willEnterFullScreenNotification,object:window)
  view.setFrameSize(NSSize(width:42,height:31)); view.layout(); try await quiet(second,2)
  NotificationCenter.default.post(name:NSWindow.didEnterFullScreenNotification,object:window)
  try await until { session.snapshot.width == 42 }
  view.isHidden = true; view.layout(); view.setFrameSize(NSSize(width:43,height:32)); view.layout(); try await quiet(second,3)
  view.isHidden = false; view.layout(); try await until { session.snapshot.width == 43 }
  view.resizeTransitionTimeout = .milliseconds(50)
  NotificationCenter.default.post(name:NSWindow.willExitFullScreenNotification,object:window)
  view.setFrameSize(NSSize(width:44,height:33)); view.layout()
  try await until { session.snapshot.width == 44 }
  view.detach(); window.contentView = nil; window.close()
  try await session.close(); try await runtime.shutdown()
  print("PASS initial-size snapshot/reconnect, policy CAS and AppKit viewport/fullscreen/hidden integration")
}
@MainActor func failedViewBinding() async throws {
  let runtime = try NativeRuntime(), session = try runtime.makeSession(), owner = UUID()
  let peer = native_resize_peer_create()!; defer { native_resize_peer_destroy(peer) }
  session.remoteResize.update(owner:owner,viewport:viewport(31))
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peer))")
  try await until { session.snapshot.width == 31 }
  session.presentations.stop() // Force replacement-view acquisition to fail.
  let window = NSWindow(contentRect:NSRect(x:0,y:0,width:40,height:30),styleMask:.borderless,backing:.buffered,defer:false)
  window.isReleasedWhenClosed = false
  let view = NativeDesktopView(frame:window.contentLayoutRect); window.contentView = view
  var failed = false; view.onError = { _ in failed = true }; view.bind(session)
  try check(failed,"failed renderer acquisition fixture")
  session.remoteResize.update(owner:owner,viewport:viewport(32))
  try await until { session.snapshot.width == 32 }
  view.detach(); window.contentView = nil; window.close()
  try await session.close(); try await runtime.shutdown()
  print("PASS failed replacement view does not steal automatic resize ownership")
}
@main struct Main {
  static func main() async {
    do { try await run(); try await initialAndView(); try await failedViewBinding() }
    catch { print("FAIL \(error)"); exit(1) }
  }
}
