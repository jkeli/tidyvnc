// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Foundation
@testable import TidyVNCNative

struct Failure: Error { let message: String }
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  if !condition() { throw Failure(message: message) }
}
func request(_ kind: NativePrompt.Kind, status: UInt32 = 0, identity: Data = trustFixtureCertificate,
             compatibility: String = "") -> NativePrompt {
  NativePrompt(id: 1, generation: 7, kind: kind, secure: false, usernameRequired: false,
    certificateStatus: status, serverName: "fixture.invalid", fingerprint: compatibility, identity: identity)
}
func policy() throws {
  let rows: [(Int, NativeCertificateReason, Bool)] = [
    (1,.invalid,true),(5,.revoked,false),(6,.unknownIssuer,true),(7,.signerNotCA,true),
    (8,.weakAlgorithm,true),(9,.notYetValid,true),(10,.expired,true),(11,.badSignature,false),
    (12,.oldRevocationData,false),(14,.wrongOwner,true),(15,.futureRevocationData,false),
    (16,.signerConstraints,false),(17,.mismatch,false),(18,.wrongPurpose,false),
    (19,.missingOCSP,false),(20,.invalidOCSP,false),(21,.criticalExtension,false)
  ]
  for (bit, reason, allowed) in rows {
    let result = try NativeCertificatePolicy(status: 1 << bit)
    try check(result.reasons == [reason] && result.mayOverride == allowed, "portable reason and policy \(bit)")
    try check(result.fatalStatus == (allowed ? 0 : 1 << bit), "fatal status preserves unsupported reason")
    try check(!reason.message.isEmpty, "each reason has a user-facing explanation")
  }
  let missing = try NativeCertificatePolicy(status: 0), unknown = try NativeCertificatePolicy(status: 1 << 31)
  try check(!missing.mayOverride && missing.reasons == [.missingProblem], "zero cannot authorize an exception")
  try check(!unknown.mayOverride && unknown.reasons == [.unknownProblem], "unknown bits fail closed")
  let mixed = try NativeCertificatePolicy(status: 66 | 32)
  try check(!mixed.mayOverride && mixed.reasons == [.invalid,.revoked,.unknownIssuer], "allowed problems cannot conceal a fatal problem")
  print("PASS all certificate reason mappings, legacy override mask, fatal/unknown/zero policy")
}
func presentation() throws {
  let ordinary = NativeTrustPresentation(request(.certificate,status: 66))
  try check(ordinary.mayConnectOnce && ordinary.subject == "loopback-trust-fixture.invalid", "real DER subject and permitted exception")
  try check(ordinary.sha256Fingerprint?.count == 95 && ordinary.compatibilityFingerprint == nil, "certificate SHA-256 only")
  for status: UInt32 in [0,32,2048,1 << 31,66 | 32] {
    let value = NativeTrustPresentation(request(.certificate,status: status))
    try check(!value.mayConnectOnce && !value.problems.isEmpty, "fatal trust UI cannot enable approval")
  }
  let broken = NativeTrustPresentation(request(.certificate,status: 66,identity: Data([1,2,3])))
  try check(!broken.mayConnectOnce && broken.subject == nil && broken.problems.contains("The server certificate could not be decoded."), "malformed identity fails closed")
  let key = NativeTrustPresentation(request(.hostKey,identity: hostKeyFixture,compatibility: "untrusted display value"))
  try check(key.mayConnectOnce && key.sha256Fingerprint == hostKeyFixtureSHA256, "independent SHA-256 golden over raw key identity")
  try check(key.compatibilityFingerprint == hostKeyFixtureCompatibility && key.sha256Fingerprint != key.compatibilityFingerprint, "legacy fingerprint cannot masquerade as SHA-256")
  try check(!String(describing: key).contains("01-02") && !String(reflecting: ordinary).contains("fixture.invalid"), "descriptions redact trust material")
  for data in [Data(),Data(repeating: 1,count: 65537)] {
    let invalid = NativeTrustPresentation(request(.hostKey,identity: data))
    try check(!invalid.mayConnectOnce && invalid.sha256Fingerprint == nil, "bounded nonempty identities")
  }
  try check(!NativeTrustPresentation(request(.hostKey,identity: Data([1,2,3]))).mayConnectOnce,"malformed RSA encoding cannot be approved")
  try check(!NativeTrustPresentation(request(.credentials)).mayConnectOnce, "credentials are never a trust decision")
  print("PASS DER presentation, fatal/malformed denial, fingerprint algorithms, bounds and redaction")
}
@main struct NativeTrustTests {
  static func main() async {
    do {
      try policy(); try presentation()
      try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<64 { group.addTask { let value = try NativeCertificatePolicy(status: 66); try check(value.mayOverride, "concurrent stateless classification") } }
        try await group.waitForAll()
      }
    } catch { FileHandle.standardError.write(Data("FAIL \(error)\n".utf8)); exit(1) }
  }
}
