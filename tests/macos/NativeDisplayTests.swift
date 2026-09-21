// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
import Combine
@testable import TidyVNCNative

struct Failure: Error { let message: String }
final class WeakReference<T: AnyObject> {
  weak var value: T?
  init(_ value: T?) { self.value = value }
}
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw Failure(message: message) }
}
func rectangle(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NativeDisplayRectangle {
  NativeDisplayRectangle(x: x, y: y, width: w, height: h)
}
func display(_ id: String, x: Double = 0, y: Double = 0, scale: Double = 1, primary: Bool = false) -> NativeDisplay {
  NativeDisplay(id: NativeDisplayID(id), name: id, bounds: rectangle(x,y,1000,800),
    workArea: rectangle(x,y+24,1000,740), backingScale: scale, isPrimary: primary)
}
@MainActor final class Source: NativeDisplaySource {
  var values: [NativeDisplay] = [], reads = 0
  var failure: NativeDisplayError?
  func read() throws -> [NativeDisplay] { reads += 1; if let failure { throw failure }; return values }
}
@MainActor func snapshotsAndSelection() throws {
  let source = Source(), notifications = NotificationCenter()
  let primary = display("primary", scale: 2, primary: true)
  let left = display("left", x: -1000), above = display("above", y: -800, scale: 1.5)
  source.values = [primary, left, above]
  let service = NativeDisplayService(source: source, notifications: notifications, workspaceNotifications: notifications)
  defer { service.stop() }
  let original = service.snapshot
  try check(original.generation == 1 && original.error == nil && original.displays.count == 3, "initial topology")
  try check(original.display(left.id)?.bounds.x == -1000 && original.display(above.id)?.bounds.y == -800, "negative origins preserved")
  try check(original.display(above.id)?.backingScale == 1.5 && original.primary == primary, "fractional scale and explicit primary")
  var updates: [NativeDisplaySnapshot] = []
  let subscription = service.$snapshot.dropFirst().sink { value in
    MainActor.assumeIsolated { updates.append(value); service.refresh() } // Safe synchronous observer reentry.
  }
  defer { subscription.cancel() }
  source.values.reverse(); service.refresh()
  notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
  try check(updates.isEmpty && service.snapshot == original, "order-only and duplicate notifications do not publish")
  source.values = [primary, above]
  notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
  try check(service.snapshot.generation == 2 && updates.count == 1, "removal publishes one generation")
  try check(original.displays.count == 3, "retained old snapshot is immutable")
  let partial = service.snapshot.resolve([left.id, above.id, above.id])
  try check(partial.displays == [above] && partial.missing == [left.id] && !partial.usedFallback, "partial selected-monitor loss preserves surviving choice")
  let fallback = service.snapshot.resolve([left.id], current: above.id)
  try check(fallback.displays == [above] && fallback.missing == [left.id] && fallback.usedFallback, "missing-only selection falls back to current")
  try check(service.snapshot.resolve([left.id], current: left.id).displays == [primary], "missing current falls back to primary")
  source.values = [above, left, primary]; service.refresh()
  try check(service.snapshot.resolve([left.id]).displays == [left] && !service.snapshot.resolve([left.id]).usedFallback, "replug restores stable selected ID")
  source.values = [display("primary", scale: 1, primary: true), left]
  notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
  try check(service.snapshot.generation == 4 && service.snapshot.primary?.backingScale == 1, "scale change publishes")
  source.values = []; service.refresh()
  try check(service.snapshot.error == nil && service.snapshot.displays.isEmpty && service.snapshot.resolve([left.id]).displays.isEmpty, "no displays has no fabricated fallback")
  source.values = [primary]; service.refresh()
  source.failure = .unavailable; service.refresh()
  try check(service.snapshot.error == .unavailable && service.snapshot.primary == nil, "failure does not offer stale geometry")
  let failedGeneration = service.snapshot.generation; service.refresh()
  try check(service.snapshot.generation == failedGeneration, "same failure coalesces")
  source.failure = nil; service.refresh()
  try check(service.snapshot.generation == failedGeneration + 1 && service.snapshot.primary == primary, "error recovery publishes")
  let reads = source.reads
  service.stop(); source.values = []; service.refresh()
  notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
  notifications.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
  try check(source.reads == reads, "stop gates explicit and notification refresh")
  print("PASS display generation, immutable ownership, mixed scale, negative origins, remove/replug selection, failures and stop")
}
@MainActor func validationAndCoordinates() throws {
  let source = Source(), service = NativeDisplayService(source: source, notifications: NotificationCenter())
  defer { service.stop() }
  let primary = display("one", primary: true)
  for bad in [[primary, primary], [display("non-primary")], [display("bad", scale: .nan, primary: true)],
              [display("bad", x: .infinity, primary: true)], [display("", primary: true)]] {
    source.values = bad; service.refresh()
    try check(service.snapshot.error == .invalidSnapshot && service.snapshot.displays.isEmpty, "invalid snapshot rejected as a unit")
  }
  source.values = [NativeDisplay(id: primary.id, name: "bad", bounds: primary.bounds,
    workArea: rectangle(-1,0,1000,800), backingScale: 1, isPrimary: true)]
  service.refresh(); try check(service.snapshot.error == .invalidSnapshot, "work area outside bounds rejected")
  source.values = (0..<65).map { display("\($0)", primary: $0 == 0) }
  service.refresh(); try check(service.snapshot.error == .tooManyDisplays, "bounded topology")
  let base = CGRect(x: 0, y: 0, width: 1000, height: 800)
  try check(AppKitDisplaySource.rectangle(base, primary: base) == rectangle(0,0,1000,800), "primary origin")
  try check(AppKitDisplaySource.rectangle(CGRect(x: -500,y: 800,width: 500,height: 400), primary: base) == rectangle(-500,-400,500,400), "above-left AppKit conversion")
  try check(AppKitDisplaySource.rectangle(CGRect(x: 0,y: 50,width: 1000,height: 720), primary: base) == rectangle(0,30,1000,720), "work-area orientation preserves top and bottom exclusions")
  print("PASS malformed topology, bounds, count limit and AppKit logical-coordinate conversion")
}
@MainActor func viewAndLifetime() throws {
  let source = Source(), notifications = NotificationCenter()
  source.values = [display("primary", primary: true)]
  var service: NativeDisplayService? = NativeDisplayService(source: source, notifications: notifications)
  let weakService = WeakReference(service)
  var view: NativeDesktopView? = NativeDesktopView(frame: CGRect(x: 0,y: 0,width: 100,height: 100))
  let weakView = WeakReference(view)
  view!.observeDisplays(service)
  try check(view!.displayGeneration == 1, "desktop receives initial topology")
  source.values = []; service!.refresh()
  try check(view!.displayGeneration == 2 && view!.desktopRectangle == .zero, "unattached desktop receives topology without fabricating frame geometry")
  view!.detach(); source.values = [display("new", primary: true)]; service!.refresh()
  try check(view!.displayGeneration == 0, "detached view stops receiving topology")
  view!.observeDisplays(service); view = nil
  try check(weakView.value == nil, "subscription does not retain desktop")
  service = nil
  try check(weakService.value == nil, "notification center does not retain service")
  let reads = source.reads; notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
  try check(source.reads == reads, "no provider access after service disposal")
  print("PASS desktop topology delivery, detach and weak service/view disposal")
}
@MainActor func actualAppKit() throws {
  let service = NativeDisplayService()
  defer { service.stop() }
  let first = service.snapshot
  try check(first.error == nil && !first.displays.isEmpty, "actual NSScreen snapshot available")
  try check(first.displays.count == NSScreen.screens.count, "all current AppKit drawable screens represented")
  try check(first.primary?.bounds.x == 0 && first.primary?.bounds.y == 0, "actual primary top-left origin")
  for value in first.displays {
    try check(value.id.rawValue.hasPrefix("macos-display:") && value.backingScale > 0, "opaque UUID identity and actual scale")
  }
  service.refresh()
  try check(service.snapshot == first, "actual IDs and values stable across immediate reread")
  // Exercise the same notification route without changing hardware or settings.
  NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
  try check(service.snapshot == first, "AppKit notification rereads unchanged topology")
  print("PASS actual NSScreen/ColorSync capture: \(first.displays.count) drawable display(s); no physical hotplug/mixed-density claim")
}
func layoutMapping() throws {
  let left = display("left",x:-1000,scale:2), main = display("main",primary:true)
  let logical = try NativeDisplayLayout(displays:[main,left],devicePixels:false)
  let pixels = try NativeDisplayLayout(displays:[left,main],devicePixels:true)
  try check(logical.width == 2000 && logical.height == 800 && !logical.normalized,"logical shared layout")
  try check(pixels.width == 3000 && pixels.height == 1600 && pixels.normalized,"mixed pixel layout normalization")
  try check(pixels.regions.first { $0.id == main.id }?.x == 2000,"mixed density preserves adjacency without overlapping")
  let reordered = try NativeDisplayLayout(displays:[main,left],devicePixels:true)
  try check(pixels == reordered,"display enumeration order does not change mapping")
  let above = display("above",y:-900,scale:1.5)
  let vertical = try NativeDisplayLayout(displays:[main,above],devicePixels:true)
  try check(vertical.regions.first { $0.id == main.id }?.y == 1300,"vertical density and logical gap preserved")
  let baseline = try NativeRemoteLayout(width:2000,height:800,screens:[
    .init(id:42,x:1000,y:0,width:1000,height:800,flags:9),.init(id:7,x:0,y:0,width:1000,height:800,flags:11)])
  let remote = try logical.remoteLayout(matching:baseline)
  try check(remote.screens.first { $0.x == 1000 }?.id == 42 && remote.screens.first { $0.x == 0 }?.flags == 11,"exact geometry keeps remote identity and flags")
  let one = try NativeRemoteLayout(width:2,height:2,screens:[.init(id:0,x:0,y:0,width:2,height:2,flags:19)])
  let fresh = try pixels.remoteLayout(matching:one)
  try check(Set(fresh.screens.map(\.id)) == [0,1] && fresh.screens[0].flags == 19 && fresh.screens[1].flags == 0,"new identity avoids existing zero ID and preserves reused flags")
  for values in [[],[main,main],[main,display("mirror")],[display("fractional",x:0.5)],[display("huge",scale:100)]] as [[NativeDisplay]] {
    do { _ = try NativeDisplayLayout(displays:values,devicePixels:true); throw Failure(message:"invalid layout accepted") }
    catch is NativeError {}
  }
  print("PASS shared logical/device monitor mapping, mixed-density normalization, geometry identity and strict invalid-input rejection")
}
@main struct NativeDisplayTests {
  @MainActor static func main() {
    _ = NSApplication.shared
    do { try layoutMapping(); try snapshotsAndSelection(); try validationAndCoordinates(); try viewAndLifetime(); try actualAppKit() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
