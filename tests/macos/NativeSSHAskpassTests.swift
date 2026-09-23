// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation
import AppKit
import SwiftUI
import NativeTestSupport
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ value: @autoclosure () throws -> Bool,_ message: String) throws {
  if try !value() { throw Failure(message:message) }
}
@MainActor func until(_ label: String,_ condition: () -> Bool) async throws {
  for _ in 0..<3000 { if condition() { return }; try await Task.sleep(for:.milliseconds(2)) }
  throw Failure(message:"Timed out: " + label)
}
final class Directory {
  let path: String
  init() throws {
    var pattern = Array("/tmp/tidy-askpass-XXXXXX".utf8CString)
    guard let path = mkdtemp(&pattern) else { throw Failure(message:"private directory") }
    self.path = String(cString:path)
  }
  deinit { try? FileManager.default.removeItem(atPath:path) }
}
@MainActor final class Helper {
  let process = Process(), output = Pipe(), error = Pipe()
  init(executable: String, directory: String, prompt: String = "Password:", hint: String? = nil) throws {
    process.executableURL = URL(fileURLWithPath:executable); process.arguments = [prompt]
    // Match the production's fixed search path so sanitizer runtimes can find
    // Apple's symbolizer; do not inherit the test runner's environment.
    var environment = ["PATH":"/usr/bin:/bin","LC_ALL":"C","TIDYVNC_ASKPASS_SOCKET":directory + "/askpass"]
    if let hint { environment["SSH_ASKPASS_PROMPT"] = hint }
    process.environment = environment; process.standardOutput = output; process.standardError = error
    process.standardInput = FileHandle.nullDevice; try process.run()
  }
  func result() async throws -> (Int32,Data) {
    try await until("helper exit") { !self.process.isRunning }
    try check(error.fileHandleForReading.readDataToEndOfFile().isEmpty,"helper errors never reflect prompts or responses")
    return (process.terminationStatus,output.fileHandleForReading.readDataToEndOfFile())
  }
}
@MainActor func answer(_ model: NativeSSHInteraction, _ text: String) throws {
  var bytes = Array(text.utf8)
  try model.respond(model.question!.id,bytes:&bytes)
  try check(bytes.allSatisfy { $0 == 0 },"caller response consumed")
}
@MainActor func requests(executable: String) async throws {
  let directory = try Directory(), model = NativeSSHInteraction()
  let request = try NativeSSHTunnelRequest(endpoint:"remote.invalid",gateway:"alice@gateway.invalid")
  let server = try NativeSSHAskpass(directory:directory.path,request:request) { await model.ask($0) }
  for (hint,kind,reply) in [(nil,NativeSSHQuestion.Kind.response,"fixture-password"),("confirm",.permission,"yes"),("none",.notification,"")] {
    let helper = try Helper(executable:executable,directory:directory.path,hint:hint)
    try await until("question") { model.question != nil }
    let question = model.question!
    try check(question.gateway == request.gateway && question.endpoint == request.endpoint && question.kind == kind && question.text == "Password:","copied question has immutable route context and hint")
    try check(!String(describing:question).contains("Password") && !String(reflecting:question).contains("gateway"),"question descriptions are redacted")
    for invalid in [Array(repeating:UInt8(65),count:1024),[65,0,66],[65,10,66],[65,13,66]] {
      var bytes = invalid
      do { try model.respond(question.id,bytes:&bytes); throw Failure(message:"invalid SSH response admitted") }
      catch NativeTunnelError.invalidRequest {}
      try check(bytes.allSatisfy { $0 == 0 } && model.question?.id == question.id,"rejected response consumed without answering")
    }
    try answer(model,reply)
    let result = try await helper.result()
    try check(result.0 == 0 && result.1 == Data((reply + "\n").utf8),"exact bounded response reaches only helper stdout")
    var stale = Array("stale-secret".utf8)
    do { try model.respond(question.id,bytes:&stale); throw Failure(message:"stale reply") }
    catch let error as NativeError { try check(error.status == .stale && stale.allSatisfy { $0 == 0 },"stale response rejected and cleared") }
  }
  await server.close(); await server.close()
  try check(!FileManager.default.fileExists(atPath:directory.path + "/askpass"),"joined socket cleanup")
}
@MainActor func cancellation(executable: String) async throws {
  for close in [false,true] {
    let directory = try Directory(), model = NativeSSHInteraction()
    let request = try NativeSSHTunnelRequest(endpoint:"remote",gateway:"gateway")
    let server = try NativeSSHAskpass(directory:directory.path,request:request) { await model.ask($0) }
    let helper = try Helper(executable:executable,directory:directory.path)
    try await until("pending question") { model.question != nil }
    if close { await server.close() } else { helper.process.terminate() }
    try await until("cancelled presentation") { model.question == nil }
    let result = try await helper.result()
    try check(result.0 != 0 && result.1.isEmpty,"cancel never becomes affirmative or a partial response")
    await server.close()
    try check(!FileManager.default.fileExists(atPath:directory.path + "/askpass"),"cancelled worker joined")
  }
  let model = NativeSSHInteraction(), request = try NativeSSHTunnelRequest(endpoint:"remote",gateway:"gateway")
  let question = NativeSSHQuestion(gateway:request.gateway,endpoint:request.endpoint,kind:.response,text:"Password:")
  let task = Task { await model.ask(question) }; task.cancel()
  let result = await task.value
  try check(result == nil && model.question == nil,"cancellation before prompt publication")
  model.stop(); let stopped = await model.ask(question)
  try check(stopped == nil,"closed interaction refuses further prompts")
}
@MainActor func isolation(executable: String) async throws {
  let a = try Directory(), b = try Directory(), first = NativeSSHInteraction(), second = NativeSSHInteraction()
  let ra = try NativeSSHTunnelRequest(endpoint:"same-target",gateway:"alice@gateway")
  let rb = try NativeSSHTunnelRequest(endpoint:"same-target",gateway:"bob@gateway")
  let sa = try NativeSSHAskpass(directory:a.path,request:ra) { await first.ask($0) }
  let sb = try NativeSSHAskpass(directory:b.path,request:rb) { await second.ask($0) }
  let ha = try Helper(executable:executable,directory:a.path), hb = try Helper(executable:executable,directory:b.path)
  try await until("independent requests") { first.question != nil && second.question != nil }
  try check(first.question?.gateway != second.question?.gateway,"route context isolated")
  await sa.close(); _ = try await ha.result()
  try check(second.question != nil && hb.process.isRunning,"closing one owner does not cancel another")
  try answer(second,"second-secret"); let result = try await hb.result()
  try check(result.1 == Data("second-secret\n".utf8),"response goes only to matching helper")
  await sb.close()
}
@MainActor func unsafeInputs(executable: String) async throws {
  let request = try NativeSSHTunnelRequest(endpoint:"remote",gateway:"gateway"), directory = try Directory()
  let leaf = directory.path + "/askpass", marker = Data("keep".utf8)
  try marker.write(to:URL(fileURLWithPath:leaf))
  do { _ = try NativeSSHAskpass(directory:directory.path,request:request) { _ in nil }; throw Failure(message:"existing leaf overwritten") }
  catch NativeTunnelError.privateSocketUnavailable {}
  try check(try Data(contentsOf:URL(fileURLWithPath:leaf)) == marker,"existing leaf preserved")
  let bad = try Helper(executable:executable,directory:directory.path)
  let result = try await bad.result(); try check(result.0 != 0 && result.1.isEmpty,"helper rejects non-socket leaf")
  try FileManager.default.removeItem(atPath:leaf)
  try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:directory.path)
  do { _ = try NativeSSHAskpass(directory:directory.path,request:request) { _ in nil }; throw Failure(message:"public directory admitted") }
  catch NativeTunnelError.privateSocketUnavailable {}
  try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:directory.path)
  let model = NativeSSHInteraction()
  let server = try NativeSSHAskpass(directory:directory.path,request:request) { await model.ask($0) }
  for (prompt,hint) in [(String(repeating:"x",count:8193),nil),("Password:","unknown"),("The authenticity of host 'gateway (127.0.0.1)' cannot be established",nil)] {
    let helper = try Helper(executable:executable,directory:directory.path,prompt:prompt,hint:hint)
    let result = try await helper.result(); try check(result.0 != 0 && result.1.isEmpty,"bounded strict helper preflight")
  }
  await server.close()
}
func configuredFixture(request: NativeSSHTunnelRequest, key: String, known: String, keyAlias: String? = nil, configuration: String? = nil) async throws -> NativeSSHPreparedGateway {
  let source = URL(fileURLWithPath:configuration ?? known + ".config")
  let root = source.deletingLastPathComponent()
  let text = "Host configured-fixture\n HostName " + request.gatewayHost + "\n User " + request.gatewayUser! +
    "\n Port \(request.gatewayPort)\n IdentityFile \"" + key + "\"\n IdentitiesOnly yes\n IdentityAgent none\n UserKnownHostsFile \"" + known +
    "\"\n GlobalKnownHostsFile /dev/null\n LogLevel QUIET\n LogVerbose *\n" + (keyAlias.map { " HostKeyAlias " + $0 + "\n" } ?? "")
  try Data(text.utf8).write(to:source)
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:source.path)
  return try await NativeSSHPreparedGateway.prepare(requested:NativeSSHGateway("configured-fixture"),root:source,includeBase:root,home:root)
}
@MainActor func realSSH(gateway: String, key: String, known: String, helper: String) async throws {
  let model = NativeSSHInteraction()
  for (cancel,configured) in [(true,false),(false,false),(true,true),(false,true)] {
    guard let peer = native_test_peer_create(0) else { throw Failure(message:"RFB peer") }
    defer { native_test_peer_destroy(peer) }
    let request = try NativeSSHTunnelRequest(endpoint:"127.0.0.1::\(native_test_peer_port(peer))",gateway:gateway)
    let paths = PathCapture(), owner: NativeSSHTunnel
    var preparedPath: String?
    if configured {
      let prepared = try await configuredFixture(request:request,key:key,known:known)
      preparedPath = prepared.configurationURL.deletingLastPathComponent().path
      owner = try NativeSSHTunnel(prepared:prepared,endpoint:request.endpoint,authentication:.init(helper:URL(fileURLWithPath:helper),interaction:model))
    } else { owner = NativeSSHTunnel(request:request,executable:"/usr/bin/ssh",timeout:.seconds(15),
      authentication:.init(helper:URL(fileURLWithPath:helper),interaction:model)) { command,socket in
      paths.set(socket)
      return ["-i",key,"-o","IdentitiesOnly=yes","-o","IdentityAgent=none","-o","UserKnownHostsFile=\(known)",
        "-o","GlobalKnownHostsFile=/dev/null"] + request.arguments(command,socket:socket,interactive:true)
    }
    }
    let starting = Task { try await owner.start() }
    try await until("actual SSH passphrase") { model.question != nil }
    try check(model.question?.kind == .response && model.question?.gateway == request.gateway,"actual SSH prompt route")
    if cancel {
      starting.cancel()
      do { _ = try await starting.value; throw Failure(message:"cancelled SSH authenticated") } catch is CancellationError {}
      await owner.close()
      try check(model.question == nil,"startup cancellation drains actual SSH prompt")
    } else {
      try answer(model,"fixture-key-passphrase")
      let route = try await starting.value
      let runtime = try NativeRuntime(); var configuration = NativeSessionConfiguration(); configuration.securityTypes = [1]
      let session = try runtime.makeSession(configuration:configuration)
      do {
        let result = try await session.connect(endpoint:route.endpoint,through:route.localEndpoint,routeIdentity:route.routeIdentity)
        try check(result.snapshot.state == .connected,"actual encrypted-key SSH and routed RFB")
        try await session.close(); await owner.close(); try await runtime.shutdown()
      } catch { try? await session.close(); await owner.close(); try? await runtime.shutdown(); throw error }
    }
    if let preparedPath { try check(!FileManager.default.fileExists(atPath:preparedPath),"configured authentication snapshot joined") }
    else { try check(paths.path != nil && !FileManager.default.fileExists(atPath:URL(fileURLWithPath:paths.path!).deletingLastPathComponent().path),"SSH helper/master/socket directory joined") }
  }
  print("PASS actual OpenSSH encrypted-key prompt, cancellation, routed RFB and joined cleanup")
}
@MainActor func hostKeyReview(gateway: String, key: String, known: String, helper: String) async throws {
  let helperDirectory = try Directory()
  let quotedHelper = helperDirectory.path + "/helper space'\"%$"
  try FileManager.default.createSymbolicLink(atPath:quotedHelper,withDestinationPath:URL(fileURLWithPath:helper).path)
  let request = try NativeSSHTunnelRequest(endpoint:"remote.invalid",gateway:gateway)
  let expected = try String(contentsOfFile:known + ".fingerprint",encoding:.utf8)
  let changedBefore = try Data(contentsOf:URL(fileURLWithPath:known + ".changed"))
  let model = NativeSSHInteraction()
  for configured in [false,true] {
    let knownBase = configured ? helperDirectory.path + "/configured-known" : known
    func aliasBytes(_ bytes: Data) -> Data {
      let text = String(decoding:bytes,as:UTF8.self)
      return Data(("configured-key " + text.split(separator:" ",maxSplits:1).last!).utf8)
    }
    let trustedBytes = configured ? aliasBytes(try Data(contentsOf:URL(fileURLWithPath:known))) : try Data(contentsOf:URL(fileURLWithPath:known))
    let changedBytes = configured ? aliasBytes(changedBefore) : changedBefore
    if configured {
      try trustedBytes.write(to:URL(fileURLWithPath:knownBase))
      try changedBytes.write(to:URL(fileURLWithPath:knownBase + ".changed"))
      try (Data("@revoked ".utf8) + trustedBytes).write(to:URL(fileURLWithPath:knownBase + ".revoked"))
    }
  for mode in ["cancel","save","repeat","save-failure","save-failure-auth","changed","revoked"] {
    print("CHECK host-key mode=\(mode), configured=\(configured)")
    let file = knownBase + ((mode == "changed" || mode == "revoked") ? "." + mode : mode == "cancel" ? ".cancelled" : ".new")
    // A regular file in the parent position makes saving impossible, even when
    // the fixture is run with elevated filesystem privileges.
    let blocked = knownBase + ".blocked"
    if mode.hasPrefix("save-failure") { try Data("not a directory".utf8).write(to:URL(fileURLWithPath:blocked)) }
    let effectiveFile = mode.hasPrefix("save-failure") ? blocked + "/known_hosts" : file
    let paths = PathCapture(), owner: NativeSSHTunnel
    var preparedPath: String?
    if configured {
      let prepared = try await configuredFixture(request:request,key:key,known:effectiveFile,keyAlias:"configured-key",configuration:knownBase + ".config")
      preparedPath = prepared.configurationURL.deletingLastPathComponent().path
      owner = try NativeSSHTunnel(prepared:prepared,endpoint:request.endpoint,authentication:.init(helper:URL(fileURLWithPath:quotedHelper),interaction:model))
    } else { owner = NativeSSHTunnel(request:request,executable:"/usr/bin/ssh",timeout:.seconds(15),
      authentication:.init(helper:URL(fileURLWithPath:quotedHelper),interaction:model)) { command,socket in
      paths.set(socket)
      return ["-i",key,"-o","IdentitiesOnly=yes","-o","IdentityAgent=none","-o","UserKnownHostsFile=\(effectiveFile)",
        "-o","GlobalKnownHostsFile=/dev/null"] + request.arguments(command,socket:socket,interactive:true)
    }
    }
    var startFailure: (any Error)?
    let starting = Task {
      do { return try await owner.start() }
      catch { startFailure = error; throw error }
    }
    do {
      if mode == "changed" || mode == "revoked" {
        do { _ = try await starting.value; throw Failure(message:"changed key connected") }
        catch NativeTunnelError.startupFailed {}
        try check(model.question == nil,"changed key cannot be approved as new")
        try check(try Data(contentsOf:URL(fileURLWithPath:file)) == (mode == "changed" ? changedBytes : Data("@revoked ".utf8) + trustedBytes),"changed/revoked key never overwritten")
      } else {
        try await until("host-key or password request: \(mode), configured=\(configured)") { model.question != nil || startFailure != nil }
        if let startFailure { throw startFailure }
        if mode != "repeat" {
          try check(model.question?.kind == .hostKey && model.question?.hostKey?.fingerprint == expected,"offered key fingerprint independently verified")
          try check(!FileManager.default.fileExists(atPath:effectiveFile),"no trust write before approval")
          if mode == "cancel" {
            model.cancel()
            do { _ = try await starting.value; throw Failure(message:"cancelled key connected") }
            catch NativeTunnelError.startupFailed {}
            try check(!FileManager.default.fileExists(atPath:file),"cancel leaves known hosts absent")
          } else {
            var generic = Array("yes".utf8)
            do { try model.respond(model.question!.id,bytes:&generic); throw Failure(message:"unbound host-key response") }
            catch NativeTunnelError.invalidRequest {}
            try check(generic.allSatisfy { $0 == 0 },"rejected generic approval consumed")
            try answer(model,expected)
            try await until("passphrase after explicit trust") { model.question != nil }
          }
        }
        if mode != "cancel" {
          try check(model.question?.kind == .response,"known or just-approved key proceeds to authentication")
          if mode == "save-failure-auth" { model.cancel() }
          else { try answer(model,"fixture-key-passphrase") }
          if mode.hasPrefix("save-failure") {
            do { _ = try await starting.value; throw Failure(message:"unsaved gateway key admitted forwarding") }
            catch NativeTunnelError.hostKeySaveFailed {}
            try check(!FileManager.default.fileExists(atPath:effectiveFile),"failed save leaves no trusted key")
          } else {
            _ = try await starting.value
            try check(try Data(contentsOf:URL(fileURLWithPath:file)) == trustedBytes,"SSH saved exactly the reviewed key")
          }
        }
      }
      await owner.close()
      if let preparedPath { try check(!FileManager.default.fileExists(atPath:preparedPath),"configured host-key helper and snapshot cleanup") }
      else { try check(paths.path != nil && !FileManager.default.fileExists(atPath:URL(fileURLWithPath:paths.path!).deletingLastPathComponent().path),"host-key helper cleanup") }
    } catch { starting.cancel(); await owner.close(); _ = try? await starting.value; throw error }
  }
  }
  print("PASS new SSH host-key cancel/save/reconnect, independent fingerprint and changed/revoked-key rejection")
}
final class PathCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?
  func set(_ value: String) { lock.withLock { self.value = value } }
  var path: String? { lock.withLock { value } }
}
func fixtureKey() -> String {
  let name = Array("ssh-ed25519".utf8)
  return Data([0,0,0,UInt8(name.count)] + name + [0,0,0,32] + Array(repeating:UInt8(1),count:32)).base64EncodedString()
}
func keyValidation() throws {
  let marker = Array("Failed to add the host to the list of known hosts (".utf8)
  for split in 0...marker.count {
    let classifier = NativeSSHSaveFailure()
    classifier.consume(Array("remote banner\n".utf8)[...])
    classifier.consume(marker.prefix(split)); classifier.consume(marker.dropFirst(split))
    classifier.consume(Array("private path ignored).\r\n".utf8)[...])
    try check(classifier.failed,"fragmented host-key write failure is detected")
  }
  let unrelated = NativeSSHSaveFailure()
  unrelated.consume(Array("untrusted prefix ".utf8)[...]); unrelated.consume(marker[...])
  try check(!unrelated.failed,"embedded diagnostics cannot masquerade as the fixed log prefix")

  let gateway = try NativeSSHGateway("gateway.invalid")
  let record = "gateway.invalid\nssh-ed25519\n" + fixtureKey()
  let key = NativeSSHHostKey(record:record,gateway:gateway)
  try check(key != nil,"valid structured Ed25519 key")
  let aliasedRecord = record.replacingOccurrences(of:"gateway.invalid",with:"configured-key")
  try check(NativeSSHHostKey(record:aliasedRecord,expectedHostname:"configured-key") != nil &&
            NativeSSHHostKey(record:aliasedRecord,expectedHostname:"gateway.invalid") == nil,
            "observer binds the prepared key lookup identity")
  for invalid in [record + "\n", record.replacingOccurrences(of:"gateway.invalid",with:"other.invalid"),
    record.replacingOccurrences(of:"ssh-ed25519",with:"ssh-rsa"), "gateway.invalid\nssh-ed25519\n////",
    "gateway.invalid\nssh-ed25519\n" + Data([255,255,255,255]).base64EncodedString()] {
    try check(NativeSSHHostKey(record:invalid,gateway:gateway) == nil,"malformed, misbound or mismatched key rejected")
  }
  let prompt = "The authenticity of host 'gateway.invalid (127.0.0.1)' can't be established.\nED25519 key fingerprint is: " + key!.fingerprint + "\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "
  try check(key!.matchesConfirmation(prompt),"key-bound confirmation")
  try check(!key!.matchesConfirmation(prompt.replacingOccurrences(of:"gateway.invalid",with:"other.invalid")),"confirmation hostname bound")
  try check(!key!.matchesConfirmation(prompt.replacingOccurrences(of:key!.fingerprint,with:"SHA256:unrelated")),"confirmation fingerprint bound")
}
@MainActor func renderPrompts(directory: URL? = nil) async throws {
  _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
  let directory = directory ?? URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("ssh-render")
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  for dark in [false,true] {
    for kind in [NativeSSHQuestion.Kind.response,.permission,.notification,.hostKey] {
      let model = NativeSSHInteraction()
      let text = kind == .response ? "Enter passphrase for key '/Users/example/.ssh/id_ed25519':" : String(repeating:"Untrusted SSH request text, shown literally. [Link](https://example.invalid) ",count:100)
      let gateway = try NativeSSHGateway("alice@" + String(repeating:"long-gateway-name",count:200) + ".invalid")
      let key = NativeSSHHostKey(record:gateway.host + "\nssh-ed25519\n" + fixtureKey(),gateway:gateway)
      let request = NativeSSHQuestion(gateway:gateway,endpoint:"remote-desktop.invalid:3",kind:kind,text:text,hostKey:kind == .hostKey ? key : nil)
      let host = NSHostingController(rootView:SSHAuthenticationSheet(interaction:model,request:request,cancel:{})
        .environment(\.layoutDirection,CommandLine.arguments.contains("--rtl") ? .rightToLeft : .leftToRight)
        .environment(\.colorScheme,dark ? .dark : .light).background(Color(nsColor:.windowBackgroundColor)))
      host.sizingOptions = []
      let size = NSSize(width:460,height:570)
      let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.titled],backing:.buffered,defer:false)
      window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
      window.contentViewController = host; window.setContentSize(size)
      defer { window.contentViewController = nil; window.close() }
      let view = host.view
      view.layoutSubtreeIfNeeded(); try await Task.sleep(for:.milliseconds(100)); view.layoutSubtreeIfNeeded()
      let fitting = host.sizeThatFits(in:size)
      try check(view.bounds.size == size && fitting.width <= size.width && fitting.height <= size.height,
        "SSH prompt fits bounded window: \(fitting), actual \(view.bounds.size)")
      func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
      }
      let scrolls = scrollViews(view)
      try check(scrolls.count == 1,"SSH details have one scroll area")
      guard let scroll = scrolls.first, let document = scroll.documentView else { throw Failure(message:"SSH details missing") }
      for bottom in [false,true] {
        document.scroll(NSPoint(x:0,y:bottom ? document.bounds.maxY : 0)); scroll.reflectScrolledClipView(scroll.contentView)
        if bottom && kind != .response {
          try check(document.bounds.height > scroll.contentView.bounds.height && scroll.contentView.bounds.origin.y > 0,
            "Complete long SSH request reachable without growing the sheet")
        }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw Failure(message:"SSH bitmap") }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:view.bounds,to:bitmap) }
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw Failure(message:"SSH PNG") }
        try data.write(to:directory.appendingPathComponent("ssh-\(kind.rawValue)\(bottom ? "-end" : "")\(dark ? "-dark" : "").png"))
      }
    }
  }
}
@main enum NativeSSHAskpassTests {
  @MainActor static func main() async {
    do {
      if CommandLine.arguments.count == 6, CommandLine.arguments[1] == "--ssh" {
        try await realSSH(gateway:CommandLine.arguments[2],key:CommandLine.arguments[3],known:CommandLine.arguments[4],helper:CommandLine.arguments[5])
        try await hostKeyReview(gateway:CommandLine.arguments[2],key:CommandLine.arguments[3],known:CommandLine.arguments[4],helper:CommandLine.arguments[5]); return
      }
      if CommandLine.arguments.contains("--render-only") {
        try await renderPrompts(directory:URL(fileURLWithPath:CommandLine.arguments[1])); return
      }
      try keyValidation()
      let executable = CommandLine.arguments[1]
      try await requests(executable:executable); try await cancellation(executable:executable)
      try await isolation(executable:executable); try await unsafeInputs(executable:executable)
      try await renderPrompts()
      print("PASS private SSH askpass transport, response bounds, route isolation, cancellation and joined cleanup")
    } catch let error as NativeSSHConfigurationIssue {
      let reason: String
      switch error {
      case .failed: reason = "process failed"
      case .timedOut: reason = "process timed out"
      case .invalidOutput: reason = "invalid output"
      case .changedPolicy: reason = "changed policy"
      }
      FileHandle.standardError.write(Data("FAIL: SSH configuration \(reason)\n".utf8)); exit(1)
    } catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
  }
}
