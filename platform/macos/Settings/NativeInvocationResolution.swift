// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

// Created by a host only after classifying the operand and capturing launch cwd.
// Separate from Finder/Open requests; consumed once by native app startup.
public struct NativeInvocationRequest: Sendable {
  public let options: NativeInvocationOptions
  public let endpoint: String, workingDirectory: String
  public let monitorMapping: [Int:NativeDisplayID]?
  public init(options: NativeInvocationOptions, endpoint: String, workingDirectory: String,
              monitorMapping: [Int:NativeDisplayID]? = nil) {
    self.options = options; self.endpoint = endpoint; self.workingDirectory = workingDirectory
    self.monitorMapping = monitorMapping
  }
  // Options have already passed per-occurrence shared boolean validation.
  // Also available before a session exists, for fatal startup/listener failures.
  public var alertOnFatalError: Bool {
    options.assignments.last(where:{ $0.name == "AlertOnFatalError" })?.value != "off"
  }
  // Routing is launch metadata, not an ordinary setting or compatibility file
  // field. Resolve it against the final reviewed target before session creation.
  public func gateway(inheriting inherited: NativeSSHGateway? = nil, endpoint: String = "") throws -> NativeSSHGateway? {
    let gateway = try NativeInvocationRouting.gateway(options, inheriting:inherited)
    if let gateway, !endpoint.isEmpty {
      do { _ = try NativeSSHTunnelRequest(endpoint:endpoint,gateway:gateway) }
      catch { throw NativeInvocationResolutionFailure(reason:.invalidTunnelTarget,argument:options.operandArgument) }
    }
    return gateway
  }
}

enum NativeInvocationRouting {
  static func gateway(_ options: NativeInvocationOptions, inheriting inherited: NativeSSHGateway? = nil) throws -> NativeSSHGateway? {
    var gateway = inherited
    for field in options.assignments where field.name == "via" {
      do { gateway = field.value.isEmpty ? nil : try NativeSSHGateway(field.value) }
      catch { throw NativeInvocationResolutionFailure(reason:.invalidValue,argument:field.argument) }
    }
    if gateway != nil, options.assignments.last(where:{ $0.name == "listen" })?.value == "on" {
      throw NativeInvocationResolutionFailure(reason:.tunnelListenUnsupported,argument:options.assignments.last(where:{ $0.name == "via" })?.argument ?? 0)
    }
    return gateway
  }
}

public struct NativeInvocationResolutionFailure: Error, Sendable, Equatable, CustomStringConvertible {
  public enum Reason: Sendable { case notLaunch, unsupportedOption, invalidEndpoint, invalidValue, displayMappingRequired, relativePathNeedsBase, invalidListenPort, listenSocketUnsupported, invalidTunnelTarget, tunnelListenUnsupported, customTunnelCommandUnsupported }
  public let reason: Reason
  public let argument: UInt32
  public var description: String {
    let message: String
    switch reason {
    case .notLaunch: message = String(localized:"document.help.and.version.requests.do.not.create.a.connection", defaultValue:"Help and version requests do not create a connection.")
    case .unsupportedOption: message = String(localized:"document.a.command.line.option.needs.a.native.adapter.that.is.not.available", defaultValue:"A command-line option needs a native adapter that is not available yet.")
    case .invalidEndpoint: message = String(localized:"document.the.command.line.server.address.is.invalid", defaultValue:"The command-line server address is invalid.")
    case .invalidValue: message = String(localized:"document.a.command.line.value.cannot.be.applied.to.this.connection", defaultValue:"A command-line value cannot be applied to this connection.")
    case .displayMappingRequired: message = String(localized:"document.resolve.the.command.line.monitor.selection.before.continuing", defaultValue:"Resolve the command-line monitor selection before continuing.")
    case .relativePathNeedsBase: message = String(localized:"document.resolve.the.command.line.file.path.before.continuing", defaultValue:"Resolve the command-line file path before continuing.")
    case .invalidListenPort: message = String(localized:"document.the.listen.port.must.be.a.decimal.number.from.0.to.65535", defaultValue:"The listen port must be a decimal number from 0 to 65535.")
    case .listenSocketUnsupported: message = String(localized:"document.listening.on.a.unix.socket.is.not.supported.supply.a.tcp.port", defaultValue:"Listening on a Unix socket is not supported. Supply a TCP port or connection file instead.")
    case .invalidTunnelTarget: message = String(localized:"document.ssh.forwarding.requires.a.supported.tcp.server.address.unix.socket.targets.are", defaultValue:"SSH forwarding requires a supported TCP server address. Unix socket targets are not supported.")
    case .tunnelListenUnsupported: message = String(localized:"document.ssh.forwarding.cannot.be.combined.with.listening.for.connections", defaultValue:"SSH forwarding cannot be combined with listening for connections.")
    case .customTunnelCommandUnsupported: message = String(localized:"document.vnc.via.cmd.shell.customizations.are.not.supported.unset.vnc.via.cmd", defaultValue:"VNC_VIA_CMD shell customizations are not supported. Unset VNC_VIA_CMD to use native SSH forwarding.")
    }
    return argument == 0 ? message : String(localized:"document.error.argument", defaultValue:"Argument \(argument.formatted()): \(message)")
  }
}

