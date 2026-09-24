/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "IdentityDigest.h"

#include <cstring>

#include <core/string.h>

#include "Endpoint.h"
#include "SSHGateway.h"

namespace viewer {
namespace {
constexpr std::array<uint32_t, 64> roundConstants = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

inline uint32_t rotate(uint32_t value, int bits) { return (value >> bits) | (value << (32 - bits)); }
}

Sha256::Sha256()
  : state{0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}, buffer{}
{
}

void Sha256::block(const uint8_t* data)
{
  uint32_t w[64];
  for (int i = 0; i < 16; i++)
    w[i] = uint32_t(data[i * 4]) << 24 | uint32_t(data[i * 4 + 1]) << 16 | uint32_t(data[i * 4 + 2]) << 8 | data[i * 4 + 3];
  for (int i = 16; i < 64; i++) {
    const uint32_t s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3);
    const uint32_t s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = state[0], b = state[1], c = state[2], d = state[3], e = state[4], f = state[5], g = state[6], h = state[7];
  for (int i = 0; i < 64; i++) {
    const uint32_t t1 = h + (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) + ((e & f) ^ (~e & g)) + roundConstants[i] + w[i];
    const uint32_t t2 = (rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
    h = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
  }
  state[0] += a; state[1] += b; state[2] += c; state[3] += d;
  state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

void Sha256::update(const void* data, size_t length)
{
  auto bytes = static_cast<const uint8_t*>(data);
  total += length;
  while (length > 0) {
    const size_t take = std::min(length, buffer.size() - used);
    std::memcpy(buffer.data() + used, bytes, take);
    used += take; bytes += take; length -= take;
    if (used == buffer.size()) { block(buffer.data()); used = 0; }
  }
}

std::array<uint8_t, 32> Sha256::finish()
{
  const uint64_t bits = total * 8;
  const uint8_t one = 0x80, zero = 0;
  update(&one, 1);
  while (used != 56) update(&zero, 1);
  uint8_t length[8];
  for (int i = 0; i < 8; i++) length[i] = uint8_t(bits >> (56 - 8 * i));
  update(length, 8);
  std::array<uint8_t, 32> digest{};
  for (int i = 0; i < 8; i++)
    for (int j = 0; j < 4; j++) digest[i * 4 + j] = uint8_t(state[i] >> (24 - 8 * j));
  return digest;
}

std::string Sha256::hex(const std::array<uint8_t, 32>& digest)
{
  static const char digits[] = "0123456789abcdef";
  std::string text;
  text.reserve(64);
  for (auto byte : digest) { text += digits[byte >> 4]; text += digits[byte & 15]; }
  return text;
}

namespace identity {
namespace {
constexpr size_t maximumText = 4096;

// The macOS digests' field encoding: a 32-bit big-endian length, then bytes.
class Fields {
public:
  void text(const std::string& value) { raw(uint32_t(value.size())); hash.update(value); }
  // A number is itself a four-byte field: length 4, then the value.
  void number(uint32_t value) { raw(4); raw(value); }
  std::string finish(const char* prefix) { return prefix + Sha256::hex(hash.finish()); }

private:
  void raw(uint32_t value)
  {
    const uint8_t bytes[4] = {uint8_t(value >> 24), uint8_t(value >> 16), uint8_t(value >> 8), uint8_t(value)};
    hash.update(bytes, 4);
  }
  Sha256 hash;
};

// NativeCredentialKey/NativeTrustScope `bounded`: length first, then NUL.
void bounded(const std::string& value)
{
  if (value.size() > maximumText) throw IdentityError(IdentityProblem::TooLong);
  if (value.find('\0') != std::string::npos || !core::isValidUTF8(value.data(), value.size()))
    throw IdentityError(IdentityProblem::InvalidText);
}

Endpoint canonical(const std::string& endpoint, const std::string& route, bool allowUnixSockets)
{
  try {
    return Endpoint::parse(endpoint, allowUnixSockets, route);
  } catch (const EndpointError&) {
    throw IdentityError(IdentityProblem::InvalidEndpoint);
  }
}

void endpointFields(Fields& fields, const Endpoint& value)
{
  // The ABI transport values (TIDYVNC_ENDPOINT_TCP 1, _UNIX 2).
  fields.number(value.transport() == EndpointTransport::Tcp ? 1 : 2);
  fields.text(value.host()); fields.text(value.scope()); fields.number(value.port());
  fields.text(value.path()); fields.text(value.route());
}
}

std::string credentialAccount(const std::string& endpoint, const std::string& route, bool allowUnixSockets,
                              uint32_t securityType, CredentialShape shape, const std::string& username)
{
  bounded(endpoint); bounded(route); bounded(username);
  if (shape != CredentialShape::PasswordOnly && shape != CredentialShape::UsernamePassword)
    throw IdentityError(IdentityProblem::InvalidAuthentication);
  if (shape == CredentialShape::PasswordOnly && !username.empty())
    throw IdentityError(IdentityProblem::UnexpectedUsername);
  // None, Invalid and the negotiation wrappers (TLS, VeNCrypt, RA2, RA2ne) do
  // not identify a credential method; the negotiated subtype is required.
  switch (securityType) {
  case 0: case 1: case 18: case 19: case 257: case 260:
    throw IdentityError(IdentityProblem::InvalidAuthentication);
  default: break;
  }
  const auto value = canonical(endpoint, route, allowUnixSockets);
  Fields fields;
  fields.text("io.github.jkeli.tidyvnc.credentials.v1");
  endpointFields(fields, value);
  fields.number(securityType); fields.number(static_cast<uint32_t>(shape)); fields.text(username);
  return fields.finish("v1:");
}

std::string trustScope(const std::string& endpoint, const std::string& route, TrustKind kind)
{
  bounded(endpoint); bounded(route);
  if (endpoint.empty()) throw IdentityError(IdentityProblem::InvalidEndpoint);
  const auto value = canonical(endpoint, route, true);
  Fields fields;
  fields.text(kind == TrustKind::Certificate ? "io.github.jkeli.tidyvnc.trust.x509-spki.v1"
                                             : "io.github.jkeli.tidyvnc.trust.rsa-aes.v1");
  endpointFields(fields, value);
  return fields.finish("v1:");
}

std::string sshRoute(const SSHGateway& gateway)
{
  Fields fields;
  fields.text("tidyvnc-ssh-v1"); fields.text(gateway.host); fields.text(gateway.scope);
  fields.text(std::to_string(gateway.port));
  fields.text(gateway.hasUser ? "explicit-user" : "implicit-user"); fields.text(gateway.user);
  return fields.finish("ssh-v1:");
}

std::string sshIntent(const SSHGateway& gateway)
{
  // Not length-prefixed: one domain string, a NUL and the canonical URI.
  Sha256 hash;
  hash.update("tidyvnc-ssh-intent-v2", 21);
  const char separator = '\0';
  hash.update(&separator, 1);
  hash.update(gateway.canonicalURI);
  return "ssh-request-v2:" + Sha256::hex(hash.finish());
}

std::string sshResolved(const std::string& hostName, const std::string& user, uint32_t port, const std::string& alias)
{
  if (hostName.empty() || user.empty() || port == 0 || port > 65535 || hostName.size() > maximumText ||
      user.size() > maximumText)
    throw IdentityError(IdentityProblem::InvalidGateway);
  // NativeSSHResolvedGateway: the resolved fields must form a valid gateway.
  const bool literal = hostName.find(':') != std::string::npos && hostName.front() != '[';
  SSHGateway gateway;
  try {
    gateway = SSHGateway::parse("ssh://" + user + "@" + (literal ? "[" + hostName + "]" : hostName) + ":" + std::to_string(port));
  } catch (const std::invalid_argument&) {
    throw IdentityError(IdentityProblem::InvalidGateway);
  }
  if (!alias.empty()) {
    static const char allowed[] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]%@";
    if (alias.size() > 1024 || alias.find_first_not_of(allowed) != std::string::npos)
      throw IdentityError(IdentityProblem::InvalidAlias);
  }
  const auto host = gateway.host + (gateway.scope.empty() ? "" : "%" + gateway.scope);
  // OpenSSH uses an explicit alias verbatim, including at a nondefault port.
  const auto lookup = !alias.empty() ? alias : gateway.port == 22 ? host : "[" + host + "]:" + std::to_string(gateway.port);
  Fields fields;
  fields.text("tidyvnc-ssh-resolved-v2"); fields.text(host); fields.text(gateway.user);
  fields.text(std::to_string(gateway.port));
  fields.text(alias.empty() ? "default-host-key" : "explicit-host-key"); fields.text(lookup);
  return fields.finish("ssh-v2:");
}
}
}
