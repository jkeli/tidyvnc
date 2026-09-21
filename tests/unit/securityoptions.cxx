/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include <gtest/gtest.h>
#include <core/Configuration.h>
#include <viewer/core/SecurityOptions.h>
#include <viewer/core/ProtocolSession.h>
#include <rfb/Exception.h>
#include <rdr/MemInStream.h>
#include <rdr/MemOutStream.h>
#include <algorithm>
#include <future>
#include <set>
using namespace viewer;
namespace {
void problem(const std::string& text, SecurityOptionProblem expected) {
  try { SecuritySelection value(text); FAIL() << "Accepted invalid selection"; }
  catch (const SecurityOptionError& error) { EXPECT_EQ(error.problem,expected); }
}
std::vector<uint8_t> negotiate(const std::string& selection,const std::vector<uint8_t>& offers,bool extended = false,bool old = false) {
  rdr::MemOutStream wire, output;
  const char* version = old ? "RFB 003.003\n" : "RFB 003.008\n";
  wire.writeBytes(reinterpret_cast<const uint8_t*>(version),12);
  if (old) { wire.writeU32(offers[0]); }
  else {
    wire.writeU8(extended ? 1 : offers.size());
    if (extended) wire.writeU8(rfb::secTypeVeNCrypt);
    else for (auto type : offers) wire.writeU8(type);
  }
  if (extended) {
    wire.writeU8(0); wire.writeU8(2); wire.writeU8(0); wire.writeU8(offers.size());
    for (auto type : offers) wire.writeU32(type);
  }
  rdr::MemInStream input(wire.data(),wire.length());
  ProtocolSession session(rfb::SecurityClient(SecuritySelection(selection).types()));
  session.start("isolated.invalid",input,output);
  // The independent fixture ends after security offers, before credentials.
  try { for (int i = 0; i < 12 && session.processMessage(); ++i) {} }
  catch (const rdr::end_of_stream&) {}
  return {output.data(),output.data()+output.length()};
}
}
TEST(SecurityOptions, CatalogMatchesCompiledMethodsAndCanonicalNames)
{
  const auto& choices = securityChoices(); ASSERT_EQ(choices.size(),15u);
  std::set<uint32_t> seen, compiled;
  for (const auto& choice : choices) {
    EXPECT_TRUE(seen.insert(choice.type).second);
    EXPECT_EQ(choice.type,rfb::secTypeNum(choice.name));
    EXPECT_STREQ(choice.name,rfb::secTypeName(choice.type));
    if (choice.available) {
      compiled.insert(choice.type);
      EXPECT_EQ(SecuritySelection(choice.name).types(),std::list<uint32_t>{choice.type});
    } else problem(choice.name,SecurityOptionProblem::Unavailable);
    if (choice.protection == SecurityProtection::RSAAES || choice.protection == SecurityProtection::RSAAuthentication) {
      EXPECT_EQ(choice.credentials,SecurityCredentials::ServerSelected);
      EXPECT_TRUE(choice.aesBits == 128 || choice.aesBits == 256);
    }
  }
  const auto& supported = rfb::SecurityClient::supportedTypes();
  EXPECT_EQ(compiled,(std::set<uint32_t>(supported.begin(),supported.end())));
  EXPECT_EQ(SecuritySelection().types(),supported);
  EXPECT_EQ(SecuritySelection(SecuritySelection().text()).types(),supported);
}
TEST(SecurityOptions, CanonicalExactListAndEmptyDenyAll)
{
  const SecuritySelection selection(" vNcAuth ,pLaIn, None, VncAuth ");
  EXPECT_EQ(selection.text(),"VncAuth,Plain,None");
  EXPECT_EQ(selection.types(),(std::list<uint32_t>{rfb::secTypeVncAuth,rfb::secTypePlain,rfb::secTypeNone}));
  EXPECT_TRUE(SecuritySelection("").types().empty());
  for (const auto& value : {"VeNCrypt","Tight","SSPI","Unknown","1","None Plain"}) problem(value,SecurityOptionProblem::UnknownType);
  for (const auto& value : {" ",",None","None,","None,,Plain"}) problem(value,SecurityOptionProblem::InvalidSyntax);
  problem(std::string("None\0Plain",10),SecurityOptionProblem::InvalidSyntax);
  problem(std::string(1025,'x'),SecurityOptionProblem::TooLong);
  EXPECT_EQ(SecuritySelection(std::string(1020,' ') + "None").text(),"None");
}
TEST(SecurityOptions, IndependentOfMutableLegacyPolicyAndConcurrentReaders)
{
  struct Guard { std::string saved = rfb::SecurityClient::secTypes.getValueStr(); ~Guard() { rfb::SecurityClient::secTypes.setParam(saved.c_str()); } } guard;
  ASSERT_TRUE(rfb::SecurityClient::secTypes.setParam("None"));
  const auto defaults = SecuritySelection().text();
  EXPECT_NE(defaults,"None");
  std::vector<std::future<bool>> readers;
  for (int i = 0; i < 8; ++i) readers.push_back(std::async(std::launch::async,[defaults] {
    for (int n = 0; n < 100; ++n) {
      if (SecuritySelection().text() != defaults || SecuritySelection("plain,none").text() != "Plain,None" || securityChoices().size() != 15) return false;
    }
    return true;
  }));
  for (auto& reader : readers) EXPECT_TRUE(reader.get());
  EXPECT_EQ(rfb::SecurityClient::secTypes.getValueStr(),"None");
}
TEST(SecurityOptions, NegotiationKeepsServerOrderAndRefusesDisabledMethods)
{
  for (auto offers : {std::vector<uint8_t>{rfb::secTypeNone,rfb::secTypeVncAuth},std::vector<uint8_t>{rfb::secTypeVncAuth,rfb::secTypeNone}}) {
    const auto both = negotiate("VncAuth,None",offers);
    ASSERT_GE(both.size(),13u); EXPECT_EQ(both[12],offers[0]);
    const auto restricted = negotiate("VncAuth",offers);
    ASSERT_GE(restricted.size(),13u); EXPECT_EQ(restricted[12],rfb::secTypeVncAuth);
  }
  EXPECT_THROW(negotiate("VncAuth",{rfb::secTypeNone}),rfb::protocol_error);
  EXPECT_THROW(negotiate("",{rfb::secTypeNone,rfb::secTypeVncAuth}),rfb::protocol_error);
  EXPECT_THROW(negotiate("VncAuth",{rfb::secTypeNone},false,true),rfb::protocol_error);
  EXPECT_THROW(negotiate("",{rfb::secTypeNone},false,true),rfb::protocol_error);
  const auto extended = negotiate("Plain,VncAuth",{rfb::secTypeNone,rfb::secTypeVncAuth},true);
  ASSERT_EQ(extended.size(),19u); EXPECT_EQ(extended[12],rfb::secTypeVeNCrypt);
  EXPECT_EQ(extended[18],rfb::secTypeVncAuth);
  EXPECT_THROW(negotiate("Plain",{rfb::secTypeNone,rfb::secTypeVncAuth},true),rfb::protocol_error);
}

