// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

public enum NativeDefaultsImportPreparation: Sendable {
  case review(NativeDefaultsImportReview)
  case mapping(NativeDefaultsImportMapping)
}

public struct NativeDefaultsImportMapping: Identifiable, Sendable {
  public let id = UUID()
  public let source: URL
  public var origin: NativeImportOrigin { projection.origin }
  public let numbers: [Int]
  public let suggested: [Int:NativeDisplayID]
  let projection: NativeDefaultsImportProjection
  init(source: URL, projection: NativeDefaultsImportProjection, legacyDisplays: [NativeDisplayID],
       availableDisplays: [NativeDisplayID], previous: [Int:NativeDisplayID]? = nil) throws {
    do { try NativeFullscreenPolicy.validateIDs(availableDisplays) }
    catch { throw NativeImportSourceError.invalidDisplayMapping }
    let mapping = try NativeDocumentMonitorMapping(document:projection.document,base:.init(),workingDirectory:"/",
      legacyDisplays:legacyDisplays,available:availableDisplays,previous:previous)
    guard !mapping.numbers.isEmpty else { throw NativeDocumentResolutionFailure(reason:.displayMappingRequired,line:0) }
    self.source = source; self.projection = projection
    numbers = mapping.numbers; suggested = mapping.suggested
  }
  func resolve(_ assignments: [Int:NativeDisplayID], availableDisplays: [NativeDisplayID]) throws -> NativeDefaultsImportReview {
    do { try NativeFullscreenPolicy.validateIDs(availableDisplays) }
    catch { throw NativeImportSourceError.invalidDisplayMapping }
    guard Set(assignments.keys) == Set(numbers), assignments.values.allSatisfy({ availableDisplays.contains($0) }) else {
      throw NativeImportSourceError.invalidDisplayMapping
    }
    let proposal = try NativeDefaultsImport(projection:projection,monitorMapping:assignments)
    return NativeDefaultsImportReview(source:source,proposal:proposal,legacyDisplays:[],projection:projection,
      monitorMapping:assignments,availableDisplays:availableDisplays)
  }
}
