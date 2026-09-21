// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC

extension tidyvnc_invocation_info: ABIValue {}
extension tidyvnc_invocation_assignment: ABIValue {}
extension tidyvnc_invocation_option: ABIValue {}

public enum NativeInvocationAction: UInt32, Sendable { case launch, help, version }
public enum NativeInvocationCategory: UInt32, Sendable {
  case connection, encoding, input, display, security, credentialFile, logging, network, listen, tunnel, platform
}
public enum NativeInvocationProblem: UInt32, Sendable {
  case tooManyArguments = 1, tooLarge, nullByte, unknownOption, missingValue, unavailable, extraOperand, invalidText, invalidValue
}
public struct NativeInvocationFailure: Error, Sendable, Equatable, CustomStringConvertible {
  public let problem: NativeInvocationProblem
  public let argument: UInt32
  public var description: String {
    let message: String
    switch problem {
    case .tooManyArguments: message = "Too many command-line arguments."
    case .tooLarge: message = "Command-line input exceeds its byte limit."
    case .nullByte: message = "A command-line argument contains a null byte."
    case .unknownOption: message = "An unrecognized command-line option was supplied."
    case .missingValue: message = "A command-line option requires a value."
    case .unavailable: message = "A command-line option is unavailable in this build."
    case .extraOperand: message = "Only one server address, connection file or listen port may be supplied."
    case .invalidText: message = "A command-line argument is not valid UTF-8."
    case .invalidValue: message = "A command-line option has an invalid value."
    }
    return argument == 0 ? message : "Argument \(argument): \(message)"
  }
}
public struct NativeInvocationAssignment: Sendable, Equatable {
  public let name: String, value: String
  public let category: NativeInvocationCategory
  public let argument: UInt32, valueArgument: UInt32
}
public struct NativeInvocationOption: Sendable, Equatable {
  public let name: String, alias: String
  public let category: NativeInvocationCategory
  public let boolean: Bool, available: Bool
}
private func invocationCall(allowing: Set<NativeStatus> = [.ok], _ body: (UnsafeMutablePointer<tidyvnc_error>) -> UInt32) throws -> NativeStatus {
  do { return try checked(allowing:allowing,body) }
  catch let error as NativeError {
    if error.domain == UInt32(TIDYVNC_DOMAIN_INVOCATION), let problem = NativeInvocationProblem(rawValue:error.detail & 255) {
      throw NativeInvocationFailure(problem:problem,argument:error.detail >> 8)
    }
    throw error
  }
}
private func invocationText(_ bytes: tidyvnc_bytes, argument: UInt32) throws -> String {
  guard bytes.length <= NativeInvocationSyntax.maximumArgumentBytes, bytes.data != nil || bytes.length == 0 else {
    throw NativeError(.unsupported,"Unsupported invocation value")
  }
  guard let text = String(bytes:UnsafeBufferPointer(start:bytes.data,count:Int(bytes.length)),encoding:.utf8) else {
    throw NativeInvocationFailure(problem:.invalidText,argument:argument)
  }
  return text
}
private func invocationName<T>(_ value: T) throws -> String {
  try withUnsafeBytes(of:value) { bytes in
    guard let text = String(bytes:bytes.prefix(while:{ $0 != 0 }),encoding:.utf8) else {
      throw NativeError(.unsupported,"Unsupported invocation option name")
    }
    return text
  }
}

