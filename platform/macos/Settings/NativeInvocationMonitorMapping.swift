// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

// No-file CLI display recovery. Keeps one validated candidate and its exact launch
// request until explicit mapping, cancellation or close; never rereads stores.
public struct NativeInvocationMonitorMapping: Identifiable, Sendable {
  public let id = UUID()
  public let numbers: [Int]
  public let suggested: [Int:NativeDisplayID]
  public let endpoint: String
  let prepared: NativeInvocationPreparation
  init(prepared: NativeInvocationPreparation, request: NativeInvocationRequest,
       legacyDisplays: [NativeDisplayID], available: [NativeDisplayID]) throws {
    numbers = prepared.overlay.monitorNumbers
    guard !numbers.isEmpty, numbers.count <= 64 else {
      throw NativeInvocationResolutionFailure(reason:.invalidValue,argument:prepared.overlay.fieldPositions["FullScreenSelectedMonitors"] ?? 0)
    }
    self.prepared = prepared; endpoint = request.endpoint
    suggested = Dictionary(uniqueKeysWithValues:numbers.compactMap { number in
      let id: NativeDisplayID?
      if let mapping = request.monitorMapping { id = mapping[number] }
      else { id = number > 0 && number <= legacyDisplays.count ? legacyDisplays[number-1] : nil }
      guard let id, available.contains(id) else { return nil }
      return (number,id)
    })
  }
  func resolve(_ assignments: [Int:NativeDisplayID], available: [NativeDisplayID]) throws -> NativeInvocationResolution {
    guard Set(assignments.keys) == Set(numbers), assignments.values.allSatisfy({ available.contains($0) }) else {
      throw NativeInvocationResolutionFailure(reason:.displayMappingRequired,argument:0)
    }
    return try NativeInvocationResolution(prepared:prepared,endpoint:endpoint,legacyDisplays:[],
      monitorMapping:assignments,availableDisplays:available)
  }
}
