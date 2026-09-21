// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws { if !value() { throw Failure(message:message) } }
@MainActor final class Sink {
  var requests: [NativeDocumentOpenRequest] = []
  func receive(_ value: NativeDocumentOpenRequest) { requests.append(value) }
}
@main struct NativeDocumentLaunchTests {
  @MainActor static func main() throws {
    let router = NativeDocumentLaunchRouter(), first = Sink(), second = Sink()
    try check(router.route(filePaths:["/first.tidyvnc","/second.tigervnc"],workingDirectory:"/invocation"),"cold launch batch admitted")
    try check(router.pendingCount == 2 && first.requests.isEmpty,"queued until window action available")
    router.install { first.receive($0) }
    try check(router.pendingCount == 0 && first.requests.map(\.url.path) == ["/first.tidyvnc","/second.tigervnc"],"cold batch delivered in order")
    try check(first.requests.allSatisfy { $0.workingDirectory == "/invocation" },"invocation context retained")
    let firstID = first.requests[0].id
    try check(router.route(filePaths:["/first.tidyvnc"]),"repeat explicit open admitted")
    try check(first.requests.count == 3 && first.requests[2].id != firstID,"repeated open creates a distinct review")
    router.install { second.receive($0) }
    try check(second.requests.isEmpty,"replacement action does not replay drained requests")
    try check(router.route(filePaths:["/third.tidyvnc"]),"warm open admitted")
    try check(second.requests.count == 1 && first.requests.count == 3,"current action receives subsequent requests")
    for batch in [["/valid.tidyvnc","relative"],["/bad\0name"],["/"+String(repeating:"x",count:4096)],Array(repeating:"/many",count:65)] {
      try check(!router.route(filePaths:batch),"invalid entire batch rejected")
      try check(second.requests.count == 1 && router.pendingCount == 0,"no partial batch dispatch")
    }
    router.stop(); router.install { first.receive($0) }
    try check(!router.route(filePaths:["/after-quit"]) && first.requests.count == 3,"quit revokes current and late actions")
    let full = NativeDocumentLaunchRouter()
    try check(full.route(filePaths:Array(repeating:"/same",count:64)),"exact pending bound")
    try check(!full.route(filePaths:["/overflow"]) && full.pendingCount == 64,"overflow leaves queue intact")
    full.stop(); full.install { first.receive($0) }
    try check(full.pendingCount == 0 && first.requests.count == 3,"stop discards undelivered startup queue")
    let nested = NativeDocumentLaunchRouter(), nestedSink = Sink()
    nested.install { value in
      nestedSink.receive(value)
      if nestedSink.requests.count == 1 { _ = nested.route(filePaths:["/nested"]); nested.install { nestedSink.receive($0) } }
    }
    try check(nested.route(filePaths:["/outer-one","/outer-two"]),"reentrant dispatch accepted")
    try check(nestedSink.requests.map(\.url.path) == ["/outer-one","/outer-two","/nested"],"reentrancy preserves queue order without duplication")
    nested.stop()
    let urlRouter = NativeDocumentLaunchRouter(), urlSink = Sink()
    urlRouter.install { urlSink.receive($0) }
    try check(urlRouter.route(urls:[URL(fileURLWithPath:"/with space.tidyvnc")]),"modern file URL admitted")
    try check(urlSink.requests.first?.url.path == "/with space.tidyvnc","URL decoding preserves path")
    for url in [URL(string:"https://example.invalid/file")!,URL(string:"file://remote.invalid/file")!] {
      try check(!urlRouter.route(urls:[URL(fileURLWithPath:"/valid"),url]) && urlSink.requests.count == 1,"nonlocal URL rejects entire batch")
    }
    urlRouter.stop()
    let stopping = NativeDocumentLaunchRouter(), stoppedSink = Sink()
    stopping.install { value in stoppedSink.receive(value); stopping.stop() }
    _ = stopping.route(filePaths:["/first","/never"])
    try check(stoppedSink.requests.count == 1 && stopping.pendingCount == 0,"stop during dispatch does not open another window")
    print("Native document cold/warm routing, batch bounds, identities and quit passed")
  }
}
