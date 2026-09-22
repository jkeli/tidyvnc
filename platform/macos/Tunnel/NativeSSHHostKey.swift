// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import CryptoKit
import Foundation

// Key material comes from OpenSSH's KnownHostsCommand arguments, never from
// remote authentication prose. This observer supplies no trusted host entries.
public struct NativeSSHHostKey: Sendable, Equatable {
  public let hostname: String, algorithm: String, fingerprint: String
  let displayAlgorithm: String
  init?(record: String, gateway: NativeSSHGateway) {
    self.init(record:record,expectedHostname:gateway.port == 22 ? gateway.host : "[\(gateway.host)]:\(gateway.port)")
  }
  init?(record: String, expectedHostname: String) {
    let fields = record.split(separator:"\n",omittingEmptySubsequences:false)
    guard fields.count == 3 else { return nil }
    let hostname = String(fields[0]), algorithm = String(fields[1])
    guard hostname == expectedHostname, fields[2].utf8.count <= 6144,
          let data = Data(base64Encoded:String(fields[2])), data.base64EncodedString() == fields[2] else { return nil }
    let bytes = Array(data); var cursor = 0
    func field() -> ArraySlice<UInt8>? {
      guard bytes.count - cursor >= 4 else { return nil }
      let length = bytes[cursor..<cursor+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      cursor += 4
      guard length <= UInt32(bytes.count-cursor) else { return nil }
      defer { cursor += Int(length) }; return bytes[cursor..<cursor+Int(length)]
    }
    guard let name = field(), String(bytes:name,encoding:.utf8) == algorithm else { return nil }
    let display: String
    switch algorithm {
    case "ssh-ed25519":
      guard field()?.count == 32 else { return nil }; display = "ED25519"
    case "ssh-rsa":
      guard let exponent = field(), !exponent.isEmpty, exponent.count <= 8,
            let modulus = field(), modulus.count >= 128, modulus.count <= 2049 else { return nil }
      display = "RSA"
    case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
      let curve = String(algorithm.dropFirst(11))
      guard let encodedCurve = field(), String(bytes:encodedCurve,encoding:.utf8) == curve,
            let point = field(), point.first == 4,
            point.count == (curve == "nistp256" ? 65 : curve == "nistp384" ? 97 : 133) else { return nil }
      display = "ECDSA"
    default: return nil // Certificates/security-key formats need separate review.
    }
    guard cursor == bytes.count else { return nil }
    self.hostname = hostname; self.algorithm = algorithm; displayAlgorithm = display
    fingerprint = "SHA256:" + Data(SHA256.hash(data:data)).base64EncodedString().replacingOccurrences(of:"=",with:"")
  }
  func matchesConfirmation(_ text: String) -> Bool {
    // The trusted key bytes and computed fingerprint must agree with SSH's
    // confirmation. A changed/unsupported format is rejected, never answered yes.
    text.hasPrefix("The authenticity of host '\(hostname.prefix(200)) (") &&
      text.contains("\n\(displayAlgorithm) key fingerprint is: \(fingerprint)\n") &&
      text.hasSuffix("Are you sure you want to continue connecting (yes/no/[fingerprint])? ")
  }
}
