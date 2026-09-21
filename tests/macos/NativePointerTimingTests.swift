// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeTestSupport
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw Failure(message:message) }
}
func resolved(_ args: [String], base: NativeSessionConfiguration = .init()) throws -> NativeInvocationResolution {
  try .init(options:.init(arguments:args),endpoint:"",base:base,workingDirectory:"/launch")
}
func values() throws {
  try check(try NativePointerTiming.defaultMilliseconds() == 17,"shared retained default")
  for invalid in ["-1","2147483648","private-invalid"] {
    do { _ = try resolved(["-PointerEventInterval="+invalid,"-PointerEventInterval=0"]); throw Failure(message:"invalid earlier interval accepted") }
    catch let failure as NativeInvocationFailure { try check(failure.argument == 1 && failure.problem == .invalidValue,"bounded per-occurrence validation") }
  }
  let result = try resolved(["-PointerEventInterval=17","-PointerEventInterval=0"])
  try check(result.configuration.pointerEventIntervalMilliseconds == 0 && result.configuration.pointerEventIntervalSource == .commandLine,
            "explicit zero and CLI provenance")
  let document = try NativeConnectionDocument(data:Data("TidyVNC Configuration file Version 1.0\nShared=on\nPointerEventInterval=400\n".utf8))
  let file = try NativeDocumentResolution(document:document,base:result.configuration)
  let config = try file.configuration(acknowledging:Set(file.notices.map(\.line)))
  try check(config.pointerEventIntervalMilliseconds == 0 && file.notices.count == 1,"CLI-only timing survives file overlay")
  let export = try NativeDocumentExport(endpoint:"",configuration:config)
  try check(export.losses.contains(.pointerTiming),"omitted timing requires review")
  do { _ = try export.serializedData(acknowledging:export.losses.subtracting([.pointerTiming])); throw Failure(message:"unreviewed timing loss accepted") }
  catch NativeDocumentExportError.reviewRequired {}
  let help = try NativeInvocationBootstrap.terminal(.init(arguments:["--help"]),version:"fixture")!
  try check(help.text.contains("PointerEventInterval <value> [default: 17]\n"),"help uses shared timing default and native support status")
}
final class Peer {
  let raw: UnsafeMutableRawPointer
  init() throws {
    guard let raw = native_test_peer_create_reconnecting(0) else { throw Failure(message:"local peer unavailable") }
    self.raw = raw
  }
  var endpoint: String { "127.0.0.1::\(native_test_peer_port(raw))" }
  func count(_ x: UInt32, _ y: UInt32, _ buttons: UInt32 = 0) -> UInt32 { native_test_peer_count_input(raw,5,buttons,x,y) }
  deinit { native_test_peer_destroy(raw) }
}
@MainActor func until(_ condition: () -> Bool) async throws {
  for _ in 0..<3000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"pointer fixture timed out")
}
@MainActor func wire() async throws {
  let runtime = try NativeRuntime(), slowPeer = try Peer(), fastPeer = try Peer()
  var slowConfig = try resolved(["-PointerEventInterval=2147483647"]).configuration
  let slow = try runtime.makeSession(configuration:slowConfig)
  slowConfig.pointerEventIntervalMilliseconds = 0
  let fast = try runtime.makeSession(configuration:slowConfig)
  let ordinary = try runtime.makeSession()
  try check(ordinary.pointerEventIntervalMilliseconds == 17 && ordinary.pointerEventIntervalSource == .compiled,"native default snapshots shared policy")
  try check(slow.pointerEventIntervalMilliseconds == UInt32(Int32.max) && slow.pointerEventIntervalSource == .commandLine,"owned policy unaffected by source edits")
  var bad = NativeSessionConfiguration(); bad.pointerEventIntervalMilliseconds = .max
  do { _ = try runtime.makeSession(configuration:bad); throw Failure(message:"host bypassed interval bound") }
  catch let error as NativeError { try check(error.status == .invalidArgument,"C creation validates native configuration") }
  _ = try await slow.connect(endpoint:slowPeer.endpoint); _ = try await fast.connect(endpoint:fastPeer.endpoint)
  try slow.setFocused(true); try fast.setFocused(true)
  try slow.sendPointer(x:1,y:1,buttons:0)
  try fast.sendPointer(x:1,y:1,buttons:0)
  try await until { fastPeer.count(1,1) == 1 }
  try check(slowPeer.count(1,1) == 0,"per-session interval reaches the protocol worker")
  try slow.sendPointer(x:0,y:1,buttons:1)
  try await until { slowPeer.count(0,1,1) == 1 }
  try slow.sendPointer(x:0,y:1,buttons:0)
  try await until { slowPeer.count(0,1) == 1 }
  try slow.sendPointer(x:1,y:0,buttons:0)
  try slow.sendKey(id:65,keysym:65,down:true)
  try await until { slowPeer.count(1,0) == 1 && native_test_peer_has_key(slowPeer.raw) == 1 }
  try slow.sendKey(id:65,keysym:65,down:false)
  // A routing barrier must discard pending motion; a following key is also a
  // deterministic flush probe, without waiting for the deliberately long timer.
  try slow.sendPointer(x:1,y:1,buttons:0); try slow.setFocused(false); try slow.setFocused(true)
  try slow.sendKey(id:66,keysym:66,down:true); try slow.sendKey(id:66,keysym:66,down:false)
  try await until { native_test_peer_count_input(slowPeer.raw,0,66,0,0) == 1 }
  try check(slowPeer.count(1,1) == 0,"focus loss discards pending motion before next key")
  try slow.sendPointer(x:1,y:1,buttons:0)
  _ = try await slow.disconnect(); _ = try await slow.connect(endpoint:slowPeer.endpoint); try slow.setFocused(true)
  try slow.sendKey(id:67,keysym:67,down:true); try slow.sendKey(id:67,keysym:67,down:false)
  try await until { native_test_peer_count_input(slowPeer.raw,0,67,0,0) == 1 }
  try check(slowPeer.count(1,1) == 0,"no old pending motion after reconnect")
  try slow.sendPointer(x:1,y:1,buttons:0)
  try fast.sendPointer(x:0,y:0,buttons:0); try await until { fastPeer.count(0,0) == 1 }
  try check(slowPeer.count(1,1) == 0,"reconnect retains the slow policy")
  try await runtime.shutdown()
}
@main enum NativePointerTimingTests {
  @MainActor static func main() async {
    do { try values(); try await wire(); print("Native pointer interval defaults, CLI/file/export and independent wire timing passed") }
    catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
  }
}
