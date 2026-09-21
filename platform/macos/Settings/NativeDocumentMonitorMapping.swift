// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

// Sparse file monitor numbers must never become array sizes: the shared codec
// accepts positive Int32 values, including numbers far above the display count.
public struct NativeDocumentMonitorMapping: Identifiable, Sendable {
  public let id = UUID()
  public let numbers: [Int]
  public let monitorSource: NativeOptionSource?
  public let suggested: [Int:NativeDisplayID]
  public let available: [NativeDisplayID]
  let compatibility: NativeCompatibilityState?
  let document: NativeConnectionDocument
  let base: NativeSessionConfiguration
  let workingDirectory: String

  init(document: NativeConnectionDocument, base: NativeSessionConfiguration,
       workingDirectory: String, legacyDisplays: [NativeDisplayID], available: [NativeDisplayID],
       previous: [Int:NativeDisplayID]? = nil, compatibility: NativeCompatibilityState? = nil) throws {
    self.compatibility = compatibility
    self.document = document; self.base = base; self.workingDirectory = workingDirectory
    self.available = available
    let options = try Self.options(document:document,base:base,compatibility:compatibility)
    numbers = options.numbers; monitorSource = options.numberSource
    guard numbers.count <= 64 else { throw NativeDocumentResolutionFailure(reason:.unrepresentableField,line:0) }
    suggested = Dictionary(uniqueKeysWithValues:numbers.compactMap { number in
      if let chosen = previous ?? options.preferredMapping {
        guard let id = chosen[number], available.contains(id) else { return nil }
        return (number,id)
      }
      guard number <= legacyDisplays.count, available.contains(legacyDisplays[number-1]) else { return nil }
      return (number,legacyDisplays[number-1])
    })
  }
  public static func numbers(document: NativeConnectionDocument, base: NativeSessionConfiguration = .init(), compatibility: NativeCompatibilityState? = nil) throws -> [Int] {
    try options(document:document,base:base,compatibility:compatibility).numbers
  }
  private static func options(document: NativeConnectionDocument, base: NativeSessionConfiguration,
                              compatibility: NativeCompatibilityState?) throws -> NativeFullscreenOptions {
    var fields: [String:String] = [:]
    for index in document.entries.indices {
      // Inspect only monitor fields. In particular, platform-only values such as
      // Audio can contain future escapes and must remain opaque to this helper.
      // The enclosing resolver validates all other supported fields separately.
      let name = document.entries[index].name.lowercased()
      guard ["fullscreenselectedmonitors","fullscreenmode","fullscreenallmonitors"].contains(name) else { continue }
      guard let field = try document.validatedOption(at:index) else { continue }
      fields[field.name] = field.value
    }
    return options(fields:fields,base:base,compatibility:compatibility)
  }
  static func numbers(fields: [String:String], base: NativeSessionConfiguration, compatibility: NativeCompatibilityState? = nil) -> [Int] {
    options(fields:fields,base:base,compatibility:compatibility).numbers
  }
  private static func options(fields: [String:String], base: NativeSessionConfiguration,
                              compatibility: NativeCompatibilityState?) -> NativeFullscreenOptions {
    let all = fields["FullScreenAllMonitors"].map { $0 == "on" } ?? compatibility?.fullscreenAllMonitors ?? false
    let allSource: NativeOptionSource = fields["FullScreenAllMonitors"] != nil ? .document : (compatibility?.allSource ?? .document)
    return (compatibility?.pendingFullscreen ?? NativeFullscreenOptions(base:base))
      .applying(fields:fields,source:.document,all:all,allSource:allSource,preferredMapping:nil)
  }
}
