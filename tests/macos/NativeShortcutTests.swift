// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message: message) } }
@MainActor func classifier() throws {
  for mask in UInt32(0)..<16 {
    let state = try NativeShortcutState(modifiers: .init(rawValue: mask))
    for (index, symbol) in [UInt32(0xffe3),0xffe1,0xffe9,0xffeb].enumerated() where mask & (1 << index) != 0 {
      try check(try state.key(id: Int32(index), keysym: symbol, down: true) == .normal, "modifier forwarding")
    }
    try check(try state.key(id: 99, keysym: 0xff0d, down: true) == (mask == 0 ? .normal : .shortcut), "all modifier sets")
    try state.reset()
    try check(try state.key(id: 99, keysym: 0xff0d, down: true) == .normal, "reset clears held modifiers")
  }
  let full = try NativeShortcutState(modifiers: .control)
  _ = try full.key(id: -1, keysym: 0xffe3, down: true)
  for id in Int32(0)..<1023 { _ = try full.key(id: id, keysym: 0x61, down: true) }
  do { _ = try full.key(id: 1024, keysym: 0x61, down: true); throw Failure(message: "Unbounded shortcut state") }
  catch let error as NativeError { try check(error.status == .resourceLimit, "typed capacity failure") }
  try check(try full.key(id: 1, keysym: 0x61, down: true) == .shortcut, "repeat consumes no slot")
  _ = try full.key(id: 1, keysym: 0, down: false)
  try check(try full.key(id: 1024, keysym: 0x61, down: true) == .shortcut, "recovery after release")
  do { try full.setModifiers(.init(rawValue: 16)); throw Failure(message: "Accepted unsupported modifiers") }
  catch let error as NativeError { try check(error.status == .invalidArgument, "invalid modifier status") }
  try check(try full.key(id: 1024, keysym: 0, down: false) == .shortcut, "failed setting preserves state")
  print("PASS shared shortcut classifier: modifier sets, reset, repeats, bounded capacity and failure preservation")
}
@MainActor func routing() throws {
  let router = try NativeShortcutRouter()
  var translations = 0
  func translated() -> [UInt32] { translations += 1; return [0xff0d] }
  _ = try router.press(id: 36, keysym: 0xff0d, candidates: translated())
  try check(translations == 0, "ordinary input never translates shortcut candidates")
  try router.reset()
  func arm() throws {
    try check(try router.press(id: 59, keysym: 0xffe3, candidates: []) == .init(.remote), "Control forwarded")
    try check(try router.press(id: 58, keysym: 0xffe9, candidates: []) == .init(.remote), "Option forwarded")
  }
  try arm()
  try check(try router.release(id: 58) == .init(.remote), "partial chord release")
  try check(try router.release(id: 59) == .init(.releaseKeyboard, release: true), "modifier-only releases keyboard control")
  for (symbol, route) in [(UInt32(0x67), NativeShortcutDecision.Route.captureKeyboard), (0x6d,.contextMenu), (0xff0d,.toggleFullscreen), (0xff8d,.toggleFullscreen), (0x78,.suppress)] {
    try router.reset(); try arm()
    try check(try router.press(id: 9, keysym: 0x10000e9, candidates: [0x10000e9,symbol]) == .init(route, release: true), "layout candidates choose local action")
    try check(try router.press(id: 9, keysym: symbol, candidates: [symbol]) == .init(route, release: true), "repeat preserves local routing")
    try check(try router.release(id: 9) == .init(.suppress), "local release not forwarded")
    try check(try router.release(id: 59) == .init(.suppress), "released modifiers not sent twice")
    _ = try router.release(id: 58)
  }
  try router.reset(); try arm()
  try check(try router.press(id: 49, keysym: 0x20, candidates: [0x20]) == .init(.suppress), "Space begins bypass without releasing remote modifiers")
  try check(try router.release(id: 49) == .init(.remote), "bypass Space release is safe for unmatched wire key")
  try check(try router.press(id: 46, keysym: 0x6d, candidates: [0x6d]) == .init(.remote), "bypass forwards shortcut chord")
  _ = try router.release(id: 46); _ = try router.release(id: 58); _ = try router.release(id: 59)
  try arm()
  try check(try router.press(id: 46, keysym: 0x6d, candidates: [0x6d]) == .init(.contextMenu, release: true), "bypass ends after all releases")
  try check(try router.press(id: 49, keysym: 0x20, candidates: [0x20]) == .init(.suppress), "Space after local action cannot bypass")
  try check(try router.press(id: 46, keysym: 0x6d, candidates: [0x6d]) == .init(.contextMenu, release: true), "late Space preserves local routing")
  try router.setModifiers([])
  try arm()
  try check(try router.press(id: 46, keysym: 0x6d, candidates: [0x6d]) == .init(.remote), "zero modifiers disables local shortcuts")
  let other = try NativeShortcutRouter()
  try check(try other.press(id: 46, keysym: 0x6d, candidates: [0x6d]) == .init(.remote), "surface state isolated")
  try router.setModifiers(.command)
  _ = try router.press(id: 55, keysym: 0xffeb, candidates: [])
  try check(try router.press(id: 46, keysym: 0x6d, candidates: [0x6d]) == .init(.contextMenu, release: true), "modifier reconfiguration clears old state")
  let bypass = try NativeShortcutRouter(modifiers: .control)
  _ = try bypass.press(id: -1, keysym: 0xffe3, candidates: [])
  _ = try bypass.press(id: -2, keysym: 0x20, candidates: [0x20]); _ = try bypass.release(id: -2)
  for id in Int32(0)..<1023 { _ = try bypass.press(id: id, keysym: 0x61, candidates: [0x61]) }
  do { _ = try bypass.press(id: 1024, keysym: 0x61, candidates: []); throw Failure(message: "Unbounded bypass") }
  catch let error as NativeError { try check(error.status == .resourceLimit, "bypass bookkeeping bound") }
  do { try bypass.setModifiers(.init(rawValue: 16)); throw Failure(message: "Invalid router mask") }
  catch let error as NativeError { try check(error.status == .invalidArgument, "router validates mask") }
  try check(try bypass.release(id: 1) == .init(.remote), "failed changes preserve bypass")
  try check(try bypass.press(id: 1024, keysym: 0x61, candidates: []) == .init(.remote), "bypass slot recovery")
  try bypass.reset()
  _ = try bypass.press(id: -1, keysym: 0xffe3, candidates: [])
  try check(try bypass.release(id: -1) == .init(.releaseKeyboard, release: true), "focus reset clears bypass")
  print("PASS native decisions: layout variants, actions, release intent, repeats, modifier-only unarm, Space bypass and isolation")
}
@main struct NativeShortcutTests {
  @MainActor static func main() {
    do { try classifier(); try routing() }
    catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
