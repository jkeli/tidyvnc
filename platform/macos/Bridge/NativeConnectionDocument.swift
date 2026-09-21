// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC

extension tidyvnc_document_info: ABIValue {}
extension tidyvnc_document_entry: ABIValue {}

public enum NativeDocumentProblem: UInt32, Sendable {
  case empty = 1, invalidHeader, nullByte, lineTooLong, invalidAssignment
  case invalidEscape, tooLarge, tooManyEntries, invalidExportName
  case invalidText, invalidIndex
  case invalidValue, unavailable
}
public struct NativeDocumentFailure: Error, Sendable, Equatable, CustomStringConvertible {
  public let problem: NativeDocumentProblem
  public let line: UInt32
  public var description: String {
    let message: String
    switch problem {
    case .empty: message = "The connection file is empty."
    case .invalidHeader: message = "The connection file header is unsupported."
    case .nullByte: message = "The connection file contains a null byte."
    case .lineTooLong: message = "A connection-file line exceeds its byte limit."
    case .invalidAssignment: message = "A connection-file assignment is malformed."
    case .invalidEscape: message = "A connection-file value contains an invalid escape."
    case .tooLarge: message = "The connection file exceeds its size limit."
    case .tooManyEntries: message = "The connection file contains too many assignments."
    case .invalidExportName: message = "A field cannot be exported to a connection file."
    case .invalidText: message = "The connection file is not valid UTF-8."
    case .invalidIndex: message = "The connection-file entry does not exist."
    case .invalidValue: message = "A connection-file option has an invalid value."
    case .unavailable: message = "A connection-file option is unavailable in this build."
    }
    return line == 0 ? message : "Line \(line): \(message)"
  }
}
@discardableResult private func documentCall(allowing: Set<NativeStatus> = [.ok], _ body: (UnsafeMutablePointer<tidyvnc_error>) -> UInt32) throws -> NativeStatus {
  do { return try checked(allowing: allowing, body) }
  catch let error as NativeError {
    if error.domain == UInt32(TIDYVNC_DOMAIN_DOCUMENT), let problem = NativeDocumentProblem(rawValue: error.detail & 255) {
      throw NativeDocumentFailure(problem: problem, line: error.detail >> 8)
    }
    throw error
  }
}
private func documentText<T>(_ value: T, line: UInt32) throws -> String {
  try withUnsafeBytes(of: value) { bytes in
    guard let result = String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8) else {
      throw NativeDocumentFailure(problem: .invalidText, line: line)
    }
    return result
  }
}
public struct NativeDocumentAssignment: Sendable, Equatable {
  public let name: String, value: String
  public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}
public struct NativeDocumentEntry: Sendable, Equatable {
  public let name: String, encodedValue: String
  public let line: UInt32
}

// Immutable core handle and copied Swift metadata. The synchronized registry
// protects concurrent readers; no borrowed bytes escape a call. This parses
// syntax only: it does not apply settings, read files or authorize migration.
public final class NativeConnectionDocument: Sendable {
  public static let maximumBytes = 1_048_576
  public static let maximumEntries = 4096
  private let handle: NativeHandle
  public let isLegacy: Bool
  public let entries: [NativeDocumentEntry]

  public init(data: Data) throws {
    guard data.count <= Self.maximumBytes else { throw NativeDocumentFailure(problem: .tooLarge, line: 0) }
    // Explicitly reject invalid text, including in ignored/comment fields;
    // never silently turn unrepresentable bytes into replacement characters.
    guard String(data: data, encoding: .utf8) != nil else { throw NativeDocumentFailure(problem: .invalidText, line: 0) }
    var raw: UInt64 = 0
    _ = try data.withUnsafeBytes { bytes in
      try documentCall { tidyvnc_document_parse(tidyvnc_bytes(data: bytes.bindMemory(to: UInt8.self).baseAddress, length: UInt64(bytes.count)), &raw, $0) }
    }
    let owner = NativeHandle(adopting: raw)
    var info = abi(tidyvnc_document_info.self)
    try documentCall { tidyvnc_document_get(owner.raw, &info, $0) }
    guard info.count <= Self.maximumEntries, info.legacy_header <= 1 else { throw NativeError(.unsupported, "Unsupported connection-file metadata") }
    var copied: [NativeDocumentEntry] = []
    copied.reserveCapacity(Int(info.count))
    for index in 0..<info.count {
      var entry = abi(tidyvnc_document_entry.self)
      try documentCall { tidyvnc_document_entry_at(owner.raw, index, 0, &entry, $0) }
      copied.append(try NativeDocumentEntry(name: documentText(entry.name, line: entry.line),
        encodedValue: documentText(entry.value, line: entry.line), line: entry.line))
    }
    handle = owner; isLegacy = info.legacy_header != 0; entries = copied
  }
  public func decodedValue(at index: Int) throws -> String {
    guard entries.indices.contains(index) else { throw NativeDocumentFailure(problem: .invalidIndex, line: 0) }
    var value = abi(tidyvnc_document_entry.self)
    try documentCall { tidyvnc_document_entry_at(handle.raw, UInt32(index), 1, &value, $0) }
    return try documentText(value.value, line: value.line)
  }
  public func validatedOption(at index: Int) throws -> NativeDocumentAssignment? {
    guard entries.indices.contains(index) else { throw NativeDocumentFailure(problem: .invalidIndex, line: 0) }
    var value = abi(tidyvnc_document_entry.self)
    if try documentCall(allowing: [.ok,.noChange], { tidyvnc_document_option_at(handle.raw, UInt32(index), &value, $0) }) == .noChange { return nil }
    return try .init(documentText(value.name, line: value.line), documentText(value.value, line: value.line))
  }
  public static func serialize(_ fields: [NativeDocumentAssignment]) throws -> Data {
    guard fields.count <= maximumEntries else { throw NativeDocumentFailure(problem: .tooManyEntries, line: 0) }
    var storage: [UInt8] = []
    var offsets: [(Int, Int, Int, Int)] = []
    for field in fields {
      guard field.name.utf8.prefix(256).count <= 255, field.value.utf8.prefix(256).count <= 255 else {
        throw NativeDocumentFailure(problem: .lineTooLong, line: 0)
      }
      let name = storage.count; storage.append(contentsOf: field.name.utf8)
      let value = storage.count; storage.append(contentsOf: field.value.utf8)
      offsets.append((name, value - name, value, storage.count - value))
    }
    return try storage.withUnsafeBufferPointer { buffer in
      let values = offsets.map { name, nameLength, value, valueLength in
        tidyvnc_document_assignment(name: tidyvnc_bytes(data: buffer.baseAddress?.advanced(by: name), length: UInt64(nameLength)),
          value: tidyvnc_bytes(data: buffer.baseAddress?.advanced(by: value), length: UInt64(valueLength)))
      }
      return try values.withUnsafeBufferPointer { input in
        var length: UInt64 = 0
        try documentCall { tidyvnc_document_serialize(input.baseAddress, UInt32(input.count), tidyvnc_mutable_bytes(data: nil, length: 0), &length, $0) }
        guard length <= maximumBytes else { throw NativeDocumentFailure(problem: .tooLarge, line: 0) }
        var result = Data(count: Int(length))
        _ = try result.withUnsafeMutableBytes { output in
          try documentCall { tidyvnc_document_serialize(input.baseAddress, UInt32(input.count),
            tidyvnc_mutable_bytes(data: output.bindMemory(to: UInt8.self).baseAddress, length: UInt64(output.count)), &length, $0) }
        }
        guard length == result.count else { throw NativeError(.internalFailure, "Connection-file export size changed") }
        return result
      }
    }
  }
}
