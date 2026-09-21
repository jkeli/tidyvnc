/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_SECURITY_OPTIONS_H
#define TIDYVNC_SECURITY_OPTIONS_H
#include <cstdint>
#include <list>
#include <stdexcept>
#include <string>
#include <vector>
namespace viewer {
enum class SecurityProtection { None, AnonymousTLS, X509TLS, RSAAES, RSAAuthentication, LegacyAuthentication };
enum class SecurityCredentials { None, Password, UsernamePassword, ServerSelected };
struct SecurityChoice {
  uint32_t type;
  const char* name;
  SecurityProtection protection;
  SecurityCredentials credentials;
  uint32_t aesBits;
  bool available;
};
const std::vector<SecurityChoice>& securityChoices();
enum class SecurityOptionProblem { UnknownType = 1, Unavailable, TooLong, InvalidSyntax, InvalidTLSPriority };
class SecurityOptionError : public std::invalid_argument {
public:
  explicit SecurityOptionError(SecurityOptionProblem problem_) : std::invalid_argument("Invalid security selection"), problem(problem_) {}
  const SecurityOptionProblem problem;
};
// Bounded preflight using a private GnuTLS priority cache. May read library
// configuration: call off UI threads. Empty uses library defaults even in builds
// without TLS. Success means usable for X509 or anonymous TLS, not that a server
// or every selected method will support it. No legacy parameters are changed.
void validateTLSPriority(const std::string& text);
// Owned allow-list only; it never changes negotiation order or legacy globals.
// Empty text deliberately denies every method. Tokens are ASCII case-insensitive,
// optional surrounding ASCII whitespace is ignored, duplicates retain first order.
class SecuritySelection {
public:
  SecuritySelection(); // Compiled defaults, never the mutable parameter registry.
  explicit SecuritySelection(const std::string& text); // At most 1024 bytes.
  const std::list<uint32_t>& types() const { return selected; }
  std::string text() const;
private:
  std::list<uint32_t> selected;
};
}
#endif
