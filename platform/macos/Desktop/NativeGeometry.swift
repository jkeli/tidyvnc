// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CoreGraphics
import TidyVNC

extension tidyvnc_geometry_options: ABIValue {}
extension tidyvnc_canvas_viewport: ABIValue {}

public struct NativeCanvasViewport: Equatable, Sendable {
  public let width: UInt32, height: UInt32
  public let region: NativePixelRect
  public let devicePixels: Bool
  public init(width: UInt32, height: UInt32, region: NativePixelRect, devicePixels: Bool) throws {
    self.width = width; self.height = height; self.region = region; self.devicePixels = devicePixels
    var canvas = abiValue, options = abi(tidyvnc_geometry_options.self), result = abi(tidyvnc_geometry.self)
    options.remote_width = 1; options.remote_height = 1
    options.viewport_width = 1; options.viewport_height = 1; options.backing_scale = 1
    try withText("100") { bytes in
      options.scaling = bytes
      try checked { tidyvnc_desktop_canvas_geometry(&options,&canvas,0,0,&result,$0) }
    }
  }
  var abiValue: tidyvnc_canvas_viewport {
    var value = abi(tidyvnc_canvas_viewport.self)
    value.width = width; value.height = height; value.x = region.x; value.y = region.y
    value.region_width = region.width; value.region_height = region.height
    return value
  }
}

extension tidyvnc_geometry: ABIValue {}
extension tidyvnc_damage: ABIValue {}
extension tidyvnc_rectangle: ABIValue {}
public struct NativeGeometry {
  private var options: tidyvnc_geometry_options
  private let scaling: String
  public let canvas: NativeCanvasViewport?
  public let rectangle: CGRect
  public let backingWidth: UInt32, backingHeight: UInt32
  public var backingScale: Double { options.backing_scale }
  // Pan uses the selected sizing units, while the view and pointer use logical
  // coordinates. Match the shared transform's rounded canvas dimensions.
  private var panUnits: Double { options.units == 1 ? backingScale : 1 }
  var panLimit: CGPoint {
    CGPoint(x: min(65535, max(0, rectangle.width * panUnits - (canvas.map { Double($0.width) } ?? ceil(options.viewport_width * panUnits)))),
            y: min(65535, max(0, rectangle.height * panUnits - (canvas.map { Double($0.height) } ?? ceil(options.viewport_height * panUnits)))))
  }
  var panPosition: CGPoint {
    CGPoint(x: min(options.pan_x, panLimit.x), y: min(options.pan_y, panLimit.y))
  }
  func panned(_ direction: NativeDesktopPan) -> CGPoint {
    var result = panPosition
    switch direction {
    case .left: result.x = max(0, result.x - options.viewport_width * panUnits * 0.8)
    case .right: result.x = min(panLimit.x, result.x + options.viewport_width * panUnits * 0.8)
    case .up: result.y = max(0, result.y - options.viewport_height * panUnits * 0.8)
    case .down: result.y = min(panLimit.y, result.y + options.viewport_height * panUnits * 0.8)
    case .origin: result = .zero
    }
    return result
  }
  public var isIdentity: Bool { backingWidth == options.remote_width && backingHeight == options.remote_height }
  public init(width: UInt32, height: UInt32, viewport: CGSize, backingScale: Double,
              scaling: String = "FixedRatio", devicePixels: Bool = false, pan: CGPoint = .zero, canvas: NativeCanvasViewport? = nil) throws {
    var options = abi(tidyvnc_geometry_options.self)
    options.remote_width = width; options.remote_height = height; options.units = (canvas?.devicePixels ?? devicePixels) ? 1 : 0
    options.viewport_width = viewport.width; options.viewport_height = viewport.height
    options.backing_scale = backingScale; options.pan_x = pan.x; options.pan_y = pan.y
    var value = abi(tidyvnc_geometry.self)
    try withText(scaling) { bytes in
      options.scaling = bytes
      if var region = canvas?.abiValue { try checked { tidyvnc_desktop_canvas_geometry(&options,&region,0,0,&value,$0) } }
      else { try checked { tidyvnc_desktop_geometry(&options,0,0,&value,$0) } }
    }
    options.scaling = tidyvnc_bytes() // The borrowed span never escapes its call.
    self.options = options; self.scaling = scaling; self.canvas = canvas
    backingWidth = value.backing_width; backingHeight = value.backing_height
    rectangle = CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
  }
  public func damageRectangle(_ damage: NativePixelRect, filter: NativeScalingFilter) throws -> CGRect {
    var input = options, region = abi(tidyvnc_damage.self), result = abi(tidyvnc_rectangle.self)
    region.x = damage.x; region.y = damage.y; region.width = damage.width; region.height = damage.height; region.quality = filter.rawValue
    try withText(scaling) { bytes in
      input.scaling = bytes
      if var canvas = canvas?.abiValue { try checked { tidyvnc_desktop_canvas_damage(&input,&canvas,&region,&result,$0) } }
      else { try checked { tidyvnc_desktop_damage(&input,&region,&result,$0) } }
    }
    return CGRect(x: result.x, y: result.y, width: result.width, height: result.height)
  }
  public func remotePoint(_ point: CGPoint) throws -> (x: Int32, y: Int32) {
    var input = options, output = abi(tidyvnc_geometry.self)
    try withText(scaling) { bytes in
      input.scaling = bytes
      if var canvas = canvas?.abiValue { try checked { tidyvnc_desktop_canvas_geometry(&input,&canvas,point.x,point.y,&output,$0) } }
      else { try checked { tidyvnc_desktop_geometry(&input,point.x,point.y,&output,$0) } }
    }
    return (output.remote_x, output.remote_y)
  }
}
