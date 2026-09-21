// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

// Validated values awaiting display resolution. A selected mode without mapped
// IDs is deliberately not a NativeFullscreenPolicy and cannot reach a session.
struct NativeFullscreenOptions: Sendable {
  var startsFullscreen: Bool
  var mode: NativeFullscreenMode
  var selectedDisplays: [NativeDisplayID]
  var selectedNumbers: [Int]?
  var sources: [NativeFullscreenOption:NativeOptionSource]
  var selectionSource: NativeOptionSource?
  var preferredMapping: [Int:NativeDisplayID]?

  init(base: NativeSessionConfiguration) {
    startsFullscreen = base.fullscreenPolicy.startsFullscreen
    mode = base.fullscreenPolicy.mode
    selectedDisplays = base.fullscreenPolicy.selectedDisplays
    sources = base.fullscreenSources
  }
  func applying(fields: [String:String], source: NativeOptionSource, all: Bool,
                allSource: NativeOptionSource, preferredMapping: [Int:NativeDisplayID]?) -> Self {
    var result = self
    if let value = fields["FullScreen"] {
      result.startsFullscreen = value == "on"; result.sources[.startsFullscreen] = source
    }
    if let value = fields["FullScreenMode"], let mode = NativeFullscreenMode(rawValue:value.lowercased()) {
      result.mode = mode; result.sources[.mode] = source
    }
    if let value = fields["FullScreenSelectedMonitors"] {
      result.selectedNumbers = Array(Set(value.split(separator:",").compactMap { Int($0) })).sorted()
      result.selectionSource = source; result.sources[.selectedDisplays] = source
      // A later selection replaces the entire earlier list and its assignments.
      result.preferredMapping = preferredMapping
    } else if let preferredMapping {
      // Explicit host mapping can also cover the retained implicit monitor 1.
      result.preferredMapping = preferredMapping
    }
    if all { result.mode = .all; result.sources[.mode] = allSource }
    return result
  }
  var numbers: [Int] {
    if let selectedNumbers { return selectedNumbers }
    return mode == .selected && selectedDisplays.isEmpty ? [1] : []
  }
  var numberSource: NativeOptionSource? {
    guard !numbers.isEmpty else { return nil }
    return selectionSource ?? sources[.mode]
  }
  struct Resolution {
    let configuration: NativeSessionConfiguration
    let mapping: [Int:NativeDisplayID]
    let explicit: Bool
  }
  func resolve(base: NativeSessionConfiguration, legacyDisplays: [NativeDisplayID],
               mapping: [Int:NativeDisplayID]?, availableDisplays: [NativeDisplayID]?,
               line: UInt32) throws -> Resolution {
    func failure() -> NativeDocumentResolutionFailure { .init(reason:.displayMappingRequired,line:line) }
    let required = numbers
    guard required.count <= 64 else { throw NativeDocumentResolutionFailure(reason:.unrepresentableField,line:line) }
    let explicit = mapping ?? (required.isEmpty ? nil : preferredMapping)
    if let explicit {
      guard Set(explicit.keys) == Set(required) else { throw failure() }
      do { try NativeFullscreenPolicy.validateIDs(Array(Set(explicit.values))) }
      catch { throw failure() }
      if let availableDisplays, !explicit.values.allSatisfy({ availableDisplays.contains($0) }) { throw failure() }
    }
    var assignments: [Int:NativeDisplayID] = [:]
    for number in required {
      if let explicit { assignments[number] = explicit[number] }
      else if number > 0, number <= legacyDisplays.count { assignments[number] = legacyDisplays[number-1] }
      else { throw failure() }
    }
    var value = base
    let ids = selectedNumbers != nil || !required.isEmpty ? Array(Set(assignments.values)) : selectedDisplays
    do { value.fullscreenPolicy = try .init(startsFullscreen:startsFullscreen,mode:mode,selectedDisplays:ids) }
    catch { throw failure() }
    value.fullscreenSources = sources
    if selectedNumbers == nil, !required.isEmpty {
      value.fullscreenSources[.selectedDisplays] = sources[.mode] ?? .compiled
    }
    return .init(configuration:value,mapping:assignments,explicit:explicit != nil)
  }
}
