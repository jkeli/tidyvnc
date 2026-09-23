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
    case .invalid: return String(localized:"trust.certificate.reason.invalid", defaultValue:"Certificate verification failed.")
    case .revoked: return String(localized:"trust.certificate.reason.revoked", defaultValue:"The certificate has been revoked.")
    case .unknownIssuer: return String(localized:"trust.certificate.reason.unknownIssuer", defaultValue:"The certificate issuer is not trusted.")
    case .signerNotCA: return String(localized:"trust.certificate.reason.signerNotCA", defaultValue:"The signer is not a certificate authority.")
    case .weakAlgorithm: return String(localized:"trust.certificate.reason.weakAlgorithm", defaultValue:"The certificate uses an insecure algorithm.")
    case .notYetValid: return String(localized:"trust.certificate.reason.notYetValid", defaultValue:"The certificate is not yet valid.")
    case .expired: return String(localized:"trust.certificate.reason.expired", defaultValue:"The certificate has expired.")
    case .badSignature: return String(localized:"trust.certificate.reason.badSignature", defaultValue:"The certificate signature is invalid.")
    case .oldRevocationData: return String(localized:"trust.certificate.reason.oldRevocationData", defaultValue:"The revocation information is out of date.")
    case .wrongOwner: return String(localized:"trust.certificate.reason.wrongOwner", defaultValue:"The certificate does not match the requested server name.")
    case .futureRevocationData: return String(localized:"trust.certificate.reason.futureRevocationData", defaultValue:"The revocation information has a future issue date.")
    case .signerConstraints: return String(localized:"trust.certificate.reason.signerConstraints", defaultValue:"The signer violates certificate constraints.")
    case .mismatch: return String(localized:"trust.certificate.reason.mismatch", defaultValue:"The certificate does not match the required identity.")
    case .wrongPurpose: return String(localized:"trust.certificate.reason.wrongPurpose", defaultValue:"The certificate is not valid for this purpose.")
    case .missingOCSP: return String(localized:"trust.certificate.reason.missingOCSP", defaultValue:"Required certificate status information is missing.")
    case .invalidOCSP: return String(localized:"trust.certificate.reason.invalidOCSP", defaultValue:"The certificate status response is invalid.")
    case .criticalExtension: return String(localized:"trust.certificate.reason.criticalExtension", defaultValue:"A required certificate extension is unsupported.")
    case .unknownProblem: return String(localized:"trust.certificate.reason.unknownProblem", defaultValue:"The certificate has an unrecognized verification problem.")
    case .missingProblem: return String(localized:"trust.certificate.reason.missingProblem", defaultValue:"No certificate verification reason was supplied.")
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
  // Certificate details shown by the retained viewer's trust dialog.
  public let certificate: NativeCertificateDetails?
  public var description: String { "NativeTrustPresentation(<redacted>)" }
  public var debugDescription: String { description }
  public init(_ request: NativePrompt) {
    let validIdentity = !request.identity.isEmpty && request.identity.count <= 65536
    sha256Fingerprint = validIdentity ? SHA256.hash(data: request.identity).map { String(format: "%02X", $0) }.joined(separator: ":") : nil
    if request.kind == .certificate {
      compatibilityFingerprint = nil
      let policy = try? NativeCertificatePolicy(status: request.certificateStatus)
      var problems = policy?.reasons.map(\.message) ?? [String(localized:"trust.presentation.policyUnavailable", defaultValue:"Certificate verification policy is unavailable.")]
      if let certificate = validIdentity ? SecCertificateCreateWithData(nil, request.identity as CFData) : nil {
        subject = SecCertificateCopySubjectSummary(certificate) as String?
        self.certificate = NativeCertificateDetails(certificate)
        mayConnectOnce = policy?.mayOverride == true
      } else {
        subject = nil; mayConnectOnce = false; self.certificate = nil
        problems.append(String(localized:"trust.presentation.certificateDecode", defaultValue:"The server certificate could not be decoded."))
      }
      self.problems = problems
    } else if request.kind == .hostKey {
      subject = nil; certificate = nil; mayConnectOnce = (try? NativeHostKey(request.identity)) != nil
      problems = mayConnectOnce ? [String(localized:"trust.presentation.keyUnverified", defaultValue:"This server key has not been verified. Compare its fingerprint with the server administrator before continuing.")] : [String(localized:"trust.presentation.keyUnavailable", defaultValue:"The server did not provide a usable key identity.")]
      // RSA-AES supplies RealVNC's truncated SHA-1 display format. Never label it
      // SHA-256; the SHA-256 above is independently calculated over the raw key.
      compatibilityFingerprint = mayConnectOnce ? Insecure.SHA1.hash(data: request.identity).prefix(8).map { String(format: "%02x", $0) }.joined(separator: "-") : nil
    } else {
      subject = nil; certificate = nil; mayConnectOnce = false; compatibilityFingerprint = nil
      problems = [String(localized:"trust.presentation.invalidRequest", defaultValue:"This request is not a server identity decision.")]
    }
  }
}