// Transactional CLI overlay on a resolved defaults/profile base. The host must
// classify the positional operand before supplying an endpoint here; this type
// never guesses whether a path names a configuration file or a Unix socket.
// Explicit files must subsequently apply NativeDocumentResolution to this value.
public struct NativeInvocationResolution: Sendable {
  public static func supportedOptions() throws -> Set<String> {
    let encoding = try NativeEncodingOptions.schema()
    let common = Set(encoding.map(\.name) + ["Shared","ReconnectOnError","AcceptClipboard","SendClipboard",
      "ViewOnly","EmulateMiddleButton","FullscreenSystemKeys","ShortcutModifiers","AlwaysCursor","CursorType",
      "DotWhenNoCursor","ScalingFactor","ScalingQuality","DesktopPixelUnits","SecurityTypes","X509CA","X509CRL",
      "FullScreen","FullScreenMode","FullScreenSelectedMonitors","FullScreenAllMonitors"])
    let additional: Set<String> = ["AlertOnFatalError","DesktopSize","RemoteResize","GnuTLSPriority","UseIPv4","UseIPv6","PointerEventInterval","MaxCutText","geometry","Maximize","Log","PasswordFile","listen","via"]
    return common.union(additional)
  }
  init(prepared: NativeInvocationPreparation, endpoint: String, legacyDisplays: [NativeDisplayID],
       monitorMapping: [Int:NativeDisplayID]?, availableDisplays: [NativeDisplayID]) throws {
    do {
      let overlay = try NativeOptionOverlay(fields:[:],positions:prepared.overlay.fieldPositions,base:prepared.configuration,
        source:.commandLine,legacyDisplays:legacyDisplays,workingDirectory:nil,monitorMapping:monitorMapping,
        compatibility:prepared.overlay.compatibility,availableDisplays:availableDisplays)
      compatibility = overlay.compatibility; configuration = overlay.configuration
      self.endpoint = endpoint; cursorType = overlay.cursorType
      monitorNumbers = overlay.monitorNumbers; fieldArguments = overlay.fieldPositions
    } catch let error as NativeDocumentResolutionFailure {
      throw NativeInvocationResolutionFailure(reason:error.reason == .displayMappingRequired ? .displayMappingRequired : .invalidValue,
        argument:error.line)
    }
  }
  public let compatibility: NativeCompatibilityState
  public let configuration: NativeSessionConfiguration
  public let endpoint: String
  public let cursorType: NativeCursorFallback
  public let monitorNumbers: [Int]
  public let fieldArguments: [String:UInt32]
  public init(options: NativeInvocationOptions, endpoint: String, base: NativeSessionConfiguration = .init(),
              legacyDisplays: [NativeDisplayID] = [], workingDirectory: String? = nil,
              monitorMapping: [Int:NativeDisplayID]? = nil) throws {
    let prepared = try NativeInvocationPreparation(options:options,endpoint:endpoint,base:base,
      legacyDisplays:legacyDisplays,workingDirectory:workingDirectory,monitorMapping:monitorMapping,deferDisplayMapping:false)
    compatibility = prepared.overlay.compatibility; configuration = prepared.configuration
    self.endpoint = endpoint; cursorType = prepared.overlay.cursorType
    monitorNumbers = prepared.overlay.monitorNumbers; fieldArguments = prepared.overlay.fieldPositions
  }
}

