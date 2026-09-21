// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message:message) } }
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<2500 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"condition timeout")
}
func layout(_ width: UInt32) throws -> NativeRemoteLayout {
  try .init(width:width,height:2,screens:[.init(id:7,x:0,y:0,width:width,height:2,flags:9)])
}
@MainActor func expect(_ status: NativeStatus, _ action: () async throws -> Void) async throws {
  do { try await action(); throw Failure(message:"expected status \(status)") }
  catch let error as NativeError { try check(error.status == status,"typed admission failure") }
}
@MainActor func run() async throws {
  let runtime = try NativeRuntime(), session = try runtime.makeSession(), other = try runtime.makeSession()
  let peer = native_resize_peer_create()!, second = native_test_peer_create_pattern(0)!
  defer { native_resize_peer_destroy(peer); native_test_peer_destroy(second) }
  do { _ = try NativeRemoteLayout(width:2,height:2,screens:[]); throw Failure(message:"empty accepted") } catch let error as NativeError { try check(error.status == .invalidArgument,"shared validation") }
  do { _ = try layout(65536); throw Failure(message:"oversized accepted") } catch let error as NativeError { try check(error.status == .invalidArgument,"shared dimension bound") }
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peer))")
  _ = try await other.connect(endpoint:"127.0.0.1::\(native_test_peer_port(second))")
  try await until { session.snapshot.supportsResize }
  let initial = try session.desktopLayout(), generation = session.generation
  try check(initial.layout == (try layout(2)) && initial.snapshot.generation == generation,"owned coherent snapshot preserves IDs and flags")
  let large = try layout(65535)
  do {
    // Width alone fits, but an enormous height exceeds this session's buffer limit.
    let huge = try NativeRemoteLayout(width:large.width,height:65535,screens:[.init(id:7,x:0,y:0,width:large.width,height:65535)])
    try await expect(.resourceLimit) { _ = try await session.requestDesktopLayout(huge,expectedGeneration:generation) }
  }
  try await expect(.stale) { _ = try await session.requestDesktopLayout(layout(3),expectedGeneration:generation+1) }
  try session.setViewOnly(true)
  try await expect(.viewOnly) { _ = try await session.requestDesktopLayout(layout(3),expectedGeneration:generation) }
  try session.setViewOnly(false)
  try await expect(.unsupported) { _ = try await other.requestDesktopLayout(layout(3),expectedGeneration:other.generation) }
  let unsupported = try other.desktopLayout()
  try check(!unsupported.snapshot.supportsResize && unsupported.layout.width == 2,"read geometry from non-resizable server")
  native_resize_peer_reply(peer,UInt32.max)
  let request = Task { try await session.requestDesktopLayout(layout(4),expectedGeneration:generation) }
  try await until { native_resize_peer_count(peer) == 1 && session.snapshot.resizePending }
  try await expect(.busy) { _ = try await session.requestDesktopLayout(layout(5),expectedGeneration:generation) }
  try check(session.snapshot.width == 2,"wire admission is not server acknowledgement")
  native_resize_peer_reply(peer,0)
  let accepted = try await request.value
  try check(accepted.snapshot.width == 4 && !accepted.snapshot.resizePending,"completion follows successful server response")
  try check(try session.desktopLayout().layout == (try layout(4)) && initial.layout == (try layout(2)),"old copies remain immutable")
  try check(other.snapshot.width == 2 && other.snapshot.state == .connected,"other session unaffected")
  native_resize_peer_reply(peer,1)
  do { _ = try await session.requestDesktopLayout(layout(5),expectedGeneration:generation); throw Failure(message:"rejection accepted") }
  catch let failure as NativeCommandFailure {
    try check(failure.reason == .serverRejected && failure.nativeResult == 1 && failure.snapshot.width == 4,"typed server rejection leaves geometry unchanged")
  }
  native_resize_peer_reply(peer,UInt32.max)
  let cancelled = Task { try await session.requestDesktopLayout(layout(6),expectedGeneration:generation) }
  try await until { native_resize_peer_count(peer) == 3 }
  cancelled.cancel(); native_resize_peer_reply(peer,0)
  do { _ = try await cancelled.value; throw Failure(message:"cancelled await succeeded") } catch is CancellationError {}
  try await until { session.snapshot.width == 6 && !session.snapshot.resizePending }
  native_resize_peer_reply(peer,UInt32.max)
  do { _ = try await session.requestDesktopLayout(layout(7),expectedGeneration:generation); throw Failure(message:"held request never timed out") }
  catch let failure as NativeCommandFailure { try check(failure.reason == .timedOut,"typed protocol timeout") }
  try await expect(.busy) { _ = try await session.requestDesktopLayout(layout(8),expectedGeneration:generation) }
  native_resize_peer_reply(peer,0)
  try await until { !session.snapshot.resizePending && session.snapshot.width == 7 }
  let multi = try NativeRemoteLayout(width:6,height:2,screens:[.init(id:7,x:0,y:0,width:2,height:2,flags:9),.init(id:42,x:4,y:0,width:2,height:2,flags:11)])
  _ = try await session.requestDesktopLayout(multi,expectedGeneration:generation)
  try check(try session.desktopLayout().layout == multi,"multi-screen gap, identities and flags survive wire round trip")
  let maximum = try NativeRemoteLayout(width:255,height:1,screens:(0..<255).map { .init(id:UInt32($0),x:UInt32($0),y:0,width:1,height:1,flags:UInt32($0)) })
  _ = try await session.requestDesktopLayout(maximum,expectedGeneration:generation)
  try check(try session.desktopLayout().layout == maximum,"all 255 screens survive C/Swift and wire copies")
  native_resize_peer_reply(peer,UInt32.max)
  let closing = Task { try await session.requestDesktopLayout(layout(8),expectedGeneration:generation) }
  try await until { native_resize_peer_count(peer) == 7 }
  try await session.close()
  do { _ = try await closing.value; throw Failure(message:"closed request succeeded") } catch is NativeCommandFailure {} catch let error as NativeError { try check(error.status == .closing,"closed await") }
  try await other.close(); try await runtime.shutdown()
  print("PASS shared geometry validation, live wire acceptance/rejection, timeout/late reply, cancellation, close and session isolation")
}
final class Memory: NativePreferencesBacking, @unchecked Sendable {
  func read() throws -> Data? { nil }
  func write(_ value: Data) throws { throw Failure(message:"resize must not write defaults") }
}
@MainActor func editor() async throws {
  let runtime = try NativeRuntime(), store = NativePreferencesStore(backing:Memory())
  let model = ConnectionModel(runtime:runtime,preferences:store,onSession:{ _,_ in })
  try await until { model.session != nil }
  let peer = native_resize_peer_create()!; defer { native_resize_peer_destroy(peer) }
  model.endpoint = "127.0.0.1::\(native_resize_peer_port(peer))"; model.connect()
  try await until { model.canOpenRemoteResize }
  guard let session = model.session else { throw Failure(message:"missing session") }
  model.openRemoteResize()
  guard let draft = model.remoteResizeDraft else { throw Failure(message:"missing resize draft") }
  try check(!model.canOpenScaling && !model.canOpenInput && !model.canOpenRemoteResize,"editor excludes competing sheets")
  for text in ["0","65536","2.5","-3"," 4","4 ","999999999999999999999"] {
    draft.width = text; try check(!draft.canApply,"invalid dimensions do not enable Resize")
  }
  draft.width = "4"; try check(draft.canApply,"valid draft editable")
  try session.setViewOnly(true); try check(!draft.canApply,"view-only gates an open sheet")
  try session.setViewOnly(false)
  native_resize_peer_reply(peer,1); draft.apply(); try await until { !draft.isBusy }
  try check(!draft.didApply && draft.message?.contains("rejected") == true && draft.canApply,"server rejection stays correctable")
  native_resize_peer_reply(peer,0); draft.apply(); try await until { !draft.isBusy }
  try check(draft.didApply && draft.baseline?.layout.width == 4,"successful sheet shows actual server geometry")
  _ = try await session.requestDesktopLayout(layout(5),expectedGeneration:session.generation)
  draft.width = "6"; draft.apply()
  try check(draft.needsReload && !draft.isBusy && native_resize_peer_count(peer) == 3,"competing desktop change requires reload")
  draft.reload(); draft.width = "6"
  native_resize_peer_reply(peer,UInt32.max); draft.apply()
  try await until { native_resize_peer_count(peer) == 4 }
  model.closeRemoteResize()
  try check(!model.canOpenRemoteResize && !model.canOpenScaling,"dismissed request drains before new editor")
  native_resize_peer_reply(peer,0); try await until { model.canOpenRemoteResize }
  model.openRemoteResize(); model.remoteResizeDraft?.width = "7"; model.closeRemoteResize()
  try await until { model.canOpenRemoteResize }
  try check(native_resize_peer_count(peer) == 4 && session.snapshot.width == 6,"Cancel before Apply sends nothing")
  model.openRemoteResize(); model.remoteResizeDraft?.width = "8"
  native_resize_peer_reply(peer,UInt32.max); model.remoteResizeDraft?.apply()
  try await until { native_resize_peer_count(peer) == 5 }
  await model.close(); try check(model.remoteResizeDraft == nil,"controller close joins pending resize")
  await store.close(); try await runtime.shutdown()
  print("PASS native resize draft validation, server feedback, competing geometry, controller exclusion and joined teardown")
}
@MainActor final class DisplaySource: NativeDisplaySource {
  var values: [NativeDisplay] = []
  func read() throws -> [NativeDisplay] { values }
}
func monitor(_ id: String, x: Double, scale: Double, primary: Bool = false) -> NativeDisplay {
  let bounds = NativeDisplayRectangle(x:x,y:0,width:10,height:8)
  return NativeDisplay(id:.init(id),name:id,bounds:bounds,workArea:bounds,backingScale:scale,isPrimary:primary)
}
@MainActor func displayEditor() async throws {
  let runtime = try NativeRuntime(), store = NativePreferencesStore(backing:Memory())
  let source = DisplaySource(); source.values = [monitor("a",x:-10,scale:2),monitor("b",x:0,scale:1,primary:true)]
  let displays = NativeDisplayService(source:source,notifications:NotificationCenter(),workspaceNotifications:NotificationCenter())
  defer { displays.stop() }
  let model = ConnectionModel(runtime:runtime,preferences:store,displays:displays) { _,_ in }
  try await until { model.defaults?.isReady == true }
  let session = model.session!, peer = native_resize_peer_create()!
  defer { native_resize_peer_destroy(peer) }
  _ = try await session.connect(endpoint:"127.0.0.1::\(native_resize_peer_port(peer))")
  try await until { model.canOpenRemoteResize }; model.openRemoteResize()
  let draft = model.remoteResizeDraft!; draft.source = .allDisplays; draft.devicePixels = true
  try check(draft.canApply && draft.displayLayout?.width == 30 && draft.displayLayout?.normalized == true,"controller passes display service and previews shared mapping")
  draft.apply(); try await until { !draft.isBusy }
  let result = try session.desktopLayout().layout
  try check(result.width == 30 && result.height == 16 && result.screens.count == 2 && result.screens[0].id == 7 && result.screens[0].flags == 9,"monitor topology and reused identity reach actual wire")
  try check(draft.didApply && !draft.canApply,"unchanged topology is not resubmitted")
  let count = native_resize_peer_count(peer)
  draft.source = .selectedDisplays; draft.selectedDisplays = []
  try check(!draft.canApply && draft.displayMessage != nil,"empty explicit selection blocked")
  draft.selectedDisplays = [.init("a")]
  source.values = [monitor("b",x:0,scale:1,primary:true)]
  draft.apply() // No delivered notification: admission must reread source.
  try check(draft.needsDisplayReload && !draft.canApply && native_resize_peer_count(peer) == count,"fresh preflight detects unplug without sending fallback topology")
  draft.reload()
  try check(draft.missingDisplays == [.init("a")] && !draft.canApply && draft.selectedDisplays == [.init("a")],"Reload preserves missing UUID choice and requires explicit removal")
  source.values.insert(monitor("a",x:-10,scale:2),at:0); displays.refresh()
  try check(draft.needsDisplayReload,"replug requires review")
  draft.reload(); try check(draft.canApply && draft.missingDisplays.isEmpty,"replug restores stable ID")
  native_resize_peer_reply(peer,1); draft.apply(); try await until { !draft.isBusy }
  try check(!draft.didApply && draft.canApply && session.snapshot.width == 30,"monitor request rejection remains correctable")
  native_resize_peer_reply(peer,0); draft.apply(); try await until { !draft.isBusy }
  try check(draft.didApply && session.snapshot.width == 20 && draft.baseline?.layout.screens.count == 1,"selected monitor request applies")
  draft.selectedDisplays = [.init("b")]; try session.setViewOnly(true)
  try check(!draft.canApply,"view-only gates display layout path")
  try session.setViewOnly(false)
  source.values = []; displays.refresh(); draft.source = .custom; draft.width = "21"
  try check(draft.canApply,"custom sizing independent of local display availability")
  model.closeRemoteResize(); try await until { model.canOpenRemoteResize }
  await model.close(); await store.close(); try await runtime.shutdown()
  print("PASS chooser wire layout, identity, rejection, explicit selection, no-notification unplug, replug, review and controller lifetime")
}
@main struct Main {
  static func main() async {
    do { try await run(); try await editor(); try await displayEditor() }
    catch { print("FAIL \(error)"); exit(1) }
  }
}
