// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw Failure(message: message) }
}
func input(_ body: String) -> Data { Data(("TidyVNC Configuration file Version 1.0\n" + body).utf8) }
func expect(_ problem: NativeDocumentProblem, line: UInt32 = 0, _ action: () throws -> Void) throws {
  do { try action(); throw Failure(message: "Invalid document accepted") }
  catch let error as NativeDocumentFailure {
    try check(error.problem == problem && error.line == line, "typed problem and line")
    try check(!error.description.contains("private-host") && !error.description.contains("secret"), "redacted error")
  }
}
func parsing() throws {
  var bytes = input("#comment\n\nserverNAME=first\nServerName=héllo\\\\path\\nlast\nFuture=\\q\n");
  let parsed = try NativeConnectionDocument(data: bytes)
  bytes.removeAll()
  try check(!parsed.isLegacy && parsed.entries.count == 3, "owned parsed records")
  try check(parsed.entries[0].name == "serverNAME" && parsed.entries[0].line == 4, "case and physical line preserved")
  try check(parsed.entries[1].encodedValue == "héllo\\\\path\\nlast", "raw value is copied")
  let first = try parsed.decodedValue(at: 0), second = try parsed.decodedValue(at: 1)
  try check(first == "first" && second == "héllo\\path\nlast", "shared escape decoder")
  try expect(.invalidEscape, line: 6) { _ = try parsed.decodedValue(at: 2) }
  try expect(.invalidIndex) { _ = try parsed.decodedValue(at: -1) }
  try expect(.invalidIndex) { _ = try parsed.decodedValue(at: Int.max) }
  let legacy = try NativeConnectionDocument(data: Data("TigerVNC Configuration file Version 1.0\r\nServerName=fixture".utf8))
  try check(legacy.isLegacy && legacy.entries.count == 1, "legacy CRLF header and unterminated final line")
  try expect(.empty) { _ = try NativeConnectionDocument(data: Data()) }
  try expect(.invalidHeader, line: 1) { _ = try NativeConnectionDocument(data: Data("private-host".utf8)) }
  try expect(.invalidAssignment, line: 2) { _ = try NativeConnectionDocument(data: input("private-host")) }
  try expect(.nullByte, line: 2) { _ = try NativeConnectionDocument(data: input("ServerName=private-host\0")) }
  var invalidText = input("#"); invalidText.append(contentsOf: [0xc3,0x28])
  try expect(.invalidText) { _ = try NativeConnectionDocument(data: invalidText) }
  try expect(.tooLarge) { _ = try NativeConnectionDocument(data: Data(repeating: 10, count: NativeConnectionDocument.maximumBytes + 1)) }
  try expect(.lineTooLong, line: 2) { _ = try NativeConnectionDocument(data: input("#" + String(repeating: "x", count: 254))) }
  let many = input(String(repeating: "x=\n", count: NativeConnectionDocument.maximumEntries))
  let maximum = try NativeConnectionDocument(data: many)
  try check(maximum.entries.count == NativeConnectionDocument.maximumEntries, "entry limit is inclusive")
  try expect(.tooManyEntries, line: 4098) { _ = try NativeConnectionDocument(data: many + Data("x=\n".utf8)) }
}
func serialization() throws {
  let original: [NativeDocumentAssignment] = [.init("servername", "fixture\\path\n"), .init("Shared", "on"), .init("ServerName", "last")]
  let data = try NativeConnectionDocument.serialize(original)
  try check(String(data: data, encoding: .utf8) == "TidyVNC Configuration file Version 1.0\n\nServerName=fixture\\\\path\\n\nShared=on\nServerName=last\n", "canonical compatible output")
  let parsed = try NativeConnectionDocument(data: data)
  for i in original.indices {
    let value = try parsed.decodedValue(at: i)
    try check(value == original[i].value, "export/import round trip")
  }
  let empty = try NativeConnectionDocument(data: NativeConnectionDocument.serialize([]))
  try check(empty.entries.isEmpty, "empty explicit patch is a valid document")
  for name in ["Password", "PasswordFile", "UserName", "Via", "Future", "ServerName\nPassword", "DotWhenNoCursor"] {
    try expect(.invalidExportName) { _ = try NativeConnectionDocument.serialize([.init(name,"secret")]) }
  }
  try expect(.nullByte) { _ = try NativeConnectionDocument.serialize([.init("ServerName","private-host\0")]) }
  try expect(.lineTooLong) { _ = try NativeConnectionDocument.serialize([.init("ServerName",String(repeating:"é",count:122))]) }
  try expect(.lineTooLong) { _ = try NativeConnectionDocument.serialize([.init("ServerName",String(repeating:"\\",count:122))]) }
  try expect(.lineTooLong) { _ = try NativeConnectionDocument.serialize([.init("ServerName",String(repeating:"x",count:256))]) }
  try expect(.tooManyEntries) { _ = try NativeConnectionDocument.serialize(Array(repeating:.init("Shared","on"),count:4097)) }
  for value in [String(repeating:"é",count:121), String(repeating:"\\",count:121)] {
    let document = try NativeConnectionDocument(data: NativeConnectionDocument.serialize([.init("ServerName",value)]))
    let decoded = try document.decodedValue(at: 0)
    try check(decoded == value, "UTF-8 and escape byte limits round trip")
  }
}
func concurrent() async throws {
  let document = try NativeConnectionDocument(data: input("ServerName=shared\\\\path\nFuture=\\q\n"))
  try await withThrowingTaskGroup(of: Void.self) { group in
    for n in 0..<8 {
      group.addTask {
        for _ in 0..<100 {
          let value = try document.decodedValue(at: 0)
          try check(value == "shared\\path", "shared immutable reader")
          let address = "fixture-\(n)\\path"
          let copy = try NativeConnectionDocument(data: NativeConnectionDocument.serialize([.init("ServerName",address)]))
          let copied = try copy.decodedValue(at: 0)
          try check(copied == address, "independent concurrent serialization")
        }
      }
    }
    try await group.waitForAll()
  }
}
@main struct NativeConnectionDocumentTests {
  static func main() async throws {
    try parsing(); try serialization(); try await concurrent()
    print("Native connection-document syntax, export, ownership and concurrency passed")
  }
}
