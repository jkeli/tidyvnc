// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CryptoKit
import Foundation
import Security
import TidyVNC

extension tidyvnc_certificate_policy: ABIValue {}
public enum NativeCertificateReason: UInt32, CaseIterable, Sendable {
  case invalid = 1, revoked = 2, unknownIssuer = 4, signerNotCA = 8, weakAlgorithm = 16
  case notYetValid = 32, expired = 64, badSignature = 128, oldRevocationData = 256
  case wrongOwner = 512, futureRevocationData = 1024, signerConstraints = 2048, mismatch = 4096
  case wrongPurpose = 8192, missingOCSP = 16384, invalidOCSP = 32768, criticalExtension = 65536
  case unknownProblem = 131072, missingProblem = 262144
  public var message: String {
    switch self {
    case .invalid: return "Certificate verification failed."
    case .revoked: return "The certificate has been revoked."
    case .unknownIssuer: return "The certificate issuer is not trusted."
    case .signerNotCA: return "The signer is not a certificate authority."
    case .weakAlgorithm: return "The certificate uses an insecure algorithm."
    case .notYetValid: return "The certificate is not yet valid."
    case .expired: return "The certificate has expired."
    case .badSignature: return "The certificate signature is invalid."
    case .oldRevocationData: return "The revocation information is out of date."
    case .wrongOwner: return "The certificate does not match the requested server name."
    case .futureRevocationData: return "The revocation information has a future issue date."
    case .signerConstraints: return "The signer violates certificate constraints."
    case .mismatch: return "The certificate does not match the required identity."
    case .wrongPurpose: return "The certificate is not valid for this purpose."
    case .missingOCSP: return "Required certificate status information is missing."
    case .invalidOCSP: return "The certificate status response is invalid."
    case .criticalExtension: return "A required certificate extension is unsupported."
    case .unknownProblem: return "The certificate has an unrecognized verification problem."
    case .missingProblem: return "No certificate verification reason was supplied."
    }
  }
}
public struct NativeCertificatePolicy: Sendable, Equatable {
  public let reasons: [NativeCertificateReason]
  public let mayOverride: Bool
  public let fatalStatus: UInt32
  public init(status: UInt32) throws {
    var value = abi(tidyvnc_certificate_policy.self)
    try checked { tidyvnc_certificate_policy_get(status, &value, $0) }
    reasons = NativeCertificateReason.allCases.filter { value.reasons & $0.rawValue != 0 }
    mayOverride = value.may_override != 0; fatalStatus = value.fatal_status
  }
}
public struct NativeHostKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let bits: UInt32
  public let identity: Data
  public var description: String { "NativeHostKey(<redacted>)" }
  public var debugDescription: String { description }
  public init(_ identity: Data) throws {
    guard identity.count <= 2052 else { throw NativeStorageError.invalid }
    var bits: UInt32 = 0
    do {
      _ = try identity.withUnsafeBytes { bytes in
        try checked { tidyvnc_host_key_validate(.init(data: bytes.bindMemory(to: UInt8.self).baseAddress,length: UInt64(bytes.count)),&bits,$0) }
      }
    } catch let error as NativeError { throw error.status == .invalidArgument ? NativeStorageError.invalid : NativeStorageError.unavailable }
    self.bits = bits; self.identity = identity
  }
}
// Presentation is derived from owned, bounded prompt data. Fingerprints are
// deliberately excluded from diagnostics/description; UI displays them explicitly.
public struct NativeTrustPresentation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  public let mayConnectOnce: Bool
  public let problems: [String]
  public let subject: String?
  public let sha256Fingerprint: String?
  public let compatibilityFingerprint: String?
  public var description: String { "NativeTrustPresentation(<redacted>)" }
  public var debugDescription: String { description }
  public init(_ request: NativePrompt) {
    let validIdentity = !request.identity.isEmpty && request.identity.count <= 65536
    sha256Fingerprint = validIdentity ? SHA256.hash(data: request.identity).map { String(format: "%02X", $0) }.joined(separator: ":") : nil
    if request.kind == .certificate {
      compatibilityFingerprint = nil
      let policy = try? NativeCertificatePolicy(status: request.certificateStatus)
      var problems = policy?.reasons.map(\.message) ?? ["Certificate verification policy is unavailable."]
      if let certificate = validIdentity ? SecCertificateCreateWithData(nil, request.identity as CFData) : nil {
        subject = SecCertificateCopySubjectSummary(certificate) as String?
        mayConnectOnce = policy?.mayOverride == true
      } else {
        subject = nil; mayConnectOnce = false
        problems.append("The server certificate could not be decoded.")
      }
      self.problems = problems
    } else if request.kind == .hostKey {
      subject = nil; mayConnectOnce = (try? NativeHostKey(request.identity)) != nil
      problems = mayConnectOnce ? ["This server key has not been verified. Compare its fingerprint with the server administrator before continuing."] : ["The server did not provide a usable key identity."]
      // RSA-AES supplies RealVNC's truncated SHA-1 display format. Never label it
      // SHA-256; the SHA-256 above is independently calculated over the raw key.
      compatibilityFingerprint = mayConnectOnce ? Insecure.SHA1.hash(data: request.identity).prefix(8).map { String(format: "%02x", $0) }.joined(separator: "-") : nil
    } else {
      subject = nil; mayConnectOnce = false; compatibilityFingerprint = nil
      problems = ["This request is not a server identity decision."]
    }
  }
}
