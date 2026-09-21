// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNCNative
struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw Failure(message:message) }
}
func expect(_ problem: NativeInvocationProblem, _ argument: UInt32, _ inputs: [String]) throws {
  do { _ = try NativeInvocationSyntax(arguments:inputs); throw Failure(message:"invalid invocation accepted") }
  catch let error as NativeInvocationFailure {
    try check(error.problem == problem && error.argument == argument,"typed failure and argument position")
    try check(!error.description.contains("private"),"redacted diagnostic")
  }
}
@main struct NativeInvocationTests {
  static func main() async throws {
    var args = ["-passwd","/fixture/秘密\\q\n", "fixture-host", "--Shared", "off", "FullColour=on", "-Shared"]
    let parsed = try NativeInvocationSyntax(arguments:args); args.removeAll()
    try check(parsed.action == .launch && parsed.operand == "fixture-host" && parsed.operandArgument == 3,"copied operand")
    try check(parsed.assignments.count == 4,"all ordered occurrences retained")
    let path = parsed.assignments[0]
    try check(path.name == "PasswordFile" && path.value == "/fixture/秘密\\q\n" && path.category == .credentialFile,"copied raw path without IO/unescape")
    try check(path.argument == 1 && path.valueArgument == 2,"source positions")
    try check(parsed.assignments[1].value == "off" && parsed.assignments[2].name == "FullColor" && parsed.assignments[3].valueArgument == 0,"lookahead aliases and implicit true")
    let catalog = try NativeInvocationSyntax.options()
    try check(catalog.count > 40 && Set(catalog.map(\.name)).count == catalog.count,"bounded unique catalog")
    try check(catalog.contains { $0.name == "PasswordFile" && $0.alias == "passwd" && !$0.boolean },"shared catalog alias")
    for option in catalog where !option.available {
      try expect(.unavailable,1,["-"+option.name+"=private-value"])
    }
    for (flag,action) in [("--help",NativeInvocationAction.help),("--version",.version)] {
      let terminal = try NativeInvocationSyntax(arguments:["-PasswordFile=private-path",flag,"--unknown"])
      try check(terminal.action == action && terminal.assignments.count == 1 && terminal.operand == nil,"terminal actions retain preceding options for semantic validation")
    }
    let unvalidated = try NativeInvocationSyntax(arguments:["-Shared=broken","-Shared=off"])
    try check(unvalidated.assignments[0].value == "broken","syntax does not claim semantic validation or erase invalid duplicates")
    try expect(.unknownOption,1,["-Unknown=private-secret"])
    try expect(.missingValue,2,["private-host","-PasswordFile"])
    try expect(.extraOperand,2,["private-host","private-other"])
    try expect(.nullByte,1,["private\0secret"])
    try expect(.tooManyArguments,0,Array(repeating:"",count:4097))
    try expect(.tooLarge,1,[String(repeating:"é",count:32769)])
    let large = try NativeInvocationSyntax(arguments:["-PasswordFile",String(repeating:"x",count:65536)])
    try check(large.assignments[0].value.utf8.count == 65536,"CLI paths do not inherit file-line limits")
    try await withThrowingTaskGroup(of:Void.self) { group in
      for _ in 0..<8 { group.addTask {
        for _ in 0..<50 {
          let value = try NativeInvocationSyntax(arguments:["-Shared","host"])
          try check(value.operand == "host" && value.assignments[0].value == "1","concurrent independent copies")
        }
      } }
      try await group.waitForAll()
    }
    print("PASS invocation syntax, catalog, ownership, literal values, redaction and concurrent copies")
  }
}
