// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import CoreGraphics
import TidyVNC

public enum NativeStatus: UInt32, Sendable {
  case ok = 0, noChange = 1, pending = 2
  case invalidArgument = 10, abiMismatch, unsupported, invalidHandle, wrongHandleType
  case resourceLimit, outOfMemory, stale, notConnected, closing, busy, queueFull
  case cancelled, notPending, failed, internalFailure, viewOnly, unfocused, disabled, echo
}

public struct NativeError: Error, Sendable, Equatable, CustomStringConvertible {
  public let status: NativeStatus
  public let domain: UInt32
  public let detail: UInt32
  public let nativeCode: Int32
  public let description: String
  init(_ value: tidyvnc_error) {
    status = NativeStatus(rawValue: value.code) ?? .internalFailure
    domain = value.domain; detail = value.detail; nativeCode = value.native_error
    var text = value.message
    description = withUnsafeBytes(of: &text) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
  }
  init(_ status: NativeStatus, _ message: String) {
    self.status = status; domain = UInt32(TIDYVNC_DOMAIN_BRIDGE)
    detail = 0; nativeCode = 0; description = message
  }
}

public enum NativeSessionState: UInt32, Sendable {
  case idle = 0, resolving, connecting, negotiating, authenticating, connected, disconnecting, closed, failed
}
public enum NativeEndReason: UInt32, Sendable {
  case none = 0, cancelled, peerClosed, promptTimeout, authenticationRejected, transport, protocolFailure
  case resource, internalFailure, eventOverflow, resolution, connection, resolutionTimeout, connectionTimeout
  case unsupportedEndpoint, invalidEndpoint
}
public struct NativeSnapshot: Sendable, Equatable {
  public let state: NativeSessionState
  public let endReason: NativeEndReason
  public let nativeCode: Int32
  public let width: UInt32, height: UInt32
  public let supportsResize: Bool, resizePending: Bool
  public let generation: UInt64, frames: UInt64, bells: UInt64
  public let information: NativeConnectionInformation?
  init(_ value: tidyvnc_snapshot, stateOverride: NativeSessionState? = nil, information: NativeConnectionInformation? = nil) {
    self.information = information
    state = stateOverride ?? NativeSessionState(rawValue: value.state) ?? .failed
    endReason = NativeEndReason(rawValue: value.end_reason) ?? .internalFailure
    nativeCode = value.native_error; width = value.width; height = value.height
    supportsResize = value.supports_resize != 0; resizePending = value.resize_pending != 0
    generation = value.generation; frames = value.frames; bells = value.bells
  }
}
extension tidyvnc_connection_info: ABIValue {}
public struct NativeConnectionInformation: Sendable, Equatable {
  public let generation: UInt64, frames: UInt64, bitsPerSecond: UInt64
  public let width: UInt32, height: UInt32, protocolMajor: UInt32, protocolMinor: UInt32, securityType: UInt32
  public let credentialsSecure: Bool, nameTruncated: Bool
  public let requestedEncoding: Int32, lastEncoding: Int32
  public let desktopName: String, pixelFormat: String, securityName: String
  public let requestedEncodingName: String, lastEncodingName: String
  init(_ value: tidyvnc_connection_info) {
    func text<T>(_ bytes: T) -> String { withUnsafeBytes(of: bytes) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) } }
    generation = value.snapshot.generation; frames = value.snapshot.frames; bitsPerSecond = value.bits_per_second
    width = value.snapshot.width; height = value.snapshot.height; protocolMajor = value.protocol_major; protocolMinor = value.protocol_minor
    securityType = value.security_type; credentialsSecure = value.credentials_secure != 0; nameTruncated = value.name_truncated != 0
    requestedEncoding = value.requested_encoding; lastEncoding = value.last_encoding
    desktopName = text(value.desktop_name); pixelFormat = text(value.pixel_format); securityName = text(value.security_name)
    requestedEncodingName = text(value.requested_encoding_name); lastEncodingName = text(value.last_encoding_name)
  }
  // Deliberately exclude remote names, endpoints, paths and authentication data.
  public var redactedDiagnostics: String {
    """
    TidyVNC connection diagnostics
    Protocol: RFB \(protocolMajor).\(protocolMinor)
    Security: \(securityName) (\(securityType))
    Desktop size: \(width) × \(height)
    Pixel format: \(pixelFormat)
    Requested encoding: \(requestedEncodingName)
    Last used encoding: \(lastEncoding < 0 ? "Not received" : lastEncodingName)
    Line speed estimate: \(frames == 0 ? "Not sampled" : "\(bitsPerSecond / 1000) kbit/s")
    Frames received: \(frames)
    Endpoint and desktop name omitted.
    """
  }
}
public struct NativeOperation: Sendable, Equatable {
  public let id: UInt64, generation: UInt64
}
public struct NativeCompletion: Sendable, Equatable {
  public let operation: NativeOperation
  public let snapshot: NativeSnapshot
}
public struct NativeCommandFailure: Error, Sendable, Equatable {
  public enum Result: UInt32, Sendable { case succeeded = 0, cancelled, failed }
  public enum Reason: UInt32, Sendable { case none = 0, timedOut, serverRejected }
  public let operation: NativeOperation
  public let result: Result
  public let reason: Reason
  public let nativeResult: UInt32
  public let snapshot: NativeSnapshot
}

