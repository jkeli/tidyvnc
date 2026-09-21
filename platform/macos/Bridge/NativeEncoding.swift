// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC

extension tidyvnc_encoding_schema: ABIValue {}
extension tidyvnc_encoding_choice: ABIValue {}
extension tidyvnc_encoding_value: ABIValue {}
public enum NativeEncodingOption: UInt32, CaseIterable, Sendable {
  case autoSelect = 0, fullColor, lowColorLevel, preferred, customCompression, compression, noJPEG, quality
}
public enum NativeOptionSource: UInt32, Sendable {
  case compiled = 0, appDefaults, profile, session, commandLine, document
}
public struct NativeEncodingAssignment: Sendable {
  public let name: String, value: String
  public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}
public struct NativeEncodingSchema: Sendable {
  public enum Kind: UInt32, Sendable { case boolean = 0, integer, enumeration }
  public let id: NativeEncodingOption, kind: Kind
  public let name: String, alias: String, defaultValue: String
  public let minimum: Int32, maximum: Int32
  public let persistent: Bool, live: Bool
}
public struct NativeEncodingChoice: Sendable {
  public let name: String
  public let wireEncoding: Int32
  public let available: Bool
}
public struct NativeEncodingValue: Equatable, Sendable {
  public let value: String
  public let source: NativeOptionSource
}
private func encodingText<T>(_ value: T) -> String {
  withUnsafeBytes(of: value) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
}
// The C handle owns an immutable fixed-size core snapshot. Registry references
// are synchronized; no borrowed span or mutable state escapes into Swift.
public final class NativeEncodingOptions: @unchecked Sendable {
  let handle: NativeHandle
  init(owning raw: UInt64) { handle = NativeHandle(adopting: raw) }
  public convenience init(patch: [NativeEncodingAssignment] = [], source: NativeOptionSource = .session) throws {
    try self.init(base: nil, patch: patch, source: source)
  }
  private init(base: NativeEncodingOptions?, patch: [NativeEncodingAssignment], source: NativeOptionSource) throws {
    guard patch.count <= 256 else { throw NativeError(.resourceLimit, "Too many encoding assignments") }
    var storage: [UInt8] = []
    var offsets: [(Int, Int, Int, Int)] = []
    for item in patch {
      guard item.name.utf8.prefix(129).count <= 128, item.value.utf8.prefix(129).count <= 128 else {
        throw NativeError(.resourceLimit, "Encoding assignment exceeds its byte limit")
      }
      let name = storage.count; storage.append(contentsOf: item.name.utf8)
      let value = storage.count; storage.append(contentsOf: item.value.utf8)
      offsets.append((name, value - name, value, storage.count - value))
    }
    var raw: UInt64 = 0
    try storage.withUnsafeBufferPointer { buffer in
      let assignments = offsets.map { name, nameLength, value, valueLength in
        tidyvnc_encoding_assignment(name: tidyvnc_bytes(data: buffer.baseAddress?.advanced(by: name), length: UInt64(nameLength)),
          value: tidyvnc_bytes(data: buffer.baseAddress?.advanced(by: value), length: UInt64(valueLength)))
      }
      _ = try assignments.withUnsafeBufferPointer { input in
        try checked { tidyvnc_encoding_create(base?.handle.raw ?? 0, input.baseAddress, UInt32(input.count), source.rawValue, &raw, $0) }
      }
    }
    handle = NativeHandle(adopting: raw)
  }
  public func applying(_ patch: [NativeEncodingAssignment], source: NativeOptionSource) throws -> NativeEncodingOptions {
    try NativeEncodingOptions(base: self, patch: patch, source: source)
  }
  public func value(for option: NativeEncodingOption) throws -> NativeEncodingValue {
    var result = abi(tidyvnc_encoding_value.self)
    try checked { tidyvnc_encoding_get(handle.raw, option.rawValue, &result, $0) }
    guard let source = NativeOptionSource(rawValue: result.source) else { throw NativeError(.unsupported, "Unknown option source") }
    return NativeEncodingValue(value: encodingText(result.value), source: source)
  }
  public static func schema() throws -> [NativeEncodingSchema] {
    var result: [NativeEncodingSchema] = []
    for index in 0..<256 {
      var value = abi(tidyvnc_encoding_schema.self)
      if try checked(allowing: [.ok, .noChange], { tidyvnc_encoding_schema_at(UInt32(index), &value, $0) }) == .noChange { return result }
      guard let id = NativeEncodingOption(rawValue: value.id), let kind = NativeEncodingSchema.Kind(rawValue: value.type) else {
        throw NativeError(.unsupported, "Unknown encoding schema entry")
      }
      result.append(NativeEncodingSchema(id: id, kind: kind, name: encodingText(value.name), alias: encodingText(value.alias),
        defaultValue: encodingText(value.default_value), minimum: value.minimum, maximum: value.maximum,
        persistent: value.persistent != 0, live: value.live != 0))
    }
    throw NativeError(.resourceLimit, "Encoding schema exceeds its entry limit")
  }
  public static func choices() throws -> [NativeEncodingChoice] {
    var result: [NativeEncodingChoice] = []
    for index in 0..<256 {
      var value = abi(tidyvnc_encoding_choice.self)
      if try checked(allowing: [.ok, .noChange], { tidyvnc_encoding_choice_at(UInt32(index), &value, $0) }) == .noChange { return result }
      result.append(NativeEncodingChoice(name: encodingText(value.name), wireEncoding: value.wire_encoding, available: value.available != 0))
    }
    throw NativeError(.resourceLimit, "Encoding choices exceed their entry limit")
  }
}
public enum NativeEncodingProblem: UInt32, Sendable {
  case unknownOption = 1, invalidValue, unavailable, tooLong
}
extension NativeError {
  public var encodingProblem: NativeEncodingProblem? {
    domain == UInt32(TIDYVNC_DOMAIN_ENCODING) ? NativeEncodingProblem(rawValue: detail & 0xffff) : nil
  }
  public var encodingOption: NativeEncodingOption? {
    guard domain == UInt32(TIDYVNC_DOMAIN_ENCODING), detail >> 16 > 0 else { return nil }
    return NativeEncodingOption(rawValue: (detail >> 16) - 1)
  }
}
