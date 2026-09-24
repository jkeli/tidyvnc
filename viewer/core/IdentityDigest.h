/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_IDENTITY_DIGEST_H
#define TIDYVNC_IDENTITY_DIGEST_H

#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>

namespace viewer {
struct SSHGateway;

// FIPS 180-4 SHA-256 without a cryptography library, so identities are
// available in every build (plans/native-ui-winui CORE.md section 6).
class Sha256 {
public:
  Sha256();
  void update(const void* data, size_t length);
  void update(const std::string& text) { update(text.data(), text.size()); }
  std::array<uint8_t, 32> finish();
  static std::string hex(const std::array<uint8_t, 32>& digest);

private:
  void block(const uint8_t* data);
  std::array<uint32_t, 8> state;
  std::array<uint8_t, 64> buffer;
  uint64_t total = 0;
  size_t used = 0;
};

enum class IdentityProblem {
  TooLong, InvalidText, InvalidEndpoint, InvalidAuthentication, UnexpectedUsername, InvalidGateway, InvalidAlias
};
class IdentityError : public std::invalid_argument {
public:
  explicit IdentityError(IdentityProblem value) : std::invalid_argument("Invalid identity input"), problem(value) {}
  const IdentityProblem problem;
};

// Versioned, domain-separated identities that name saved credentials, trust
// entries and SSH routes. Byte-identical to the macOS frontend
// (NativeCredentialKey, NativeTrustScope, NativeSSHGateway and
// NativeSSHResolvedGateway): every field is a 32-bit big-endian byte length
// followed by its bytes, numbers are 32-bit big-endian values, and the result is
// a prefix plus lowercase hexadecimal SHA-256. None of them is a secret or
// proof of trust; none contains the endpoint, route or user in clear.
namespace identity {
enum class CredentialShape : uint32_t { PasswordOnly = 1, UsernamePassword = 2 };
enum class TrustKind { Certificate, HostKey };

// "v1:<hex>". Text fields at most 4096 bytes without NUL, valid UTF-8. The
// security type is the negotiated method (not None, Invalid, VeNCrypt/TLS
// wrappers or RSA-AES negotiation types); password-only takes no username.
std::string credentialAccount(const std::string& endpoint, const std::string& route, bool allowUnixSockets,
                              uint32_t securityType, CredentialShape shape, const std::string& username);
// "v1:<hex>" over the canonical endpoint (Unix sockets allowed) and route.
std::string trustScope(const std::string& endpoint, const std::string& route, TrustKind kind);
// "ssh-v1:<hex>": the requested gateway's host, scope, port and user.
std::string sshRoute(const SSHGateway& gateway);
// "ssh-request-v2:<hex>": the requested gateway's canonical URI.
std::string sshIntent(const SSHGateway& gateway);
// "ssh-v2:<hex>": a gateway after `ssh -G` resolution. hostName is the
// resolved host (IPv6 may carry %scope), user non-empty, port 1..65535; alias
// empty means no HostKeyAlias (the lookup name then follows OpenSSH).
std::string sshResolved(const std::string& hostName, const std::string& user, uint32_t port, const std::string& alias);
}
}
#endif
