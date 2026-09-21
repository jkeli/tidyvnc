// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import AppKit
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw Failure(message:message) }
}
func resolved(_ arguments: [String]) throws -> NativeSessionConfiguration {
  try NativeInvocationResolution(options:.init(arguments:arguments),endpoint:"",workingDirectory:"/launch").configuration
}
func values() throws {
  let value = try resolved(["-geometry=800x600+-100+20ignored","-Maximize"])
  try check(value.windowStartupPolicy.geometry?.x == -100 && value.windowStartupPolicy.geometry?.width == 800 && value.windowStartupPolicy.maximize,"retained syntax and maximize")
  try check(value.windowStartupSources == [.geometry:.commandLine,.maximize:.commandLine],"CLI sources")
  let cleared = try resolved(["-geometry=800x600","-geometry=","-Maximize","-Maximize=off"])
  try check(!cleared.windowStartupPolicy.hasPlacement,"empty geometry and explicit off clear earlier values")
  do { _ = try resolved(["-geometry=800x600+10","-geometry=800x600"]); throw Failure(message:"earlier invalid geometry hidden") }
  catch let error as NativeInvocationResolutionFailure { try check(error.reason == .invalidValue && error.argument == 1,"per-occurrence typed geometry error") }
  let document = try NativeConnectionDocument(data:Data("TidyVNC Configuration file Version 1.0\ngeometry=1x1\nMaximize=off\nShared=on\n".utf8))
  let review = try NativeDocumentResolution(document:document,base:value)
  let file = try review.configuration(acknowledging:Set(review.notices.map(\.line)))
  try check(file.windowStartupPolicy == value.windowStartupPolicy && review.notices.count == 2,"file review preserves CLI-only placement")
  let export = try NativeDocumentExport(endpoint:"",configuration:file)
  do { _ = try export.serializedData(acknowledging:export.losses.subtracting([.windowPlacement])); throw Failure(message:"placement omission bypassed review") }
  catch NativeDocumentExportError.reviewRequired {}
  let help = try NativeInvocationBootstrap.terminal(.init(arguments:["--help"]),version:"fixture")!
  try check(help.text.contains("  geometry <value>\n") && help.text.contains("  Maximize [on|off]\n"),"native help advertises implemented placement")
}
@MainActor func arithmetic() throws {
  let current = NSRect(x:-1100,y:200,width:640,height:400), work = NSRect(x:-1200,y:40,width:1200,height:760)
  let decoration = NSRect(x:0,y:0,width:0,height:28), minimum = NSSize(width:320,height:200), maximum = NSSize(width:100000,height:100000)
  func place(_ text: String, maximize: Bool = false, top: NSPoint? = nil) throws -> NSRect {
    NativeWindowStartupState.contentRect(policy:.init(geometry:try .init(text),maximize:maximize),current:current,workArea:work,
      decoration:decoration,minimum:minimum,maximum:maximum,topLeft:top)
  }
  try check(try place("2147483647x2147483647") == NSRect(x:-1100,y:-132,width:1200,height:732),"large requested content clamps to work area and preserves top-left")
  try check(try place("1x1") == NSRect(x:-1100,y:400,width:320,height:200),"native window minimum is respected")
  try check(try place("",maximize:true) == NSRect(x:-1200,y:40,width:1200,height:732),"maximize accounts for frame decoration in negative-origin work area")
  try check(try place("800x600+-100+20",maximize:true,top:NSPoint(x:-100,y:780)) == NSRect(x:-100,y:48,width:1200,height:732),"explicit position survives maximize")
}
@MainActor final class Window: NSWindow {
  var sheetFixture: NSWindow?
  override var attachedSheet: NSWindow? { sheetFixture }
}
@MainActor final class Delegate: NSObject, NSWindowDelegate {}
@MainActor func windows() throws {
  _ = NSApplication.shared
  guard let primary = NSScreen.screens.first else { throw Failure(message:"no fixture display") }
  func make() -> Window {
    let window = Window(contentRect:.init(x:100,y:100,width:400,height:300),styleMask:[.titled,.resizable,.closable],backing:.buffered,defer:false)
    window.isReleasedWhenClosed = false; return window
  }
  let window = make(), other = make(), cancelled = make(), deferred = make()
  defer { for value in [window,other,cancelled,deferred] { value.close() } }
  let delegate = Delegate(); window.delegate = delegate
  let owner = NativeWindowStartupState(), initial = window.frame
  owner.attach(window); try check(window.frame == initial && !owner.resolved,"window waits for admitted settings")
  owner.configure(.init(geometry:try .init("500x350+60+70")))
  let content = window.contentRect(forFrameRect:window.frame)
  try check(abs(content.width-500) < 1 && abs(content.height-350) < 1 && abs(content.minX-primary.frame.minX-60) < 1 &&
            abs(content.maxY-primary.frame.maxY+70) < 1,"AppKit content size and primary-top-left coordinate conversion")
  try check(owner.resolved && window.delegate === delegate && !window.isVisible,"placement preserves delegate and does not order a window front")
  window.setContentSize(.init(width:440,height:330)); let edited = window.frame, untouched = other.frame
  owner.attach(window); owner.attach(other); owner.configure(.init(maximize:true))
  NotificationCenter.default.post(name:NSApplication.didChangeScreenParametersNotification,object:nil)
  try check(window.frame == edited && other.frame == untouched,"view updates and display notifications cannot replay consumed placement")
  let maximized = NativeWindowStartupState(), work = (other.screen ?? primary).visibleFrame
  maximized.configure(.init(maximize:true)); maximized.attach(other)
  try check(abs(other.frame.minX-work.minX) < 1 && abs(other.frame.minY-work.minY) < 1 &&
            abs(other.frame.width-work.width) < 1 && abs(other.frame.height-work.height) < 1,"Maximize fills available AppKit work area")
  let closing = NativeWindowStartupState(), beforeClose = cancelled.frame
  closing.attach(cancelled); NotificationCenter.default.post(name:NSWindow.willCloseNotification,object:cancelled)
  closing.configure(.init(maximize:true)); try check(cancelled.frame == beforeClose,"close revokes placement awaiting admission")
  let sheet = NSWindow(contentRect:.zero,styleMask:[],backing:.buffered,defer:false); sheet.isReleasedWhenClosed = false
  defer { sheet.close() }; deferred.sheetFixture = sheet
  let waiting = NativeWindowStartupState(), beforeSheet = deferred.frame
  waiting.configure(.init(geometry:try .init("510x360"))); waiting.attach(deferred)
  try check(deferred.frame == beforeSheet && !waiting.resolved,"sheet prevents window mutation")
  deferred.sheetFixture = nil; NotificationCenter.default.post(name:NSWindow.didEndSheetNotification,object:deferred)
  try check(waiting.resolved && abs(deferred.contentRect(forFrameRect:deferred.frame).width-510) < 1,"sheet dismissal resolves pending placement once")
  owner.stop(); maximized.stop(); waiting.stop()
}
@main enum NativeWindowStartupTests {
  @MainActor static func main() async {
    do {
      try values(); try arithmetic(); try windows()
      let runtime = try NativeRuntime()
      var configuration = try resolved(["-geometry=800x600","-Maximize"])
      let session = try runtime.makeSession(configuration:configuration)
      configuration.windowStartupPolicy = .builtIn
      try check(session.initialWindowStartupPolicy.maximize && session.initialWindowStartupPolicy.geometry?.width == 800,"session owns immutable launch policy")
      try await runtime.shutdown()
      print("Native geometry/Maximize CLI, file/export, work-area placement and one-shot window lifetime passed")
    } catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
  }
}
