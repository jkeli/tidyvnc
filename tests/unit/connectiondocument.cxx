/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/ConnectionDocument.h>
#include <viewer/core/DocumentOptions.h>
#include <core/Configuration.h>
#include <atomic>
#include <thread>

using namespace viewer;
namespace {
std::string document(const std::string& body) {
  return std::string(ConnectionDocument::header()) + "\n" + body;
}
void rejects(const std::string& bytes, DocumentErrorCode code, size_t line = 0) {
  try { ConnectionDocument::parse(bytes); FAIL() << "Accepted invalid document"; }
  catch (const DocumentError& error) { EXPECT_EQ(error.code, code); EXPECT_EQ(error.line, line); }
}
}

TEST(ConnectionDocument, ExactHeadersAndLineEndings) {
  for (const auto* header : {ConnectionDocument::header(), ConnectionDocument::legacyHeader()}) {
    for (const auto* eol : {"\n", "\r\n"}) {
      auto parsed = ConnectionDocument::parse(std::string(header) + eol + "ServerName=[::1]:2" + eol);
      EXPECT_EQ(parsed.isLegacy(), header == ConnectionDocument::legacyHeader());
      ASSERT_EQ(parsed.entries().size(), 1u);
      EXPECT_EQ(parsed.entries()[0].value(), "[::1]:2");
      EXPECT_EQ(parsed.entries()[0].line, 2u);
    }
    EXPECT_TRUE(ConnectionDocument::parse(header).entries().empty());
  }
  rejects("", DocumentErrorCode::Empty);
  rejects(document("").insert(0, "\xef\xbb\xbf"), DocumentErrorCode::InvalidHeader, 1);
  for (const auto* suffix : {"junk", " ", "\rjunk"})
    rejects(std::string(ConnectionDocument::header()) + suffix, DocumentErrorCode::InvalidHeader, 1);
  rejects("TidyVNC Configuration file Version 2.0\n", DocumentErrorCode::InvalidHeader, 1);
}

TEST(ConnectionDocument, PreservesOrderDuplicatesBytesAndUnknownEntries) {
  auto parsed = ConnectionDocument::parse(document("#comment\n\n\r\nserverNAME=first\nServerName=héllo=last\nUnknown=\\q\n=empty-name\n"));
  ASSERT_EQ(parsed.entries().size(), 4u);
  EXPECT_EQ(parsed.entries()[0].name, "serverNAME");
  EXPECT_EQ(parsed.entries()[0].line, 5u);
  EXPECT_EQ(parsed.entries()[1].value(), "héllo=last");
  EXPECT_EQ(parsed.entries()[2].encodedValue, "\\q");
  EXPECT_THROW(parsed.entries()[2].value(), DocumentError);
  EXPECT_TRUE(parsed.entries()[3].name.empty());
  rejects(document(" #not-a-comment\n"), DocumentErrorCode::InvalidAssignment, 2);
  rejects(document("broken\n"), DocumentErrorCode::InvalidAssignment, 2);
  EXPECT_EQ(ConnectionDocument::parse(document("ServerName=last")).entries()[0].value(), "last");
}

TEST(ConnectionDocument, EscapingAndRedactedTypedErrors) {
  const std::string raw = "line\nreturn\rback\\slash=é";
  EXPECT_EQ(ConnectionDocument::decodeValue(ConnectionDocument::encodeValue(raw)), raw);
  for (const auto* invalid : {"password-secret\\q", "password-secret\\", "\\t"}) {
    try { ConnectionDocument::parse(document(std::string("ServerName=") + invalid)).entries()[0].value(); FAIL(); }
    catch (const DocumentError& error) {
      EXPECT_EQ(error.code, DocumentErrorCode::InvalidEscape);
      EXPECT_EQ(error.line, 2u);
      EXPECT_EQ(std::string(error.what()).find("secret"), std::string::npos);
    }
  }
  rejects(document(std::string("#comment\0hidden", 15)), DocumentErrorCode::NullByte, 2);
  EXPECT_THROW(ConnectionDocument::encodeValue(std::string("a\0b", 3)), DocumentError);
  EXPECT_THROW(ConnectionDocument::decodeValue(std::string("a\0b", 3)), DocumentError);
}

