// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import NativeTestSupport
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw Failure(message:message) }
}
func resolved(_ args: [String]) throws -> NativeSessionConfiguration {
  try NativeInvocationResolution(options:.init(arguments:args),endpoint:"",workingDirectory:"/launch").configuration
}
func values() throws {
  try check(try NativeMessageLimits.defaultMaxCutText() == 262144,"shared retained default")
  for invalid in ["-1","2147483648","private-invalid"] {
    do { _ = try resolved(["-MaxCutText="+invalid,"-MaxCutText=0"]); throw Failure(message:"invalid earlier limit accepted") }
    catch let failure as NativeInvocationFailure { try check(failure.argument == 1 && failure.problem == .invalidValue,"bounded per-occurrence validation") }
  }
  let config = try resolved(["-MaxCutText=2147483647","-MaxCutText=0"])
  try check(config.maxCutText == 0 && config.maxCutTextSource == .commandLine,"explicit zero and CLI provenance")
  let document = try NativeConnectionDocument(data:Data("TidyVNC Configuration file Version 1.0\nShared=on\nMaxCutText=400\n".utf8))
  let file = try NativeDocumentResolution(document:document,base:config)
  let overlay = try file.configuration(acknowledging:Set(file.notices.map(\.line)))
  try check(overlay.maxCutText == 0 && overlay.maxCutTextSource == .commandLine && file.notices.count == 1,"CLI-only limit survives file review")
  let export = try NativeDocumentExport(endpoint:"",configuration:overlay)
  try check(export.losses.contains(.clipboardLimit),"omitted limit requires review")
  do { _ = try export.serializedData(acknowledging:export.losses.subtracting([.clipboardLimit])); throw Failure(message:"unreviewed limit loss accepted") }
  catch NativeDocumentExportError.reviewRequired {}
  let data = try export.serializedData(acknowledging:export.losses)
  try check(!String(decoding:data,as:UTF8.self).contains("MaxCutText="),"no invented file field")
  let help = try NativeInvocationBootstrap.terminal(.init(arguments:["--help"]),version:"fixture")!
  try check(help.text.contains("MaxCutText <value> [default: 262144]\n"),"help default and support status")
}
final class Peer {
  let raw: UnsafeMutableRawPointer
  var clipboardMarker: UInt8 = 0
  init() throws {
    guard let raw = native_test_peer_create_reconnecting(0) else { throw Failure(message:"local peer unavailable") }
    self.raw = raw
  }
  var endpoint: String { "127.0.0.1::\(native_test_peer_port(raw))" }
  deinit { native_test_peer_destroy(raw) }
}
@MainActor func until(_ message: String, _ condition: () -> Bool) async throws {
  for _ in 0..<3000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Timed out: "+message)
}
@MainActor func receive(_ bytes: [UInt8], from peer: Peer, into session: NativeSession) async throws {
  let frame = session.frame?.sequence ?? 0
  try check(peer.clipboardMarker < .max,"fixture marker must not wrap")
  try check(bytes.withUnsafeBufferPointer { native_test_peer_clipboard_bytes(peer.raw,$0.baseAddress,UInt32($0.count)) } == 1,"bounded fixture admission")
  peer.clipboardMarker += 1
  let marker = Data([peer.clipboardMarker,0,0,0])
  // A queued initial-frame publication can advance sequence before the peer
  // has sent this clipboard message. Only its trailing wire marker establishes
  // that the message (including discarded text) has actually been consumed.
  try await until("clipboard wire marker") {
    (session.frame?.sequence ?? 0) > frame &&
      (try? session.frame?.copyPixels().prefix(4)) == marker
  }
  try check(session.snapshot.state == .connected && session.deliveryError == nil,"oversize discard preserves protocol alignment and connection")
}
@MainActor func wire() async throws {
  let runtime = try NativeRuntime(), smallPeer = try Peer(), boundaryPeer = try Peer(), zeroPeer = try Peer(), largePeer = try Peer()
  var smallConfig = try resolved(["-MaxCutText=5"])
  let small = try runtime.makeSession(configuration:smallConfig)
  smallConfig.maxCutText = 6
  let boundary = try runtime.makeSession(configuration:smallConfig)
  let zero = try runtime.makeSession(configuration:resolved(["-MaxCutText=0"]))
  let large = try runtime.makeSession(configuration:resolved(["-MaxCutText=2147483647"]))
  let ordinary = try runtime.makeSession()
  try check(ordinary.maxCutText == 262144 && ordinary.maxCutTextSource == .compiled,"shared default captured by native session")
  try check(small.maxCutText == 5 && small.maxCutTextSource == .commandLine,"caller edits do not mutate session policy")
  try check(large.maxCutText == UInt32(Int32.max),"full retained upper bound reaches session")
  var invalid = NativeSessionConfiguration(); invalid.maxCutText = .max
  do { _ = try runtime.makeSession(configuration:invalid); throw Failure(message:"host bypassed limit bound") }
  catch let error as NativeError { try check(error.status == .invalidArgument,"C creation checks direct host input") }
  for (session,peer) in [(small,smallPeer),(boundary,boundaryPeer),(zero,zeroPeer),(large,largePeer)] {
    _ = try await session.connect(endpoint:peer.endpoint); try session.setFocused(true)
    try await until("initial frame") { session.frame != nil }
  }
  let latin1: [UInt8] = [99,97,102,233,13,10]
  let smallBefore = small.clipboard?.sequence
  try await receive(latin1,from:smallPeer,into:small)
  try check(small.clipboard?.sequence == smallBefore,"wire bytes above cap are silently discarded")
  try await receive(latin1,from:boundaryPeer,into:boundary)
  try check(boundary.clipboard?.text?.text == "café\n","inclusive wire boundary before Latin-1 conversion and newline normalization")
  let zeroBefore = zero.clipboard?.sequence
  try await receive([65],from:zeroPeer,into:zero)
  try check(zero.clipboard?.sequence == zeroBefore,"zero discards nonempty incoming text")
  try await receive([],from:zeroPeer,into:zero)
  try check(zero.clipboard?.text?.text == "","zero permits empty clipboard update")
  _ = try await zero.offerClipboard("outgoing")
  let outgoing = Array("outgoing".utf8)
  try await until("outgoing unaffected") { outgoing.withUnsafeBufferPointer { native_test_peer_count_clipboard(zeroPeer.raw,$0.baseAddress,UInt32($0.count)) } == 1 }
  // Raising the protocol cap is distinct from raising the bounded UTF-8 mailbox.
  try await receive(Array(repeating:65,count:262145),from:largePeer,into:large)
  try check(large.clipboard?.kind == .rejected && large.clipboard?.result == .resourceLimit,"independent retained text budget still enforced")
  try await receive(Array("recovered".utf8),from:largePeer,into:large)
  try check(large.clipboard?.text?.text == "recovered","retention rejection recovers without disconnect")
  _ = try await small.disconnect(); _ = try await small.connect(endpoint:smallPeer.endpoint); try small.setFocused(true)
  try await until("reconnected frame") { small.frame != nil }
  let reconnected = small.clipboard?.sequence
  try await receive(latin1,from:smallPeer,into:small)
  try check(small.clipboard?.sequence == reconnected,"reconnect retains message cap")
  try await receive(Array("small".utf8),from:smallPeer,into:small)
  try check(small.clipboard?.text?.text == "small","cap accepts boundary after reconnect")
  try check(boundary.clipboard?.text?.text == "café\n","other session clipboard and policy remain independent")
  try await runtime.shutdown()
}
@main enum NativeMessageLimitsTests {
  @MainActor static func main() async {
    do { try values(); try await wire(); print("Native MaxCutText defaults, CLI/file/export, wire bounds, retention and reconnect passed") }
    catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
  }
}