public struct NativeSessionConfiguration: Sendable {
  // nil uses the shared viewer default; explicit zero disables motion delay.
  public var pointerEventIntervalMilliseconds: UInt32? = nil
  public var pointerEventIntervalSource: NativeOptionSource? = nil
  // Incoming wire/decompressed clipboard bytes; independent of UTF-8 retention budgets.
  public var maxCutText: UInt32? = nil
  public var maxCutTextSource: NativeOptionSource? = nil
  public var windowStartupPolicy: NativeWindowStartupPolicy = .builtIn
  public var windowStartupSources: [NativeWindowStartupOption:NativeOptionSource] = [:]
  public var networkPolicy: NativeNetworkPolicy = .builtIn
  public var networkSources: [NativeNetworkOption:NativeOptionSource] = [:]
  public var fullscreenPolicy: NativeFullscreenPolicy = .builtIn
  public var fullscreenSources: [NativeFullscreenOption:NativeOptionSource] = [:]
  public var resizePolicy: NativeRemoteResizePolicy = .builtIn
  public var resizeSources: [NativeResizeOption:NativeOptionSource] = [:]
  public var shared = false, reconnectOnError = true
  public var sharedSource: NativeOptionSource = .compiled, reconnectSource: NativeOptionSource = .compiled
  // nil preserves a desktop host's explicit initial rendering configuration.
  public var scaling: NativeScaling? = nil
  public var scalingSources: [NativeScalingOption: NativeOptionSource] = [:]
  public var input = NativeInputSettings()
  public var inputSources: [NativeInputOption: NativeOptionSource] = [:]
  public var encoding: NativeEncodingOptions? = nil
  // nil snapshots the core's compiled defaults; [] explicitly denies all types.
  public var securityTypes: [UInt32]? = nil
  public var securitySource: NativeOptionSource? = nil
  public var promptTimeoutMilliseconds: UInt32 = 60_000
  public var eventCapacity: UInt32 = 128
  public var commandCapacity: UInt32 = 32
  public var framebufferBytes: UInt64 = 64 * 1024 * 1024
  public var publicationBytes: UInt64 = 128 * 1024 * 1024
  public var tlsPrioritySource: NativeOptionSource? = nil
  public var tlsPriority = "", caFile = "", crlFile = ""
  public var clipboardSend = true, clipboardReceive = true
  public init() {}
}

// Immutable ownership is safe across executors: the C registry and leases are
// thread-safe, and this class never mutates or publishes a borrowed pointer.
final class NativeHandle: @unchecked Sendable {
  let raw: UInt64
  init(adopting raw: UInt64) { precondition(raw != 0); self.raw = raw }
  convenience init(retaining raw: UInt64) throws {
    try checked { tidyvnc_retain(raw, $0) }; self.init(adopting: raw)
  }
  deinit { _ = tidyvnc_release(raw, nil) }
}

