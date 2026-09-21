// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import TidyVNC

extension tidyvnc_desktop_layout: ABIValue {}
extension tidyvnc_desktop_layout_request: ABIValue {}

public struct NativeRemoteScreen: Equatable, Sendable {
  public let id: UInt32, x: UInt32, y: UInt32, width: UInt32, height: UInt32, flags: UInt32
  public init(id: UInt32, x: UInt32, y: UInt32, width: UInt32, height: UInt32, flags: UInt32 = 0) {
    self.id = id; self.x = x; self.y = y; self.width = width; self.height = height; self.flags = flags
  }
  var abiValue: tidyvnc_remote_screen { .init(id:id,x:x,y:y,width:width,height:height,flags:flags) }
}

public struct NativeRemoteLayout: Equatable, Sendable {
  public let width: UInt32, height: UInt32
  public let screens: [NativeRemoteScreen]
  public init(width: UInt32, height: UInt32, screens: [NativeRemoteScreen]) throws {
    guard screens.count <= 255 else { throw NativeError(.invalidArgument,"Too many remote screens") }
    self.width = width; self.height = height; self.screens = screens
    _ = try withABI { value in try checked { tidyvnc_desktop_layout_validate(value,$0) } }
  }
  func withABI<T>(_ body: (UnsafePointer<tidyvnc_desktop_layout_request>) throws -> T) rethrows -> T {
    try screens.map(\.abiValue).withUnsafeBufferPointer { screens in
      var request = abi(tidyvnc_desktop_layout_request.self)
      request.width = width; request.height = height; request.screen_count = UInt32(screens.count)
      request.screens = screens.baseAddress
      return try withUnsafePointer(to:&request,body)
    }
  }
}

public struct NativeRemoteDesktop: Sendable {
  public let layout: NativeRemoteLayout
  public let snapshot: NativeSnapshot
  init(_ value: tidyvnc_desktop_layout) throws {
    guard value.screen_count > 0 && value.screen_count <= 255 else { throw NativeError(.internalFailure,"Invalid remote layout") }
    snapshot = NativeSnapshot(value.snapshot)
    let screens = withUnsafeBytes(of:value.screens) { bytes in
      bytes.bindMemory(to:tidyvnc_remote_screen.self).prefix(Int(value.screen_count)).map {
        NativeRemoteScreen(id:$0.id,x:$0.x,y:$0.y,width:$0.width,height:$0.height,flags:$0.flags)
      }
    }
    layout = try NativeRemoteLayout(width:value.snapshot.width,height:value.snapshot.height,screens:screens)
  }
}
