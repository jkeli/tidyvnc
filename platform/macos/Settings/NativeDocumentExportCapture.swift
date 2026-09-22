// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

// A value snapshot captured before presenting any UI. Mapping recovery never
// rereads a live session or changes its fullscreen policy.
public struct NativeDocumentExportCapture: Sendable {
  public let selectedDisplays: [NativeDisplayID]
  public let displayNames: [NativeDisplayID:String]
  private let endpoint: String
  private let configuration: NativeSessionConfiguration
  private let inactiveCursor: NativeCursorFallback
  private let legacyDisplays: [NativeDisplayID]
  private let ignoredInput: Bool
  private let sshGateway: NativeSSHGateway?
  public init(endpoint: String, configuration: NativeSessionConfiguration,
              inactiveCursor: NativeCursorFallback = .dot, legacyDisplays: [NativeDisplayID] = [],
              displayNames: [NativeDisplayID:String] = [:], ignoredInput: Bool = false, sshGateway: NativeSSHGateway? = nil) throws {
    self.sshGateway = sshGateway
    selectedDisplays = configuration.fullscreenPolicy.selectedDisplays
    self.endpoint = endpoint; self.configuration = configuration; self.inactiveCursor = inactiveCursor
    self.legacyDisplays = legacyDisplays; self.displayNames = displayNames; self.ignoredInput = ignoredInput
    // Validate all representable settings before offering recovery. Temporary
    // ordinal assignments validate only; their output is never shown or saved.
    let validation = Dictionary(uniqueKeysWithValues:selectedDisplays.enumerated().map { ($0.element,$0.offset+1) })
    _ = try makeExport(monitorIndices:validation)
  }
  public func automaticExport() throws -> NativeDocumentExport {
    try NativeDocumentExport(endpoint:endpoint,configuration:configuration,inactiveCursor:inactiveCursor,
      legacyDisplays:legacyDisplays,ignoredInput:ignoredInput,sshGateway:sshGateway)
  }
  public func makeExport(monitorIndices: [NativeDisplayID:Int]) throws -> NativeDocumentExport {
    try NativeDocumentExport(endpoint:endpoint,configuration:configuration,inactiveCursor:inactiveCursor,
      ignoredInput:ignoredInput,monitorIndices:monitorIndices,sshGateway:sshGateway)
  }
  var suggestedIndices: [NativeDisplayID:Int] {
    guard legacyDisplays.count <= 64, Set(legacyDisplays).count == legacyDisplays.count else { return [:] }
    return Dictionary(uniqueKeysWithValues:selectedDisplays.compactMap { id in
      legacyDisplays.firstIndex(of:id).map { (id,$0+1) }
    })
  }
}

public struct NativeDocumentExportMapping: Identifiable, Sendable {
  public let id = UUID()
  public var selectedDisplays: [NativeDisplayID] { capture.selectedDisplays }
  public var displayNames: [NativeDisplayID:String] { capture.displayNames }
  public let suggestedIndices: [NativeDisplayID:Int]
  let capture: NativeDocumentExportCapture
  init(capture: NativeDocumentExportCapture, previous: [NativeDisplayID:Int]? = nil) {
    self.capture = capture; suggestedIndices = previous ?? capture.suggestedIndices
  }
  public func indices(from text: [NativeDisplayID:String]) throws -> [NativeDisplayID:Int] {
    guard Set(text.keys) == Set(selectedDisplays) else { throw NativeDocumentExportError.displayMapping }
    var result: [NativeDisplayID:Int] = [:]
    for (id,value) in text {
      let input = value.trimmingCharacters(in:.whitespacesAndNewlines)
      guard !input.isEmpty, input.utf8.count <= 10, input.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let number = Int(input), number > 0, number <= Int(Int32.max) else { throw NativeDocumentExportError.displayMapping }
      result[id] = number
    }
    guard Set(result.values).count == result.count else { throw NativeDocumentExportError.displayMapping }
    return result
  }
}
