// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
import TidyVNC

public enum NativeEndpointIssue: UInt32, Sendable, Equatable {
  case required = 0, tooLong, invalidHost, unmatchedBracket, invalidPort, invalidPath, invalidRoute, unsupportedTransport
  case invalidText, unavailable
}
public enum NativeEndpoint {
  // Borrow only a bounded UTF-8 buffer. The C call performs no DNS/file/network
  // IO, creates no runtime/session, and never returns an input-bearing diagnostic.
  public static func validate(_ address: String, allowUnixSockets: Bool = true) throws {
    let input = Array(address.utf8.prefix(4097))
    try input.withUnsafeBufferPointer { bytes in
      _ = try checked { tidyvnc_endpoint_validate(tidyvnc_bytes(data: bytes.baseAddress, length: UInt64(bytes.count)), allowUnixSockets ? 1 : 0, $0) }
    }
  }
  public static func issue(for address: String, allowUnixSockets: Bool = true) -> NativeEndpointIssue? {
    // The core accepts empty as localhost:0. A blank native form requires entry,
    // matching the existing Connect behavior, without changing parser semantics.
    guard !address.isEmpty else { return .required }
    do { try validate(address, allowUnixSockets: allowUnixSockets); return nil }
    catch let error as NativeError {
      if error.domain == UInt32(TIDYVNC_DOMAIN_ENDPOINT), let issue = NativeEndpointIssue(rawValue: error.detail),
         (1...7).contains(error.detail) { return issue }
      return error.status == .invalidArgument ? .invalidText : .unavailable
    } catch { return .unavailable }
  }
}