// Internal candidate only: pending monitor values are not a public resolved
// invocation and must pass a final file/display resolution before admission.
struct NativeInvocationPreparation: Sendable {
  let overlay: NativeOptionOverlay
  let configuration: NativeSessionConfiguration
  init(options: NativeInvocationOptions, endpoint: String, base: NativeSessionConfiguration,
       legacyDisplays: [NativeDisplayID], workingDirectory: String?,
       monitorMapping: [Int:NativeDisplayID]?, deferDisplayMapping: Bool) throws {
    guard options.action == .launch else { throw NativeInvocationResolutionFailure(reason:.notLaunch,argument:0) }
    _ = try NativeLaunchCredentialInputs.passwordFile(options,workingDirectory:workingDirectory)
    _ = try NativeInvocationRouting.gateway(options)
    let supported = try NativeInvocationResolution.supportedOptions()
    var fields: [String:String] = [:], positions: [String:UInt32] = [:]
    var geometry: NativeWindowGeometry?
    for field in options.assignments {
      guard supported.contains(field.name) else {
        throw NativeInvocationResolutionFailure(reason:.unsupportedOption,argument:field.argument)
      }
      if field.name == "geometry" {
        do { geometry = try NativeWindowGeometry(field.value) }
        catch { throw NativeInvocationResolutionFailure(reason:.invalidValue,argument:field.argument) }
      }
      if field.name == "Log" {
        try NativeProcessLogging.validate(field)
      }
      var value = field.value
      if field.name == "DesktopSize" {
        do { value = try Self.initialSize(value) }
        catch { throw NativeInvocationResolutionFailure(reason:.invalidValue,argument:field.argument) }
      }
      if field.name == "GnuTLSPriority", field.value.utf8.count > 4096 {
        throw NativeInvocationResolutionFailure(reason:.invalidValue,argument:field.argument)
      }
      fields[field.name] = value; positions[field.name] = field.argument
    }
    if !endpoint.isEmpty {
      do { try NativeEndpoint.validate(endpoint) }
      catch { throw NativeInvocationResolutionFailure(reason:.invalidEndpoint,argument:options.operandArgument) }
    }
    do {
      let overlay = try NativeOptionOverlay(fields:fields,positions:positions,base:base,source:.commandLine,
        legacyDisplays:legacyDisplays,workingDirectory:workingDirectory,monitorMapping:monitorMapping,
        deferDisplayMapping:deferDisplayMapping)
      var value = overlay.configuration
      if let alert = fields["AlertOnFatalError"] { value.alertOnFatalError = alert == "on" }
      if fields["geometry"] != nil {
        value.windowStartupPolicy.geometry = geometry; value.windowStartupSources[.geometry] = .commandLine
      }
      if let maximize = fields["Maximize"] {
        value.windowStartupPolicy.maximize = maximize == "on"; value.windowStartupSources[.maximize] = .commandLine
      }
      if let interval = fields["PointerEventInterval"] {
        guard let milliseconds = UInt32(interval), milliseconds <= UInt32(Int32.max) else {
          throw NativeInvocationResolutionFailure(reason:.invalidValue,argument:positions["PointerEventInterval"] ?? 0)
        }
        value.pointerEventIntervalMilliseconds = milliseconds; value.pointerEventIntervalSource = .commandLine
      }
      if let limit = fields["MaxCutText"] {
        guard let bytes = UInt32(limit), bytes <= UInt32(Int32.max) else {
          throw NativeInvocationResolutionFailure(reason:.invalidValue,argument:positions["MaxCutText"] ?? 0)
        }
        value.maxCutText = bytes; value.maxCutTextSource = .commandLine
      }
      if let ipv4 = fields["UseIPv4"] {
        value.networkPolicy.ipv4 = ipv4 == "on"; value.networkSources[.ipv4] = .commandLine
      }
      if let ipv6 = fields["UseIPv6"] {
        value.networkPolicy.ipv6 = ipv6 == "on"; value.networkSources[.ipv6] = .commandLine
      }
      value = try NativeRemoteResizePreferences(enabled:fields["RemoteResize"].map { $0 == "on" },initialSize:fields["DesktopSize"])
        .applying(to:value,source:.commandLine)
      value = try NativeSecurityPreferences(tlsPriority:fields["GnuTLSPriority"]).applying(to:value,source:.commandLine)
      self.overlay = overlay; configuration = value
    } catch let failure as NativeDocumentResolutionFailure {
      let reason: NativeInvocationResolutionFailure.Reason
      switch failure.reason {
      case .displayMappingRequired: reason = .displayMappingRequired
      case .relativePathNeedsBase: reason = .relativePathNeedsBase
      case .invalidEndpoint: reason = .invalidEndpoint
      default: reason = .invalidValue
      }
      throw NativeInvocationResolutionFailure(reason:reason,argument:failure.line)
    } catch { throw NativeInvocationResolutionFailure(reason:.invalidValue,argument:0) }
  }
  private static func initialSize(_ input: String) throws -> String {
    if input.isEmpty { return "" }
    // Retained DesktopWindow uses sscanf("%dx%d"): decimal/sign/leading C
    // whitespace, literal x, then a decimal height; trailing text is ignored.
    // Parse with checked arithmetic instead of sscanf's overflowing int writes.
    let bytes = Array(input.utf8); var index = 0
    func number() throws -> UInt32 {
      while index < bytes.count && [9,10,11,12,13,32].contains(bytes[index]) { index += 1 }
      if index < bytes.count && bytes[index] == 43 { index += 1 }
      let start = index; var value: UInt32 = 0
      while index < bytes.count && (48...57).contains(bytes[index]) {
        value = value * 10 + UInt32(bytes[index]-48)
        guard value <= 65535 else { throw NativePreferencesError.invalidValue }
        index += 1
      }
      guard index > start && value > 0 else { throw NativePreferencesError.invalidValue }
      return value
    }
    let width = try number()
    guard index < bytes.count, bytes[index] == 120 else { throw NativePreferencesError.invalidValue }
    index += 1
    let height = try number()
    return "\(width)x\(height)"
  }
}