TEST(ConnectionDocument, HistoricalLineBoundaryCountsTerminators) {
  for (const std::string ending : {"", "\n", "\r\n"}) {
    const auto line = std::string("x=") + std::string(252 - ending.size(), 'x') + ending;
    EXPECT_EQ(ConnectionDocument::parse(document(line)).entries().size(), 1u);
    rejects(document("x" + line), DocumentErrorCode::LineTooLong, 2);
  }
  // Comments are bounded too; they must not bypass resource limits.
  rejects(document("#" + std::string(254, 'x')), DocumentErrorCode::LineTooLong, 2);
}

TEST(ConnectionDocument, BoundedDocumentAndAssignmentCount) {
  std::string input = document("");
  for (size_t i = 0; i < ConnectionDocument::maximumEntries; ++i) input += "x=\n";
  EXPECT_EQ(ConnectionDocument::parse(input).entries().size(), ConnectionDocument::maximumEntries);
  rejects(input + "x=\n", DocumentErrorCode::TooManyEntries, ConnectionDocument::maximumEntries + 2);
  input = document("");
  input.append(ConnectionDocument::maximumBytes - input.size(), '\n');
  EXPECT_TRUE(ConnectionDocument::parse(input).entries().empty());
  rejects(input + "\n", DocumentErrorCode::TooLarge);
}

TEST(ConnectionDocument, ExportIsCurrentCanonicalAndNeverPassesUnknownOrSecretFields) {
  auto bytes = ConnectionDocument::serialize({{"servername", "host\\path\n"}, {"fullcolor", "on"}});
  EXPECT_EQ(bytes, document("\nServerName=host\\\\path\\n\nFullColor=on\n"));
  auto parsed = ConnectionDocument::parse(bytes);
  EXPECT_FALSE(parsed.isLegacy());
  EXPECT_EQ(parsed.entries()[0].value(), "host\\path\n");
  for (const auto* name : {"Password", "passwd", "PasswordFile", "UserName", "via", "Tunnel", "Unknown",
                          "FullScreenAllMonitors", "DotWhenNoCursor", "ServerName\nPassword", " ServerName"}) {
    EXPECT_EQ(ConnectionDocument::exportName(name), nullptr);
    EXPECT_THROW(ConnectionDocument::serialize({{name, "secret"}}), DocumentError);
  }
  // Public verification settings can be saved explicitly; migration filters
  // them separately. They are not authentication secrets or trust decisions.
  EXPECT_NO_THROW(ConnectionDocument::serialize({{"X509CA", "/ca.pem"}, {"SecurityTypes", "X509Vnc"}}));
  EXPECT_NO_THROW(ConnectionDocument::serialize({{"Audio", "on"}, {"SendPrimary", "on"}, {"SetPrimary", "off"}}));
  EXPECT_EQ(ConnectionDocument::exportName("PlayAudio"), nullptr);
}

TEST(ConnectionDocument, ExportPreflightsEscapedLengthAndCanAlwaysBeRead) {
  const std::string largest(242, 'x'); // ServerName= + 242 bytes + LF = 254.
  EXPECT_EQ(ConnectionDocument::parse(ConnectionDocument::serialize({{"ServerName", largest}})).entries()[0].value(), largest);
  EXPECT_THROW(ConnectionDocument::serialize({{"ServerName", largest + "x"}}), DocumentError);
  EXPECT_NO_THROW(ConnectionDocument::serialize({{"ServerName", std::string(121, '\\')}}));
  EXPECT_THROW(ConnectionDocument::serialize({{"ServerName", std::string(122, '\\')}}), DocumentError);
  EXPECT_THROW(ConnectionDocument::serialize(std::vector<DocumentAssignment>(ConnectionDocument::maximumEntries + 1, {"Shared", "on"})), DocumentError);
}