protocol ABIValue { init(); var size: UInt32 { get set }; var version: UInt32 { get set } }
extension tidyvnc_error: ABIValue {}
extension tidyvnc_runtime_options: ABIValue {}
extension tidyvnc_session_options: ABIValue {}
extension tidyvnc_connect_options: ABIValue {}
extension tidyvnc_operation: ABIValue {}
extension tidyvnc_snapshot: ABIValue {}
extension tidyvnc_event: ABIValue {}
extension tidyvnc_view_update: ABIValue {}
extension tidyvnc_image_info: ABIValue {}
extension tidyvnc_prompt_info: ABIValue {}
extension tidyvnc_callbacks: ABIValue {}
func abi<T: ABIValue>(_ type: T.Type) -> T {
  var value = T(); value.size = UInt32(MemoryLayout<T>.size); value.version = UInt32(TIDYVNC_ABI_VERSION); return value
}
@discardableResult
func checked(allowing: Set<NativeStatus> = [.ok], _ call: (UnsafeMutablePointer<tidyvnc_error>) -> UInt32) throws -> NativeStatus {
  var error = abi(tidyvnc_error.self)
  let code = call(&error)
  guard let status = NativeStatus(rawValue: code), allowing.contains(status) else { throw NativeError(error) }
  return status
}
func copyBytes(_ bytes: tidyvnc_bytes) throws -> Data {
  guard bytes.length <= UInt64(Int.max), bytes.data != nil || bytes.length == 0 else {
    throw NativeError(.internalFailure, "Invalid owned payload span")
  }
  guard bytes.length != 0 else { return Data() }
  return Data(bytes: bytes.data!, count: Int(bytes.length))
}
func withText<T>(_ text: String, _ body: (tidyvnc_bytes) throws -> T) rethrows -> T {
  try Array(text.utf8).withUnsafeBufferPointer { try body(tidyvnc_bytes(data: $0.baseAddress, length: UInt64($0.count))) }
}

public struct NativePixelRect: Sendable, Hashable {
  public let x: UInt32, y: UInt32, width: UInt32, height: UInt32
  public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }
}

