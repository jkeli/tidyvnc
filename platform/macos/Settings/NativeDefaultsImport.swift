// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

public enum NativeImportOrigin: String, Codable, CaseIterable, Sendable { case currentXDG, legacy }
public enum NativeDefaultsImportCategory: String, CaseIterable, Sendable { case connection, clipboard, encoding, input, scaling, fullscreen }
public struct NativeDefaultsImportNotice: Sendable, Equatable {
  public enum Kind: Sendable { case excluded, unknown, platformOnly, displayMapping, inactiveCursor }
  public let line: UInt32
  public let name: String
  public let kind: Kind
}
public enum NativeDefaultsImportError: Error, Equatable, Sendable {
  case reviewRequired, unrepresentable
}

// An explicit defaults-import projection, never an explicit-file session overlay.
// Source bytes and excluded values are not retained in this review object.
public struct NativeDefaultsImport: Identifiable, Sendable {
  public let id = UUID()
  public let origin: NativeImportOrigin
  public let notices: [NativeDefaultsImportNotice]
  public let categories: Set<NativeDefaultsImportCategory>
  private let candidate: NativePreferences
  public func preferences(acknowledging lines: Set<UInt32> = []) throws -> NativePreferences {
    guard Set(notices.map(\.line)).isSubset(of:lines) else { throw NativeDefaultsImportError.reviewRequired }
    return candidate
  }
  public init(data: Data, origin: NativeImportOrigin, legacyDisplays: [NativeDisplayID] = []) throws {
    try self.init(projection:NativeDefaultsImportProjection(data:data,origin:origin),legacyDisplays:legacyDisplays)
  }
  init(projection: NativeDefaultsImportProjection, legacyDisplays: [NativeDisplayID] = [],
       monitorMapping: [Int:NativeDisplayID]? = nil) throws {
    let schema = try NativeEncodingOptions.schema()
    var notices = projection.notices
    let resolved = try NativeDocumentResolution(document:projection.document,legacyDisplays:legacyDisplays,monitorMapping:monitorMapping)
    let config = try resolved.configuration(), fields = resolved.fieldLines
    func has(_ name: String) -> Bool { fields[name] != nil }
    var value = NativePreferences(), categories: Set<NativeDefaultsImportCategory> = []
    if has("Shared") { value.shared = config.shared }
    if has("ReconnectOnError") { value.reconnectOnError = config.reconnectOnError }
    if value.shared != nil || value.reconnectOnError != nil { categories.insert(.connection) }
    if has("SendClipboard") { value.clipboardSend = config.clipboardSend }
    if has("AcceptClipboard") { value.clipboardReceive = config.clipboardReceive }
    if value.clipboardSend != nil || value.clipboardReceive != nil { categories.insert(.clipboard) }
    var encoding = NativeEncodingPreferences()
    for field in schema where has(field.name) {
      guard let options = config.encoding else { throw NativeDefaultsImportError.unrepresentable }
      try encoding.set(field.id,value:options.value(for:field.id).value)
    }
    if encoding != NativeEncodingPreferences() { value.encoding = encoding; categories.insert(.encoding) }
    var input = NativeInputPreferences()
    if has("ViewOnly") { input.viewOnly = config.input.viewOnly }
    if has("EmulateMiddleButton") { input.emulateMiddle = config.input.emulateMiddle }
    if has("FullscreenSystemKeys") { input.fullscreenSystemKeys = config.input.fullscreenSystemKeys }
    if has("ShortcutModifiers") { input.shortcutModifiers = config.input.shortcutModifiers.rawValue }
    if has("AlwaysCursor") || has("CursorType") { input.cursorFallback = config.input.cursorFallback }
    if input != NativeInputPreferences() { value.input = input; categories.insert(.input) }
    if input.cursorFallback == .hidden, resolved.cursorType == .system {
      notices.append(.init(line:fields["CursorType"] ?? fields["AlwaysCursor"]!,name:"CursorType",kind:.inactiveCursor))
    }
    var scaling = NativeScalingPreferences()
    if has("ScalingFactor") { scaling.scaling = config.scaling?.canonical }
    if has("ScalingQuality") { scaling.filter = config.scaling?.filter.storageToken }
    if has("DesktopPixelUnits") { scaling.devicePixels = config.scaling?.devicePixels }
    if scaling != NativeScalingPreferences() { value.scaling = scaling; categories.insert(.scaling) }
    var fullscreen = NativeFullscreenPreferences()
    if has("FullScreen") { fullscreen.startsFullscreen = config.fullscreenPolicy.startsFullscreen }
    if has("FullScreenMode") { fullscreen.mode = config.fullscreenPolicy.mode.rawValue }
    if has("FullScreenSelectedMonitors") || fullscreen.mode == "selected" {
      fullscreen.selectedDisplays = config.fullscreenPolicy.selectedDisplays.map(\.rawValue)
      if !config.fullscreenPolicy.selectedDisplays.isEmpty {
        notices.append(.init(line:fields["FullScreenSelectedMonitors"] ?? fields["FullScreenMode"]!,name:"FullScreenSelectedMonitors",kind:.displayMapping))
      }
    }
    if fullscreen != NativeFullscreenPreferences() { value.fullscreen = fullscreen; categories.insert(.fullscreen) }
    // This closed assignment list is the security boundary. No security, trust,
    // endpoint, credentials, tunnel or arbitrary source metadata reaches values.
    candidate = value; self.origin = projection.origin; self.categories = categories
    self.notices = notices.sorted { $0.line == $1.line ? $0.name < $1.name : $0.line < $1.line }
  }
}

