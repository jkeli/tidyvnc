// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

// Carries retained migration flags and the inactive cursor shape across overlays.
// Produced by validated resolution, never loaded from native preference storage.
public struct NativeCompatibilityState: Sendable {
  public let cursorType: NativeCursorFallback
  public let dotWhenNoCursor: Bool
  public let fullscreenAllMonitors: Bool
  let dotSource: NativeOptionSource
  let allSource: NativeOptionSource
  let pendingFullscreen: NativeFullscreenOptions?
}

// Internal application of already validated canonical values. Both explicit
// documents and CLI overlays use this path, with their own source positions and
// provenance. No file-format serialization/line limits or IO are introduced.
struct NativeOptionOverlay: Sendable {
  let compatibility: NativeCompatibilityState
  let configuration: NativeSessionConfiguration
  let endpoint: String
  let cursorType: NativeCursorFallback
  let monitorNumbers: [Int]
  let monitorSource: NativeOptionSource?
  let resolvedMonitorMapping: [Int:NativeDisplayID]
  let explicitMonitorMapping: Bool
  let fieldPositions: [String:UInt32]
  init(fields: [String:String], positions: [String:UInt32], base: NativeSessionConfiguration,
       source: NativeOptionSource, legacyDisplays: [NativeDisplayID], workingDirectory: String?,
       monitorMapping: [Int:NativeDisplayID]?, compatibility: NativeCompatibilityState? = nil,
       deferDisplayMapping: Bool = false, availableDisplays: [NativeDisplayID]? = nil) throws {
    var sources = positions
    let encodingSchema = try NativeEncodingOptions.schema()
    func line(_ name: String) -> UInt32 { sources[name] ?? 0 }
    func failure(_ reason: NativeDocumentResolutionFailure.Reason, _ name: String) -> NativeDocumentResolutionFailure {
      .init(reason:reason,line:line(name))
    }
    func flag(_ name: String) -> Bool? { fields[name].map { $0 == "on" } }
    let dot = flag("DotWhenNoCursor") ?? compatibility?.dotWhenNoCursor ?? false
    let all = flag("FullScreenAllMonitors") ?? compatibility?.fullscreenAllMonitors ?? false
    let dotSource = fields["DotWhenNoCursor"] != nil ? source : (compatibility?.dotSource ?? source)
    let allSource = fields["FullScreenAllMonitors"] != nil ? source : (compatibility?.allSource ?? source)
    var value = base
    if let address = fields["ServerName"], !address.isEmpty {
      do { try NativeEndpoint.validate(address) }
      catch { throw failure(.invalidEndpoint,"ServerName") }
    }
    // The retained reader returns an empty address when ServerName is absent.
    // An explicit file must not silently connect to a different profile's host.
    endpoint = fields["ServerName"] ?? ""
    if let shared = flag("Shared") { value.shared = shared; value.sharedSource = source }
    if let retry = flag("ReconnectOnError") { value.reconnectOnError = retry; value.reconnectSource = source }
    if let send = flag("SendClipboard") { value.clipboardSend = send }
    if let receive = flag("AcceptClipboard") { value.clipboardReceive = receive }

    let encoding = encodingSchema.compactMap { field in
      fields[field.name].map { NativeEncodingAssignment(field.name,$0) }
    }
    if !encoding.isEmpty { value.encoding = try (base.encoding ?? NativeEncodingOptions()).applying(encoding,source:source) }
    var input = NativeInputPreferences()
    input.viewOnly = flag("ViewOnly"); input.emulateMiddle = flag("EmulateMiddleButton")
    input.fullscreenSystemKeys = flag("FullscreenSystemKeys")
    if let modifiers = fields["ShortcutModifiers"] {
      let flags: [String:UInt32] = ["Ctrl":1,"Shift":2,"Alt":4,"Super":8]
      input.shortcutModifiers = modifiers.split(separator:",").reduce(0) { $0 | (flags[String($1)] ?? 0) }
    }
    var always = flag("AlwaysCursor") ?? (base.input.cursorFallback != .hidden)
    var shape = fields["CursorType"].map { $0 == "System" ? NativeCursorFallback.system : .dot }
      ?? compatibility?.cursorType ?? (base.input.cursorFallback == .system ? .system : .dot)
    // Retained migration runs after all assignments, independent of line order.
    if dot {
      always = true; shape = .dot
      if let position = sources["DotWhenNoCursor"] {
        sources["AlwaysCursor"] = position; sources["CursorType"] = position
      }
    }
    if fields["AlwaysCursor"] != nil || fields["CursorType"] != nil || dot {
      input.cursorFallback = always ? shape : .hidden
    }
    cursorType = shape
    value = try input.applying(to:value,source:source)
    if dot { value.inputSources[.cursorFallback] = dotSource }

    var scaling = NativeScalingPreferences()
    scaling.scaling = fields["ScalingFactor"]
    scaling.devicePixels = fields["DesktopPixelUnits"].map { $0 == "Device" }
    scaling.filter = fields["ScalingQuality"]?.lowercased()
    if scaling.scaling != nil || scaling.devicePixels != nil || scaling.filter != nil {
      value = try scaling.applying(to:value,source:source)
    }
    if let types = fields["SecurityTypes"] {
      value = try NativeSecurityPreferences(types:types).applying(to:value,source:source)
    }
    func path(_ field: String) throws -> String? {
      guard let path = fields[field] else { return nil }
      if path.isEmpty || path.hasPrefix("/") { return path }
      guard let directory = workingDirectory, directory.hasPrefix("/"),
            directory.utf8.prefix(4097).count <= 4096, !directory.utf8.contains(0) else {
        throw failure(.relativePathNeedsBase,field)
      }
      // Preserve dot/parent components: lexical standardization can change the
      // OS meaning when an earlier component is a symlink. Do not expand '~'.
      let joined = directory + (directory.hasSuffix("/") ? "" : "/") + path
      guard NativeTrustFiles.isValidPath(joined) else { throw failure(.relativePathNeedsBase,field) }
      return joined
    }
    value = try NativeTrustFiles(caFile:path("X509CA"),crlFile:path("X509CRL")).applying(to:value)

    let fullscreen = (compatibility?.pendingFullscreen ?? NativeFullscreenOptions(base:base))
      .applying(fields:fields,source:source,all:all,allSource:allSource,
        preferredMapping:deferDisplayMapping ? monitorMapping : nil)
    monitorNumbers = fullscreen.numbers; monitorSource = fullscreen.numberSource
    if all, let position = sources["FullScreenAllMonitors"] { sources["FullScreenMode"] = position }
    if deferDisplayMapping {
      resolvedMonitorMapping = [:]; explicitMonitorMapping = false
    } else {
      let field = fields["FullScreenSelectedMonitors"] != nil || fullscreen.selectedNumbers != nil ? "FullScreenSelectedMonitors" : "FullScreenMode"
      // A surviving inherited CLI selection has no line in the current file.
      let position = fields["FullScreenSelectedMonitors"] != nil || fullscreen.numberSource == source ? line(field) : 0
      let resolved = try fullscreen.resolve(base:value,legacyDisplays:legacyDisplays,mapping:monitorMapping,
        availableDisplays:availableDisplays,line:position)
      value = resolved.configuration; resolvedMonitorMapping = resolved.mapping
      explicitMonitorMapping = resolved.explicit
    }
    self.compatibility = .init(cursorType:shape,dotWhenNoCursor:dot,fullscreenAllMonitors:all,
      dotSource:dotSource,allSource:allSource,pendingFullscreen:deferDisplayMapping ? fullscreen : nil)
    configuration = value; fieldPositions = sources
  }
}
