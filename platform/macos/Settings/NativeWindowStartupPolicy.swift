// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC

extension tidyvnc_window_geometry: ABIValue {}
public struct NativeWindowGeometry: Sendable, Equatable {
  public let width: Int32?, height: Int32?, x: Int32?, y: Int32?
  public init(_ text: String) throws {
    var value = abi(tidyvnc_window_geometry.self)
    try checked { error in withText(text) { tidyvnc_window_geometry_parse($0,&value,error) } }
    let sized = value.flags & UInt32(TIDYVNC_WINDOW_GEOMETRY_SIZE) != 0
    let positioned = value.flags & UInt32(TIDYVNC_WINDOW_GEOMETRY_POSITION) != 0
    width = sized ? value.width : nil; height = sized ? value.height : nil
    x = positioned ? value.x : nil; y = positioned ? value.y : nil
  }
}
public enum NativeWindowStartupOption: String, Sendable { case geometry, maximize }
public struct NativeWindowStartupPolicy: Sendable, Equatable {
  public var geometry: NativeWindowGeometry?
  public var maximize: Bool
  public init(geometry: NativeWindowGeometry? = nil, maximize: Bool = false) {
    self.geometry = geometry; self.maximize = maximize
  }
  public static let builtIn = NativeWindowStartupPolicy()
  var hasPlacement: Bool { maximize || geometry?.width != nil || geometry?.x != nil }
}
