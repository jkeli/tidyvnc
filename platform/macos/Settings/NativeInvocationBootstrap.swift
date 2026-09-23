// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Foundation

public enum NativeInvocationArguments {
  // argv excludes argv[0]. Decode strictly before constructing Swift strings;
  // replacement characters must not change an endpoint, option or file path.
  public static func decode(_ arguments: [Data]) throws -> [String] {
    guard arguments.count <= NativeInvocationSyntax.maximumArguments else {
      throw NativeInvocationFailure(problem:.tooManyArguments,argument:0)
    }
    var total = 0, result: [String] = []
    for (index,bytes) in arguments.enumerated() {
      let argument = UInt32(index+1)
      guard bytes.count <= NativeInvocationSyntax.maximumArgumentBytes,
            bytes.count <= NativeInvocationSyntax.maximumBytes-total else {
        throw NativeInvocationFailure(problem:.tooLarge,argument:argument)
      }
      total += bytes.count
      guard !bytes.contains(0) else { throw NativeInvocationFailure(problem:.nullByte,argument:argument) }
      guard let value = String(data:bytes,encoding:.utf8) else {
        throw NativeInvocationFailure(problem:.invalidText,argument:argument)
      }
      result.append(value)
    }
    return result
  }
  // Kernel-provided C argv must contain argc valid pointers to terminated strings.
  // The bounded scan does not depend on CommandLine.arguments' lossy conversion.
  public static func read(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> [String] {
    guard argc >= 1 else { throw NativeInvocationFailure(problem:.invalidText,argument:0) }
    guard argc-1 <= NativeInvocationSyntax.maximumArguments else {
      throw NativeInvocationFailure(problem:.tooManyArguments,argument:0)
    }
    var input: [Data] = [], total = 0
    for index in 1..<Int(argc) {
      guard let value = argv[index] else { throw NativeInvocationFailure(problem:.invalidText,argument:UInt32(index)) }
      let count = strnlen(value,NativeInvocationSyntax.maximumArgumentBytes+1)
      guard count <= NativeInvocationSyntax.maximumArgumentBytes, count <= NativeInvocationSyntax.maximumBytes-total else {
        throw NativeInvocationFailure(problem:.tooLarge,argument:UInt32(index))
      }
      total += count; input.append(Data(bytes:value,count:count))
    }
    return try decode(input)
  }
}

public struct NativeInvocationTerminal: Sendable {
  public let text: String
  public let exitCode: Int32
}
public enum NativeInvocationPathKind: Sendable { case socket, file }
public protocol NativeInvocationPathInspecting: Sendable {
  func kind(at path: String) -> NativeInvocationPathKind
}
public struct NativeInvocationPathInspector: NativeInvocationPathInspecting {
  public init() {}
  public func kind(at path: String) -> NativeInvocationPathKind {
    var info = stat()
    // Match the retained path/socket distinction. Failed stat, missing files,
    // directories and devices go through the bounded regular-file reader, which
    // reports their error without reading a FIFO or another special file.
    return path.withCString { stat($0,&info) == 0 && info.st_mode & S_IFMT == S_IFSOCK } ? .socket : .file
  }
}
public struct NativeInvocationLaunch: Sendable {
  public let invocation: NativeInvocationRequest
  public let document: NativeDocumentOpenRequest?
  public var listen: NativeListenOptions? = nil
  public var credentials: NativeLaunchCredentialInputs? = nil
  public var connectsOnReady: Bool { listen == nil && document == nil && !invocation.endpoint.isEmpty }
}
public enum NativeInvocationBootstrap {
  public static func terminal(_ options: NativeInvocationOptions, version: String, copyright: String = "") throws -> NativeInvocationTerminal? {
    guard options.action != .launch else { return nil }
    _ = try NativeProcessLogging.selection(options)
    var text = "TidyVNC v\(version)\n" + String(localized:"invocation.viewer", defaultValue:"Native macOS viewer") + "\n"
    if !copyright.isEmpty { text += copyright + "\n" }
    if options.action == .version { return .init(text:text,exitCode:0) }
    // Command grammar is literal; localized prose receives it as arguments.
    let forms = "vncviewer [parameters] [host][:display]\n       vncviewer [parameters] [host][::port]\n       vncviewer [parameters] [path/to/socket]\n       vncviewer [parameters] [./connection.tidyvnc]\n       vncviewer -listen [parameters] [port]"
    text += "\n" + String(localized:"invocation.help.usage", defaultValue:"Usage: \(forms)") + "\n\n"
    text += "-h, --help       " + String(localized:"invocation.help.help.action", defaultValue:"Show this help (exit status 1, matching the retained viewer).") + "\n"
    text += "-v, --version    " + String(localized:"invocation.help.version.action", defaultValue:"Show the version.") + "\n\n"
    text += String(localized:"invocation.help.syntax", defaultValue:"Names are case-insensitive. Enable a boolean with \("-Name"); disable it with\n\("-Name=off"). Values accept \("-Name value"), \("Name=value"), \("-Name=value") or \("--Name=value").\nUse \("./") before a relative file name; a bare name is a server address.\nExplicit files override CLI settings and open for review before connecting.\nWith no server address, a connection form opens. Native defaults use native\nstores; importing compatibility defaults/history is a separate explicit action.") + "\n\n"
    text += String(localized:"invocation.help.parameters", defaultValue:"Parameters (* requires a native adapter; unavailable entries cannot be used):") + "\n"
    let supported = try NativeInvocationResolution.supportedOptions()
    var defaults = Dictionary(uniqueKeysWithValues:try NativeEncodingOptions.schema().map { ($0.name,$0.defaultValue) })
    defaults["MaxCutText"] = String(try NativeMessageLimits.defaultMaxCutText())
    defaults["PointerEventInterval"] = String(try NativePointerTiming.defaultMilliseconds())
    defaults["Log"] = NativeProcessLogging.defaultPolicy
    for option in try NativeInvocationSyntax.options() {
      let status = !option.available ? String(localized:"invocation.help.unavailable", defaultValue:" [unavailable]") : (supported.contains(option.name) ? "" : " *")
      let alias = option.alias.isEmpty ? "" : String(localized:"invocation.help.alias", defaultValue:" (alias: \(option.alias))")
      let value = option.boolean ? "[on|off]" : String(localized:"invocation.help.value", defaultValue:"<value>")
      let initial = defaults[option.name].map { String(localized:"invocation.help.default", defaultValue:" [default: \($0)]") } ?? ""
      text += "  \(option.name) \(value)\(alias)\(initial)\(status)\n"
    }
    text += String(localized:"invocation.help.failure.alerts", defaultValue:"\n\("AlertOnFatalError=off") closes the affected connection or failed listener when no Retry action is available.\n\("ReconnectOnError=on") still offers Retry for eligible outgoing connection errors. Other windows and the application remain open.\n")
    text += String(localized:"invocation.help.logging", defaultValue:"\nLog targets: \("stderr, stdout, file"), or empty to disable.\nFile: \("/tmp/vncviewer.log"), created on first output with one \(".bak"); failures use \("stderr").\n")
    text += String(localized:"invocation.help.listen", defaultValue:"Listen defaults to TCP port 5500; port 0 chooses an available port. Use a decimal port from 0 to 65535.\nWith \("-listen ./file.tidyvnc"), review file settings before binding; \("ServerName") supplies the port. Unix socket listeners are unsupported.\nAccept each incoming connection in the listener window.\n")
    text += String(localized:"invocation.help.credentials", defaultValue:"Legacy password files apply only to password-only authentication. \("VNC_PASSWORD") (with \("VNC_USERNAME") when required) takes precedence.\nLaunch credentials belong to the first connection window (first accepted incoming window with \("-listen")) and are never saved.\nStopping the listener clears unclaimed launch credentials.\n")
    text += String(localized:"invocation.help.adapters", defaultValue:"Unsupported native adapters fail explicitly; their parameters are never ignored.\n")
    text += String(localized:"invocation.help.ssh", defaultValue:"SSH \("via") accepts \("[user@]host") or \("ssh://[user@]host[:port]"). It uses SSH host-key verification, default-key/agent authentication and native password/passphrase prompts.\nNew Ed25519/RSA/ECDSA gateway keys require explicit \(String(localized:"ssh.trust.and.save", defaultValue:"Trust and Save")); changed keys are rejected.\nSupported \("~/.ssh/config") settings are captured before connecting; commands, proxy hops and \("VNC_VIA_CMD") are unsupported.\nSSH forwarding cannot be used with \("-listen") or Unix socket targets. An empty \("via") value selects a direct connection.\n")
    return .init(text:text,exitCode:1)
  }
  // Startup-only metadata inspection, before AppKit/store initialization. No file
  // contents, environment credentials, sockets or settings stores are opened.
  public static func launch(_ options: NativeInvocationOptions, workingDirectory: String,
                            inspector: any NativeInvocationPathInspecting = NativeInvocationPathInspector(),
                            customTunnelCommandPresent: Bool = false) throws -> NativeInvocationLaunch {
    guard workingDirectory.hasPrefix("/"), NativeTrustFiles.isValidPath(workingDirectory) else {
      throw NativeInvocationResolutionFailure(reason:.relativePathNeedsBase,argument:0)
    }
    // Check every native option before inspecting a path. Numeric display mapping
    // waits for current displays and optional explicit-file precedence in the UI.
    _ = try NativeInvocationPreparation(options:options,endpoint:"",base:.init(),legacyDisplays:[],
      workingDirectory:workingDirectory,monitorMapping:nil,deferDisplayMapping:true)
    if customTunnelCommandPresent, try NativeInvocationRouting.gateway(options) != nil {
      throw NativeInvocationResolutionFailure(reason:.customTunnelCommandUnsupported,argument:0)
    }
    if options.assignments.last(where:{ $0.name == "listen" })?.value == "on" {
      let operand = options.operand
      var listen = NativeListenOptions()
      listen.ipv4 = options.assignments.last(where:{ $0.name == "UseIPv4" })?.value != "off"
      listen.ipv6 = options.assignments.last(where:{ $0.name == "UseIPv6" })?.value != "off"
      guard listen.ipv4 || listen.ipv6 else {
        throw NativeInvocationResolutionFailure(reason:.invalidValue,
          argument:options.assignments.last(where:{ $0.name == "UseIPv4" || $0.name == "UseIPv6" })?.argument ?? 0)
      }
      var document: NativeDocumentOpenRequest?
      if let operand, operand.contains("/") || operand.contains("\\") {
        let path = operand.hasPrefix("/") ? operand : workingDirectory + (workingDirectory.hasSuffix("/") ? "" : "/") + operand
        guard NativeTrustFiles.isValidPath(path) else {
          throw NativeInvocationResolutionFailure(reason:.invalidEndpoint,argument:options.operandArgument)
        }
        guard inspector.kind(at:path) != .socket else {
          throw NativeInvocationResolutionFailure(reason:.listenSocketUnsupported,argument:options.operandArgument)
        }
        document = .init(url:URL(fileURLWithPath:path),workingDirectory:workingDirectory)
      } else if let operand {
        guard let port = NativeListenPort.parse(operand) else {
          throw NativeInvocationResolutionFailure(reason:.invalidListenPort,argument:options.operandArgument)
        }
        listen.port = port
      }
      return .init(invocation:.init(options:options,endpoint:"",workingDirectory:workingDirectory),document:document,listen:listen)
    }
    var endpoint = options.operand ?? ""
    var document: NativeDocumentOpenRequest?
    if endpoint.contains("/") || endpoint.contains("\\") {
      let path = endpoint.hasPrefix("/") ? endpoint : workingDirectory + (workingDirectory.hasSuffix("/") ? "" : "/") + endpoint
      guard NativeTrustFiles.isValidPath(path) else {
        throw NativeInvocationResolutionFailure(reason:.invalidEndpoint,argument:options.operandArgument)
      }
      if inspector.kind(at:path) == .socket { endpoint = path }
      else { document = .init(url:URL(fileURLWithPath:path),workingDirectory:workingDirectory); endpoint = "" }
    }
    if !endpoint.isEmpty {
      do { try NativeEndpoint.validate(endpoint) }
      catch { throw NativeInvocationResolutionFailure(reason:.invalidEndpoint,argument:options.operandArgument) }
    }
    let request = NativeInvocationRequest(options:options,endpoint:endpoint,workingDirectory:workingDirectory)
    _ = try request.gateway(endpoint:endpoint)
    return .init(invocation:request,document:document)
  }
}

// One process-local request, consumed once by the first ordinary connection
// window. No Codable conformance, restoration payload, IPC or relaunch argv.
@MainActor public final class NativeInvocationStartup {
  private var pending: NativeInvocationLaunch?
  public init(_ launch: NativeInvocationLaunch? = nil) { pending = launch }
  public func take() -> NativeInvocationLaunch? { defer { pending = nil }; return pending }
  public func stop() { pending?.credentials?.clear(); pending = nil }
}
