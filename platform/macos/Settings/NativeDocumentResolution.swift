// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

public struct NativeDocumentNotice: Equatable, Sendable {
  public enum Kind: Sendable { case unknownField, platformOnly }
  public let kind: Kind
  public let line: UInt32
  // No value is included: unknown fields can contain private input.
  public let name: String
}
public struct NativeDocumentResolutionFailure: Error, Equatable, Sendable, CustomStringConvertible {
  public enum Reason: Sendable { case reviewRequired, invalidEndpoint, displayMappingRequired, relativePathNeedsBase, unrepresentableField }
  public let reason: Reason
  public let line: UInt32
  public var description: String {
    switch reason {
    case .reviewRequired: "Review the ignored connection-file fields before continuing."
    case .invalidEndpoint: "The connection file contains an invalid server address."
    case .displayMappingRequired: "Resolve the connection file's monitor selection before continuing."
    case .relativePathNeedsBase: "Resolve the connection file's relative verification-file path before continuing."
    case .unrepresentableField: "The connection file contains a setting this native viewer cannot apply."
    }
  }
}

// Explicit-file overlay onto an already resolved base. Callers supply the legacy
// monitor numbering and invocation working directory; no implicit filesystem,
// display, native-store or legacy-default lookups happen during resolution.
public struct NativeDocumentResolution: Sendable {
  public let compatibility: NativeCompatibilityState
  public let document: NativeConnectionDocument
  public let endpoint: String
  public let notices: [NativeDocumentNotice]
  public let fieldLines: [String:UInt32]
  public let monitorNumbers: [Int]
  public let monitorSource: NativeOptionSource?
  public let resolvedMonitorMapping: [Int:NativeDisplayID]
  public let explicitMonitorMapping: Bool
  // Keep the inactive cursor shape, which a hidden native cursor alone cannot
  // represent. A later file export must retain it or report conversion loss.
  public let cursorType: NativeCursorFallback
  private let candidate: NativeSessionConfiguration

  // Explicit review is required for unknown/platform-only fields. Known malformed
  // or unavailable values always fail initialization; they cannot be ignored here.
  public func configuration(acknowledging lines: Set<UInt32> = []) throws -> NativeSessionConfiguration {
    guard Set(notices.map(\.line)).isSubset(of: lines) else {
      throw NativeDocumentResolutionFailure(reason:.reviewRequired,line:0)
    }
    return candidate
  }
  public init(document: NativeConnectionDocument, base: NativeSessionConfiguration = .init(),
              legacyDisplays: [NativeDisplayID] = [], workingDirectory: String? = nil,
              monitorMapping: [Int:NativeDisplayID]? = nil, compatibility: NativeCompatibilityState? = nil,
              availableDisplays: [NativeDisplayID]? = nil) throws {
    self.document = document
    var fields: [String:String] = [:], sources: [String:UInt32] = [:], ignored: [NativeDocumentNotice] = []
    let encodingSchema = try NativeEncodingOptions.schema()
    let supported = Set(encodingSchema.map(\.name) + ["ServerName","Shared","ReconnectOnError",
      "AcceptClipboard","SendClipboard","ViewOnly","EmulateMiddleButton","FullscreenSystemKeys",
      "ShortcutModifiers","AlwaysCursor","CursorType","DotWhenNoCursor","ScalingFactor","ScalingQuality",
      "DesktopPixelUnits","SecurityTypes","X509CA","X509CRL","FullScreen","FullScreenMode",
      "FullScreenSelectedMonitors","FullScreenAllMonitors"])
    // Validate every recognized occurrence before last-assignment resolution.
    // A malformed earlier value cannot be hidden by a later valid duplicate.
    for index in document.entries.indices {
      let entry = document.entries[index]
      let asciiName = String(decoding:entry.name.utf8.map { (65...90).contains($0) ? $0+32 : $0 },as:UTF8.self)
      if let name = ["audio":"Audio","sendprimary":"SendPrimary","setprimary":"SetPrimary"][asciiName] {
        // These fields are unknown to the macOS retained viewer too; do not
        // decode future escapes or validate values that cannot be applied.
        ignored.append(.init(kind:.platformOnly,line:entry.line,name:name)); continue
      }
      guard let field = try document.validatedOption(at:index) else {
        ignored.append(.init(kind:.unknownField,line:entry.line,name:entry.name)); continue
      }
      guard supported.contains(field.name) else {
        throw NativeDocumentResolutionFailure(reason:.unrepresentableField,line:entry.line)
      }
      fields[field.name] = field.value; sources[field.name] = entry.line
    }
    let overlay = try NativeOptionOverlay(fields:fields,positions:sources,base:base,source:.document,
      legacyDisplays:legacyDisplays,workingDirectory:workingDirectory,monitorMapping:monitorMapping,compatibility:compatibility,availableDisplays:availableDisplays)
    monitorSource = overlay.monitorSource; resolvedMonitorMapping = overlay.resolvedMonitorMapping
    explicitMonitorMapping = overlay.explicitMonitorMapping
    self.compatibility = overlay.compatibility
    endpoint = overlay.endpoint; cursorType = overlay.cursorType; monitorNumbers = overlay.monitorNumbers
    fieldLines = overlay.fieldPositions; notices = ignored; candidate = overlay.configuration
  }
}