// The only retained source for mapping recovery is this allow-listed projection.
// Excluded/unknown values exist only during the initial bounded parse, never in a
// review, mapping request or the preference candidate.
struct NativeDefaultsImportProjection: Sendable {
  let document: NativeConnectionDocument
  let origin: NativeImportOrigin
  let notices: [NativeDefaultsImportNotice]
  let monitorNumbers: [Int]
  init(data: Data, origin: NativeImportOrigin) throws {
    let source = try NativeConnectionDocument(data:data)
    let schema = try NativeEncodingOptions.schema()
    let allowed = Set(schema.map(\.name) + ["Shared","ReconnectOnError","AcceptClipboard","SendClipboard",
      "ViewOnly","EmulateMiddleButton","FullscreenSystemKeys","ShortcutModifiers","AlwaysCursor","CursorType",
      "DotWhenNoCursor","ScalingFactor","ScalingQuality","DesktopPixelUnits","FullScreen","FullScreenMode",
      "FullScreenSelectedMonitors","FullScreenAllMonitors"])
    let excluded: Set<String> = ["servername","securitytypes","x509ca","x509crl","tlspriority",
      "password","passwd","passwordfile","username","user","via","tunnel","security","trust"]
    var notices: [NativeDefaultsImportNotice] = []
    var filtered = Data("TidyVNC Configuration file Version 1.0\n".utf8), nextLine: UInt32 = 2
    for index in source.entries.indices {
      let entry = source.entries[index]
      let name = String(decoding:entry.name.utf8.map { (65...90).contains($0) ? $0+32 : $0 },as:UTF8.self)
      if ["audio","sendprimary","setprimary"].contains(name) {
        notices.append(.init(line:entry.line,name:entry.name,kind:.platformOnly)); continue
      }
      // Validate recognized occurrences even when excluded, matching retained
      // import's malformed-known-field behavior. Unknown fields stay undecoded.
      let field = try source.validatedOption(at:index)
      if excluded.contains(name) {
        notices.append(.init(line:entry.line,name:entry.name,kind:.excluded)); continue
      }
      guard let field else { notices.append(.init(line:entry.line,name:entry.name,kind:.unknown)); continue }
      guard allowed.contains(field.name) else { throw NativeDefaultsImportError.unrepresentable }
      // Preserve original line numbers and deprecated fields for the existing
      // resolver. Dropped fields become blank lines, never serialized secrets.
      filtered.append(contentsOf:repeatElement(UInt8(10),count:Int(entry.line-nextLine)))
      filtered.append(contentsOf:(entry.name+"="+entry.encodedValue+"\n").utf8)
      nextLine = entry.line+1
    }
    if nextLine > 2 { filtered.removeLast() } // Do not add a byte to a full-size source lacking a final newline.
    document = try NativeConnectionDocument(data:filtered)
    self.origin = origin; self.notices = notices
    monitorNumbers = try NativeDocumentMonitorMapping.numbers(document:document)
  }
}
