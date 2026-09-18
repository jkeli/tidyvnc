// Original TidyVNC work, 2026. SPDX-License-Identifier: GPL-2.0-or-later
#include <gtest/gtest.h>
#include <core/AtomicFile.h>
#include <core/xdgdirs.h>
#include <parameters.h>
#include <LegacyImport.h>
#include <filesystem>
#include <fstream>
#include <map>
#include <cstdlib>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;
class ViewerState : public testing::Test {
protected:
  fs::path root;
  std::map<std::string, std::string> saved;
  std::vector<std::string> missing;
  void SetUp() override {
    char pattern[] = "/tmp/tidyvnc-state-XXXXXX";
    root = mkdtemp(pattern);
    for (const char* name : {"HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME"}) {
      const char* value = getenv(name);
      if (value) saved[name] = value; else missing.push_back(name);
      setenv(name, (root / name).c_str(), 1);
    }
    fs::create_directories(core::gettidyvncconfigdir());
    fs::create_directories(core::gettidyvncstatedir());
    scalingFactor.setParam("100");
  }
  void TearDown() override {
    for (auto& pair : saved) setenv(pair.first.c_str(), pair.second.c_str(), 1);
    for (auto& key : missing) unsetenv(key.c_str());
    fs::remove_all(root);
    scalingFactor.setParam("100");
  }
  fs::path config() { return fs::path(core::gettidyvncconfigdir()) / "default.tidyvnc"; }
  fs::path legacy() {
    auto p = root / "XDG_CONFIG_HOME/tigervnc/default.tigervnc";
    fs::create_directories(p.parent_path()); return p;
  }
  void write(const fs::path& p, const std::string& text) { std::ofstream(p) << text; }
  std::string read(const fs::path& p) {
    std::ifstream f(p); return std::string(std::istreambuf_iterator<char>(f), {});
  }
};
TEST_F(ViewerState, ExactNewAndLegacyHeaders) {
  for (auto brand : {"TidyVNC", "TigerVNC"}) {
    write(config(), std::string(brand) + " Configuration file Version 1.0\r\nServerName=host:2\nScalingFactor=125\n");
    EXPECT_STREQ(loadViewerParameters(nullptr), "host:2");
    EXPECT_EQ(scalingFactor.getValueStr(), "125");
  }
}
TEST_F(ViewerState, RejectUnknownVersionAndMalformedHeader) {
  for (auto suffix : {"1.1", "1.0garbage", "1.0\rgarbage"}) {
    write(config(), std::string("TidyVNC Configuration file Version ") + suffix + "\n");
    EXPECT_THROW(loadViewerParameters(nullptr), std::exception);
  }
  write(config(), "");
  EXPECT_THROW(loadViewerParameters(nullptr), std::exception);
}
TEST_F(ViewerState, RoundTripAndPrivateAtomicWrites) {
  scalingFactor.setParam("137.5");
  saveViewerParameters(nullptr, "host\\name\nvalue");
  EXPECT_EQ(read(config()).find("TidyVNC Configuration file Version 1.0\n"), 0u);
  scalingFactor.setParam("100");
  EXPECT_STREQ(loadViewerParameters(nullptr), "host\\name\nvalue");
  EXPECT_EQ(scalingFactor.getValueStr(), "137.5");
  struct stat st; ASSERT_EQ(stat(config().c_str(), &st), 0); EXPECT_EQ(st.st_mode & 0777, 0600);
  chmod(config().c_str(), 0640);
  saveViewerParameters(nullptr, "other");
  ASSERT_EQ(stat(config().c_str(), &st), 0); EXPECT_EQ(st.st_mode & 0777, 0640);
}
TEST_F(ViewerState, ParseFailureRestoresParametersAndDoesNotFallback) {
  write(legacy(), "TigerVNC Configuration file Version 1.0\nScalingFactor=200\n");
  write(config(), "TidyVNC Configuration file Version 1.0\nScalingFactor=150\nbroken\n");
  EXPECT_THROW(loadViewerParameters(nullptr), std::exception);
  EXPECT_EQ(scalingFactor.getValueStr(), "100");
  EXPECT_TRUE(legacyViewerFile(false).empty());
}
TEST_F(ViewerState, ImportIsSelectedIdempotentAndPreservesSource) {
  auto old = legacy();
  std::string text = "TigerVNC Configuration file Version 1.0\nScalingFactor=200\nServerName=private-host\nSecurityTypes=None\nX509CA=/private/ca.pem\n";
  write(old, text);
  EXPECT_EQ(legacyViewerFile(false), old.string());
  EXPECT_EQ(loadViewerParameters(nullptr), nullptr);
  importLegacyPreferences(old.string());
  EXPECT_EQ(read(old), text);
  EXPECT_EQ(scalingFactor.getValueStr(), "100");
  EXPECT_EQ(read(config()).find("SecurityTypes"), std::string::npos);
  EXPECT_EQ(read(config()).find("X509CA"), std::string::npos);
  EXPECT_EQ(read(config()).find("ServerName"), std::string::npos);
  auto imported = read(config());
  write(old, "invalid");
  importLegacyPreferences(old.string());
  EXPECT_EQ(read(config()), imported);
  loadViewerParameters(nullptr);
  EXPECT_EQ(scalingFactor.getValueStr(), "200");
}
TEST_F(ViewerState, MalformedImportCreatesNoState) {
  write(legacy(), "TigerVNC Configuration file Version 1.0\nScalingFactor=200\nbroken\n");
  EXPECT_THROW(importLegacyPreferences(legacy().string()), std::exception);
  EXPECT_FALSE(fs::exists(config()));
  EXPECT_EQ(scalingFactor.getValueStr(), "100");
}
TEST_F(ViewerState, DotVncImportDoesNotRedirectWrites) {
  auto old = root / "HOME/.vnc/default.tigervnc";
  fs::create_directories(old.parent_path()); write(old, "legacy");
  EXPECT_EQ(legacyViewerFile(false), old.string());
  EXPECT_NE(std::string(core::gettidyvncconfigdir()).find("/tidyvnc"), std::string::npos);
  EXPECT_NE(std::string(core::gettidyvncstatedir()).find("/tidyvnc"), std::string::npos);
}
TEST_F(ViewerState, ImportHistoryDeduplicatesAndNeverOverwrites) {
  auto old = root / "XDG_STATE_HOME/tigervnc/tigervnc.history";
  fs::create_directories(old.parent_path()); write(old, "one\none\ntwo\n");
  EXPECT_EQ(legacyViewerFile(true), old.string());
  importLegacyHistory(old.string());
  auto destination = fs::path(core::gettidyvncstatedir()) / "tidyvnc.history";
  EXPECT_EQ(read(destination), "one\ntwo\n");
  write(old, "three\n"); importLegacyHistory(old.string());
  EXPECT_EQ(read(destination), "one\ntwo\n");
  EXPECT_EQ(read(old), "three\n");
}
TEST_F(ViewerState, AtomicFailurePreservesDestinationAndCleansTemporary) {
  write(config(), "original");
  { core::AtomicFile f(config().c_str()); fputs("replacement", f.stream());
    EXPECT_THROW(f.commit(false), std::exception); }
  EXPECT_EQ(read(config()), "original");
  EXPECT_EQ(std::distance(fs::directory_iterator(config().parent_path()), fs::directory_iterator()), 1);
  auto link = config().parent_path() / "link";
  fs::create_symlink(config(), link);
  { core::AtomicFile f(link.c_str()); fputs("replacement", f.stream());
    EXPECT_THROW(f.commit(), std::exception); }
  EXPECT_EQ(read(config()), "original");
}
TEST_F(ViewerState, UnreadableNewStateNeverUsesLegacy) {
  write(legacy(), "TigerVNC Configuration file Version 1.0\nScalingFactor=200\n");
  write(config(), "private"); chmod(config().c_str(), 0000);
  EXPECT_THROW(loadViewerParameters(nullptr), std::exception);
  EXPECT_TRUE(legacyViewerFile(false).empty()); chmod(config().c_str(), 0600);
}

TEST_F(ViewerState, RejectEmbeddedNullAndKeepRestrictiveImportPermissions) {
  std::string invalid = "TidyVNC Configuration file Version 1.0";
  invalid.push_back('\0'); invalid += "hidden\n";
  write(config(), invalid);
  EXPECT_THROW(loadViewerParameters(nullptr), std::exception);
  fs::remove(config());
  auto old = legacy();
  write(old, "TigerVNC Configuration file Version 1.0\nScalingFactor=200\n");
  chmod(old.c_str(), 0400);
  importLegacyPreferences(old.string());
  struct stat st;
  ASSERT_EQ(stat(config().c_str(), &st), 0);
  EXPECT_EQ(st.st_mode & 0777, 0400);
}