// Syntax only, not a session configuration or permission to perform an action.
// Copies every borrowed C span before releasing its temporary immutable owner.
// No source argv, C handle, environment, file or connection is retained.
public struct NativeInvocationSyntax: Sendable {
  public static let maximumArguments = 4096
  public static let maximumArgumentBytes = 65536
  public static let maximumBytes = 1_048_576
  public let action: NativeInvocationAction
  public let operand: String?
  public let operandArgument: UInt32
  public let assignments: [NativeInvocationAssignment]
  public init(arguments: [String]) throws {
    try self.init(arguments:arguments,validateValues:false)
  }
  fileprivate init(arguments: [String], validateValues: Bool) throws {
    guard arguments.count <= Self.maximumArguments else { throw NativeInvocationFailure(problem:.tooManyArguments,argument:0) }
    var storage: [UInt8] = [], offsets: [(Int,Int)] = []
    for (index,arg) in arguments.enumerated() {
      let count = arg.utf8.prefix(Self.maximumArgumentBytes+1).count
      guard count <= Self.maximumArgumentBytes, count <= Self.maximumBytes-storage.count else {
        throw NativeInvocationFailure(problem:.tooLarge,argument:UInt32(index+1))
      }
      offsets.append((storage.count,count)); storage.append(contentsOf:arg.utf8)
    }
    var raw: UInt64 = 0
    _ = try storage.withUnsafeBufferPointer { buffer in
      let args = offsets.map { offset,count in
        tidyvnc_bytes(data:buffer.baseAddress?.advanced(by:offset),length:UInt64(count))
      }
      return try args.withUnsafeBufferPointer { spans in
        try invocationCall { tidyvnc_invocation_parse(spans.baseAddress,UInt32(spans.count),&raw,$0) }
      }
    }
    let parsed = NativeHandle(adopting:raw)
    let owner: NativeHandle
    if validateValues {
      var validated: UInt64 = 0
      _ = try invocationCall { tidyvnc_invocation_validate(parsed.raw,&validated,$0) }
      owner = NativeHandle(adopting:validated)
    } else { owner = parsed }
    var info = abi(tidyvnc_invocation_info.self)
    _ = try invocationCall { tidyvnc_invocation_get(owner.raw,&info,$0) }
    guard let action = NativeInvocationAction(rawValue:info.action), info.count <= Self.maximumArguments else {
      throw NativeError(.unsupported,"Unsupported invocation metadata")
    }
    self.action = action; operandArgument = info.operand_argument
    operand = info.operand_argument == 0 ? nil : try invocationText(info.operand,argument:info.operand_argument)
    var fields: [NativeInvocationAssignment] = []
    for index in 0..<info.count {
      var entry = abi(tidyvnc_invocation_assignment.self)
      _ = try invocationCall { tidyvnc_invocation_assignment_at(owner.raw,index,&entry,$0) }
      guard let category = NativeInvocationCategory(rawValue:entry.category) else {
        throw NativeError(.unsupported,"Unsupported invocation category")
      }
      fields.append(try .init(name:invocationName(entry.name),value:invocationText(entry.value,argument:entry.value_argument == 0 ? entry.argument : entry.value_argument),
        category:category,argument:entry.argument,valueArgument:entry.value_argument))
    }
    assignments = fields
  }
  public static func options() throws -> [NativeInvocationOption] {
    var result: [NativeInvocationOption] = []
    for index in 0..<256 {
      var option = abi(tidyvnc_invocation_option.self)
      if try invocationCall(allowing:[.ok,.noChange],{ tidyvnc_invocation_option_at(UInt32(index),&option,$0) }) == .noChange { return result }
      guard let category = NativeInvocationCategory(rawValue:option.category), option.boolean <= 1, option.available <= 1 else {
        throw NativeError(.unsupported,"Unsupported invocation option metadata")
      }
      result.append(try .init(name:invocationName(option.name),alias:invocationName(option.alias),category:category,
        boolean:option.boolean != 0,available:option.available != 0))
    }
    throw NativeError(.unsupported,"Unsupported invocation catalog size")
  }
}

// Every occurrence is validated before canonical values become available.
// Host-only strings still need their platform adapters; this grants no IO.
public struct NativeInvocationOptions: Sendable {
  public let action: NativeInvocationAction
  public let operand: String?
  public let operandArgument: UInt32
  public let assignments: [NativeInvocationAssignment]
  public init(arguments: [String]) throws {
    let syntax = try NativeInvocationSyntax(arguments:arguments,validateValues:true)
    action = syntax.action; operand = syntax.operand; operandArgument = syntax.operandArgument
    assignments = syntax.assignments
  }
}