TEST(SecurityOptions, PriorityValidationBoundsAndAvailability)
{
  EXPECT_NO_THROW(validateTLSPriority(""));
  const auto rejected = [](const std::string& text, SecurityOptionProblem expected) {
    try { validateTLSPriority(text); FAIL() << "Invalid priority accepted"; }
    catch (const SecurityOptionError& error) { EXPECT_EQ(error.problem,expected); }
  };
  rejected(std::string(4097,'x'),SecurityOptionProblem::TooLong);
  rejected(std::string("NORMAL\0extra",12),SecurityOptionProblem::InvalidTLSPriority);
#ifdef HAVE_GNUTLS
  for (const auto* text : {"NORMAL","NORMAL:-VERS-ALL:+VERS-TLS1.2",
      "NORMAL:-VERS-ALL:+VERS-TLS1.2:-KX-ALL"})
    EXPECT_NO_THROW(validateTLSPriority(text)); // Last expression needs anonymous KX append.
  for (const auto* text : {"invalid-priority", "NORMAL:+invalid-algorithm", "NORMAL:-VERS-ALL"})
    rejected(text,SecurityOptionProblem::InvalidTLSPriority);
  std::vector<std::future<void>> readers;
  for (int i=0;i<8;++i) readers.push_back(std::async(std::launch::async,[] {
    for (int j=0;j<20;++j) validateTLSPriority("NORMAL:-VERS-ALL:+VERS-TLS1.2");
  }));
  for (auto& reader : readers) EXPECT_NO_THROW(reader.get());
#else
  rejected("NORMAL",SecurityOptionProblem::Unavailable);
#endif
}