// Issuer, serial, validity, public key and signature algorithm of a decoded
// certificate, read with the Security framework. Every field is optional; an
// unreadable field is omitted rather than guessed.
public struct NativeCertificateDetails: Sendable, Equatable {
  public let issuer: String?
  public let serialNumber: String?
  public let validFrom: Date?, validUntil: Date?
  public let keyAlgorithm: String?, keyBits: Int?
  public let signatureAlgorithm: String?
  private static let nameOIDs: [(String, String)] = [("2.5.4.3", "CN"), ("2.5.4.11", "OU"), ("2.5.4.10", "O"),
    ("2.5.4.7", "L"), ("2.5.4.8", "ST"), ("2.5.4.6", "C")]
  private static let signatures: [String: String] = [
    "1.2.840.113549.1.1.5": "RSA-SHA1", "1.2.840.113549.1.1.11": "RSA-SHA256", "1.2.840.113549.1.1.12": "RSA-SHA384",
    "1.2.840.113549.1.1.13": "RSA-SHA512", "1.2.840.113549.1.1.10": "RSA-PSS", "1.2.840.10045.4.3.2": "ECDSA-SHA256",
    "1.2.840.10045.4.3.3": "ECDSA-SHA384", "1.2.840.10045.4.3.4": "ECDSA-SHA512", "1.3.101.112": "Ed25519", "1.3.101.113": "Ed448"]
  init(_ certificate: SecCertificate) {
    let keys = [kSecOIDX509V1IssuerName, kSecOIDX509V1ValidityNotBefore, kSecOIDX509V1ValidityNotAfter,
                kSecOIDX509V1SignatureAlgorithm] as CFArray
    let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: [String: Any]] ?? [:]
    func value(_ key: CFString) -> Any? { values[key as String]?[kSecPropertyKeyValue as String] }
    if let parts = value(kSecOIDX509V1IssuerName) as? [[String: Any]] {
      let fields = parts.compactMap { part -> (String, String)? in
        guard let label = part[kSecPropertyKeyLabel as String] as? String,
              let text = part[kSecPropertyKeyValue as String] as? String else { return nil }
        return (label, text)
      }
      let named = Self.nameOIDs.flatMap { oid, name in fields.filter { $0.0 == oid }.map { "\(name)=\($0.1)" } }
      issuer = named.isEmpty ? nil : named.joined(separator: ", ")
    } else { issuer = nil }
    func date(_ key: CFString) -> Date? { (value(key) as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) } }
    validFrom = date(kSecOIDX509V1ValidityNotBefore); validUntil = date(kSecOIDX509V1ValidityNotAfter)
    if let parts = value(kSecOIDX509V1SignatureAlgorithm) as? [[String: Any]],
       let oid = parts.first(where: { ($0[kSecPropertyKeyLabel as String] as? String) == "Algorithm" })?[kSecPropertyKeyValue as String] as? String {
      signatureAlgorithm = Self.signatures[oid] ?? oid
    } else { signatureAlgorithm = nil }
    serialNumber = (SecCertificateCopySerialNumberData(certificate, nil) as Data?).map {
      $0.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    if let key = SecCertificateCopyKey(certificate), let attributes = SecKeyCopyAttributes(key) as? [String: Any] {
      let type = attributes[kSecAttrKeyType as String] as? String
      keyAlgorithm = type == (kSecAttrKeyTypeRSA as String) ? "RSA" : type == (kSecAttrKeyTypeECSECPrimeRandom as String) ? "EC" : nil
      keyBits = (attributes[kSecAttrKeySizeInBits as String] as? NSNumber)?.intValue
    } else { keyAlgorithm = nil; keyBits = nil }
  }
}
