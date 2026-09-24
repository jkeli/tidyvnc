/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_LEGACY_KNOWN_HOSTS_H
#define TIDYVNC_LEGACY_KNOWN_HOSTS_H

#include <cstdint>
#include <functional>
#include <stdexcept>
#include <string>
#include <vector>

namespace viewer {
enum class KnownHostsProblem { TooLarge, Corrupt, UnsupportedFormat, UnsupportedDigest };
class KnownHostsError : public std::invalid_argument {
public:
  KnownHostsError(KnownHostsProblem value, uint32_t lineNumber)
    : std::invalid_argument("Invalid known hosts data"), problem(value), line(lineNumber) {}
  const KnownHostsProblem problem;
  const uint32_t line; // One-based line, or zero when no line applies.
};

// One GnuTLS known-hosts line: "|g0|host|service|expiration|base64 DER SPKI"
// or "|c0|host|service|expiration|algorithm|hex commitment".
struct KnownHostsRecord {
  std::string host;
  uint64_t expiration = 0;       // Seconds since the Unix epoch; 0 never expires.
  std::vector<uint8_t> key;      // g0: DER SPKI.
  uint32_t algorithm = 0;        // c0: GnuTLS digest algorithm.
  std::string commitment;        // c0: lowercase hex.
};

struct KnownHostsIdentity {
  bool commitment = false;
  uint32_t algorithm = 0;        // Commitments only.
  std::string text;              // SPKI SHA-256 "AB:CD:..." or the commitment hex.
  bool operator==(const KnownHostsIdentity& other) const
  {
    return commitment == other.commitment && algorithm == other.algorithm && text == other.text;
  }
};

struct KnownHostsMatch {
  enum class State { Missing, Match, Changed } state = State::Missing;
  std::vector<KnownHostsIdentity> expected; // Distinct, first 16 in file order.
  bool hasMore = false, wildcard = false;
  std::string received;                     // SPKI SHA-256 of the presented key.
};

// The retained viewer's x509_known_hosts, read only (NativeLegacyTrustCodec on
// macOS, plans/native-ui-winui CORE.md section 6). CConn passes no service to
// GnuTLS, so every service matches; host spelling is byte-exact and a leading
// '*' is the legacy wildcard. Nothing is written, resolved or normalized.
class LegacyKnownHosts {
public:
  static constexpr size_t maximumBytes = 1024 * 1024;
  static constexpr size_t maximumRecords = 4096;
  static constexpr size_t maximumLine = 131072;
  static constexpr size_t maximumIdentities = 16;

  // Validates the whole file: any bad line fails the lookup.
  static std::vector<KnownHostsRecord> parse(const std::string& data);
  // digest(algorithm) returns the presented key's commitment digest, or throws
  // KnownHostsError(UnsupportedDigest). It is called at most once per algorithm.
  static KnownHostsMatch lookup(const std::vector<KnownHostsRecord>& records, const std::string& host,
                                const std::vector<uint8_t>& spki, uint64_t now,
                                const std::function<std::vector<uint8_t>(uint32_t)>& digest);
  static std::string fingerprint(const std::vector<uint8_t>& bytes);
};
}
#endif