TEST(ConnectionDocument, ConcurrentOwnedDocumentsAreIndependent) {
  std::atomic<bool> failed{false};
  std::vector<std::thread> threads;
  for (int n = 0; n < 8; ++n) threads.emplace_back([n, &failed] {
    const auto address = "host-" + std::to_string(n) + "\\path";
    for (int i = 0; i < 1000; ++i) {
      auto input = ConnectionDocument::serialize({{"ServerName", address}});
      auto parsed = ConnectionDocument::parse(input);
      input.assign("changed");
      if (parsed.entries()[0].value() != address) failed = true;
    }
  });
  for (auto& thread : threads) thread.join();
  EXPECT_FALSE(failed);
}

TEST(DocumentOptions, SharedCanonicalValuesAndFileOnlyNames) {
  const std::vector<DocumentAssignment> cases = {
    {"ViewOnly","YES"},{"AlwaysCursor",""},{"Shared","false"},{"FullScreenMode","aLL"},
    {"CursorType","sYsTeM"},{"DesktopPixelUnits","dEVice"},{"ScalingQuality","AREA"},
    {"ScalingFactor","125.00%"},{"QualityLevel","0x8"},{"ShortcutModifiers"," Cmd,Ctrl, Option,Win,ctrl "},
    {"FullScreenSelectedMonitors","0x1,02,+3"},{"FullScreenAllMonitors","on"},{"DotWhenNoCursor","off"}
  };
  const std::vector<std::string> expected = {"on","on","off","All","System","Device","Area","125","8","Ctrl,Alt,Super","1,2,3","on","off"};
  const auto globals = core::Configuration::global()->size();
  for (size_t i = 0; i < cases.size(); ++i) {
    DocumentAssignment result;
    ASSERT_TRUE(documentOption({cases[i].name,cases[i].value,9},result));
    EXPECT_EQ(result.name,cases[i].name); EXPECT_EQ(result.value,expected[i]);
  }
  EXPECT_EQ(core::Configuration::global()->size(),globals);
  for (auto* name : {"FullColour","LowColourLevel","RemoteResize","DesktopSize","PasswordFile","Future"}) {
    DocumentAssignment result{"unchanged","unchanged"};
    EXPECT_FALSE(documentOption({name,"\\q",2},result));
    EXPECT_EQ(result.name,"unchanged"); EXPECT_EQ(result.value,"unchanged");
  }
}

TEST(DocumentOptions, ErrorsKeepLineAndOutputWithoutGlobalMutation) {
  for (const auto& field : std::vector<DocumentAssignment>{
      {"Shared"," on"},{"FullScreenMode","all "},{"CursorType","hidden"},
      {"ShortcutModifiers","Ctrl,"},{"ShortcutModifiers","Ctrl,,Alt"},
      {"FullScreenSelectedMonitors","0"},{"FullScreenSelectedMonitors","08"},
      {"FullScreenSelectedMonitors","2147483648"},{"FullScreenSelectedMonitors","-1"},
      {"ScalingFactor","0%"},{"QualityLevel","10"},{"SecurityTypes","unknown-private-token"}}) {
    DocumentAssignment result{"unchanged","unchanged"};
    try { documentOption({field.name,field.value,17},result); FAIL(); }
    catch (const DocumentError& error) {
      EXPECT_EQ(error.code,DocumentErrorCode::InvalidValue); EXPECT_EQ(error.line,17u);
      EXPECT_EQ(std::string(error.what()).find("private"),std::string::npos);
    }
    EXPECT_EQ(result.name,"unchanged"); EXPECT_EQ(result.value,"unchanged");
  }
  for (auto* name : {"ShortcutModifiers","FullScreenSelectedMonitors"}) {
    DocumentAssignment result; EXPECT_TRUE(documentOption({name,"  \t ",2},result)); EXPECT_TRUE(result.value.empty());
  }
}
