/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include <viewer/core/SecurityOptions.h>
#include <rfb/ClientTLSOptions.h>
#include <new>
#ifdef HAVE_GNUTLS
#include <gnutls/gnutls.h>
// Concurrent sessions and validators pair gnutls_global_init/deinit per object.
// That is only safe with the thread-safe, reference-counted global lifetime.
static_assert(GNUTLS_VERSION_NUMBER >= 0x030300,
              "Concurrent native sessions require GnuTLS 3.3.0 or newer");
#endif
#include <rfb/SecurityClient.h>
#include <algorithm>

namespace viewer {
void validateTLSPriority(const std::string& text)
{
  if (text.size() > 4096) throw SecurityOptionError(SecurityOptionProblem::TooLong);
  if (text.find('\0') != std::string::npos) throw SecurityOptionError(SecurityOptionProblem::InvalidTLSPriority);
  if (text.empty()) return;
#ifdef HAVE_GNUTLS
  const auto initialized = gnutls_global_init();
  if (initialized == GNUTLS_E_MEMORY_ERROR) throw std::bad_alloc();
  if (initialized < 0) throw std::runtime_error("TLS initialization failed");
  struct TLS { ~TLS() { gnutls_global_deinit(); } } tls;
  const auto accepts = [](const std::string& expression) {
    gnutls_priority_t priority = nullptr;
    const auto status = gnutls_priority_init(&priority,expression.c_str(),nullptr);
    if (status == GNUTLS_E_MEMORY_ERROR) throw std::bad_alloc();
    if (status < 0) return false;
    gnutls_priority_deinit(priority);
    return true;
  };
  rfb::ClientTLSOptions options; options.priority = text;
  if (!accepts(options.effectivePriority(false)) && !accepts(options.effectivePriority(true)))
    throw SecurityOptionError(SecurityOptionProblem::InvalidTLSPriority);
#else
  throw SecurityOptionError(SecurityOptionProblem::Unavailable);
#endif
}

const std::vector<SecurityChoice>& securityChoices()
{
  static const auto choices = [] {
    using P = SecurityProtection;
    using C = SecurityCredentials;
    std::vector<SecurityChoice> values = {
      {rfb::secTypeNone,nullptr,P::None,C::None,0,false},
      {rfb::secTypeVncAuth,nullptr,P::None,C::Password,0,false},
      {rfb::secTypePlain,nullptr,P::None,C::UsernamePassword,0,false},
      {rfb::secTypeTLSNone,nullptr,P::AnonymousTLS,C::None,0,false},
      {rfb::secTypeTLSVnc,nullptr,P::AnonymousTLS,C::Password,0,false},
      {rfb::secTypeTLSPlain,nullptr,P::AnonymousTLS,C::UsernamePassword,0,false},
      {rfb::secTypeX509None,nullptr,P::X509TLS,C::None,0,false},
      {rfb::secTypeX509Vnc,nullptr,P::X509TLS,C::Password,0,false},
      {rfb::secTypeX509Plain,nullptr,P::X509TLS,C::UsernamePassword,0,false},
      {rfb::secTypeRA2,nullptr,P::RSAAES,C::ServerSelected,128,false},
      {rfb::secTypeRA256,nullptr,P::RSAAES,C::ServerSelected,256,false},
      {rfb::secTypeRA2ne,nullptr,P::RSAAuthentication,C::ServerSelected,128,false},
      {rfb::secTypeRAne256,nullptr,P::RSAAuthentication,C::ServerSelected,256,false},
      {rfb::secTypeDH,nullptr,P::LegacyAuthentication,C::UsernamePassword,0,false},
      {rfb::secTypeMSLogonII,nullptr,P::LegacyAuthentication,C::UsernamePassword,0,false}
    };
    const auto& supported = rfb::SecurityClient::supportedTypes();
    for (auto& choice : values) {
      choice.name = rfb::secTypeName(choice.type);
      choice.available = std::find(supported.begin(),supported.end(),choice.type) != supported.end();
    }
    return values;
  }();
  return choices;
}
SecuritySelection::SecuritySelection() : selected(rfb::SecurityClient::supportedTypes()) {}
SecuritySelection::SecuritySelection(const std::string& value)
{
  if (value.size() > 1024) throw SecurityOptionError(SecurityOptionProblem::TooLong);
  if (value.find('\0') != std::string::npos) throw SecurityOptionError(SecurityOptionProblem::InvalidSyntax);
  if (value.empty()) return;
  size_t offset = 0;
  for (;;) {
    const auto comma = value.find(',',offset);
    auto token = value.substr(offset,comma == std::string::npos ? comma : comma-offset);
    const auto first = token.find_first_not_of(" \t\r\n\f\v");
    if (first == std::string::npos) throw SecurityOptionError(SecurityOptionProblem::InvalidSyntax);
    token = token.substr(first,token.find_last_not_of(" \t\r\n\f\v")-first+1);
    const auto type = rfb::secTypeNum(token.c_str());
    const auto& choices = securityChoices();
    const auto found = std::find_if(choices.begin(),choices.end(),[&](const SecurityChoice& choice) { return choice.type == type; });
    if (found == choices.end()) throw SecurityOptionError(SecurityOptionProblem::UnknownType);
    if (!found->available) throw SecurityOptionError(SecurityOptionProblem::Unavailable);
    if (std::find(selected.begin(),selected.end(),type) == selected.end()) selected.push_back(type);
    if (comma == std::string::npos) break;
    offset = comma+1;
  }
}
std::string SecuritySelection::text() const
{
  std::string value;
  for (auto type : selected) {
    if (!value.empty()) value += ',';
    value += rfb::secTypeName(type);
  }
  return value;
}
}
