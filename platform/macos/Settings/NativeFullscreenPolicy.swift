// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation

public enum NativeFullscreenOption: String, CaseIterable, Sendable { case startsFullscreen, mode, selectedDisplays }
public struct NativeFullscreenPolicy: Equatable, Sendable {
  public let startsFullscreen: Bool
  public let mode: NativeFullscreenMode
  public let selectedDisplays: [NativeDisplayID]
  private init() { startsFullscreen = false; mode = .current; selectedDisplays = [] }
  public static let builtIn = NativeFullscreenPolicy()
  public init(startsFullscreen: Bool = false, mode: NativeFullscreenMode = .current, selectedDisplays: [NativeDisplayID] = []) throws {
    try Self.validateIDs(selectedDisplays)
    guard mode != .selected || !selectedDisplays.isEmpty else { throw NativePreferencesError.invalidValue }
    self.startsFullscreen = startsFullscreen; self.mode = mode
    self.selectedDisplays = selectedDisplays.sorted { $0.rawValue < $1.rawValue }
  }
  static func validateIDs(_ ids: [NativeDisplayID]) throws {
    guard ids.count <= 64, Set(ids).count == ids.count,
          ids.allSatisfy({ !$0.rawValue.isEmpty && $0.rawValue.utf8.count <= 256 && !$0.rawValue.unicodeScalars.contains(where:{ $0.value < 32 || $0.value == 127 }) }) else { throw NativePreferencesError.invalidValue }
  }
  public var selection: NativeFullscreenSelection {
    switch mode { case .current: .current; case .all: .all; case .selected: .selected(selectedDisplays) }
  }
}
