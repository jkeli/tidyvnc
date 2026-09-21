// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNCNative
struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
  if !value() { throw Failure(message:message) }
}
@main struct NativeProcessLoggingTests {
  @MainActor static func main() async throws {
    let defaults = try NativeProcessLogging.selection(NativeInvocationOptions(arguments:[]))
    try check(defaults == "*:stderr:30","retained default process policy")
    let last = try NativeProcessLogging.selection(NativeInvocationOptions(arguments:["-Log=*:stderr:100","-Log=*::0"]))
    try check(last == "*::0","last complete policy replaces earlier assignment")
    for args in [["-Log=private:stderr:30","-Log=*::0"],["-Log=*:syslog:30"],["-Log=*:private:30","--help"]] {
      do { _ = try NativeProcessLogging.selection(NativeInvocationOptions(arguments:args)); throw Failure(message:"invalid route accepted") }
      catch let failure as NativeInvocationResolutionFailure {
        let reason: NativeInvocationResolutionFailure.Reason = args[0].contains("private:stderr") ? .invalidValue : .unsupportedOption
        try check(failure.reason == reason && failure.argument == 1,"every route validated")
        try check(!failure.description.contains("private"),"redacted route failure")
      }
    }
    try NativeProcessLogging.validate("*:file:100")
    let options = try NativeInvocationOptions(arguments:["-Log=*::0"])
    try NativeProcessLogging.start(options)
    let runtime = try NativeRuntime(); try await runtime.shutdown()
    do { try NativeProcessLogging.start(options); throw Failure(message:"late process mutation accepted") }
    catch let failure as NativeError { try check(failure.status == .busy,"startup stays closed after runtime shutdown") }
    try NativeProcessLogging.validate("*:stdout:100")
    print("PASS native logging selection, startup and runtime lifetime")
  }
}