public final class NativeImage: @unchecked Sendable {
  public enum Format: UInt32, Sendable { case bgra8 = 1, rgba8 = 2 }
  public enum Alpha: UInt32, Sendable { case opaque = 1, straight = 2, premultiplied = 3 }
  let handle: NativeHandle
  public let width: UInt32, height: UInt32, stride: UInt64
  public let generation: UInt64, sizeGeneration: UInt64, sequence: UInt64
  public let previousSequence: UInt64
  public let damage: NativePixelRect
  let streamID: UUID
  public let hotspotX: UInt32, hotspotY: UInt32
  public let format: Format, alpha: Alpha
  init(owning owner: NativeHandle, previousSequence: UInt64 = 0, damage: NativePixelRect? = nil, streamID: UUID = UUID()) throws {
    var info = abi(tidyvnc_image_info.self)
    try checked { tidyvnc_image_get(owner.raw, &info, $0) }
    guard let format = Format(rawValue: info.format), let alpha = Alpha(rawValue: info.alpha),
          info.origin == UInt32(TIDYVNC_ORIGIN_TOP_LEFT) else { throw NativeError(.unsupported, "Unsupported image format") }
    self.previousSequence = previousSequence; self.streamID = streamID
    self.damage = damage ?? NativePixelRect(x: 0, y: 0, width: info.width, height: info.height)
    handle = owner; width = info.width; height = info.height; stride = info.stride
    generation = info.generation; sizeGeneration = info.size_generation; sequence = info.sequence
    hotspotX = info.hotspot_x; hotspotY = info.hotspot_y; self.format = format; self.alpha = alpha
  }
  // The retained image itself is zero-copy. A client needing Swift-owned bytes
  // explicitly requests a copy; no unsafe borrowed pixel span enters UI state.
  public func copyPixels() throws -> Data {
    try withExtendedLifetime(handle) {
      var info = abi(tidyvnc_image_info.self)
      try checked { tidyvnc_image_get(handle.raw, &info, $0) }
      return try copyBytes(info.pixels)
    }
  }
  // The provider retains the C lease until Core Graphics releases the image,
  // including after view removal, resize or session/runtime shutdown.
  public func makeCGImage() throws -> CGImage {
    var info = abi(tidyvnc_image_info.self)
    try checked { tidyvnc_image_get(handle.raw, &info, $0) }
    guard let pixels = info.pixels.data, info.pixels.length <= UInt64(Int.max), stride <= UInt64(Int.max) else {
      throw NativeError(.internalFailure, "Invalid image storage")
    }
    let retained = Unmanaged.passRetained(handle)
    guard let provider = CGDataProvider(dataInfo: retained.toOpaque(), data: pixels, size: Int(info.pixels.length), releaseData: { context, _, _ in
      if let context { Unmanaged<NativeHandle>.fromOpaque(context).release() }
    }) else { retained.release(); throw NativeError(.outOfMemory, "Could not retain image data") }
    let alphaInfo: CGImageAlphaInfo
    if format == .bgra8 {
      alphaInfo = alpha == .opaque ? .noneSkipFirst : alpha == .straight ? .first : .premultipliedFirst
    } else {
      alphaInfo = alpha == .opaque ? .noneSkipLast : alpha == .straight ? .last : .premultipliedLast
    }
    let order: CGBitmapInfo = format == .bgra8 ? .byteOrder32Little : .byteOrder32Big
    guard let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: Int(stride), space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: order.union(CGBitmapInfo(rawValue: alphaInfo.rawValue)), provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw NativeError(.failed, "Could not create desktop image") }
    return image
  }
}

public struct NativePrompt: Sendable, Equatable, Identifiable {
  public enum Kind: UInt32, Sendable { case credentials = 1, certificate, hostKey }
  public let id: UInt64, generation: UInt64
  public let kind: Kind
  public let secure: Bool, usernameRequired: Bool
  // The core's isSecure policy assesses credential protection. It is not a
  // transport-encryption flag (anonymous TLS is false; security modes differ).
  public var credentialProtectionMessage: String {
    secure ? "The negotiated authentication method protects your credentials." :
      "The negotiated authentication method may not adequately protect your credentials."
  }
  public let securityType: UInt32
  public let certificateStatus: UInt32
  public let serverName: String, fingerprint: String
  public let identity: Data
  init(adopting raw: UInt64) throws {
    let owner = NativeHandle(adopting: raw)
    self = try withExtendedLifetime(owner) {
      var info = abi(tidyvnc_prompt_info.self)
      try checked { tidyvnc_prompt_get(owner.raw, &info, $0) }
      var securityType: UInt32 = 0
      try checked { tidyvnc_prompt_security_type(owner.raw, &securityType, $0) }
      guard let kind = Kind(rawValue: info.kind) else { throw NativeError(.unsupported, "Unsupported authentication prompt") }
      return NativePrompt(id: info.id, generation: info.generation, kind: kind, secure: info.secure != 0, securityType: securityType,
        usernameRequired: info.username_required != 0, certificateStatus: info.certificate_status,
        serverName: String(decoding: try copyBytes(info.server_name), as: UTF8.self),
        fingerprint: String(decoding: try copyBytes(info.fingerprint), as: UTF8.self), identity: try copyBytes(info.identity))
    }
  }
  init(id: UInt64, generation: UInt64, kind: Kind, secure: Bool, securityType: UInt32 = 0, usernameRequired: Bool,
               certificateStatus: UInt32, serverName: String, fingerprint: String, identity: Data) {
    self.id = id; self.generation = generation; self.kind = kind; self.secure = secure
    self.securityType = securityType
    self.usernameRequired = usernameRequired; self.certificateStatus = certificateStatus
    self.serverName = serverName; self.fingerprint = fingerprint; self.identity = identity
  }
}
