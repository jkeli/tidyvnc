/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// ExportLoss (plans/native-ui-winui TODO W2.7): the shared corpus
// (tests/conformance/export-loss.json) through tidyvnc_export_losses, and the
// catalog's parameters against the invocation schema.
#include <tidyvnc.h>

#include <map>
#include <set>
#include <sstream>
#include <string>

#include <gtest/gtest.h>

#include "conformance-json.h"

namespace {
template <class T> T init()
{
  T value{};
  value.size = sizeof(T);
  value.version = TIDYVNC_ABI_VERSION;
  return value;
}

std::map<std::string, uint32_t> catalog()
{
  std::map<std::string, uint32_t> names;
  for (uint32_t i = 0;; i++) {
    auto info = init<tidyvnc_export_loss_info>();
    const auto status = tidyvnc_export_loss_at(i, &info, nullptr);
    if (status == TIDYVNC_NO_CHANGE) return names;
    EXPECT_EQ(TIDYVNC_OK, status);
    names[info.name] = info.loss;
  }
}
}

TEST(ExportLoss, SharedConformanceCorpus)
{
  const auto corpus = conformance::load(std::string(TIDYVNC_CONFORMANCE_DIR) + "/export-loss.json");
  ASSERT_EQ("ExportLoss", corpus["module"].string());
  const auto names = catalog();
  ASSERT_EQ(corpus["catalog"].items.size(), names.size());
  for (uint32_t i = 0; i < corpus["catalog"].items.size(); i++) {
    auto info = init<tidyvnc_export_loss_info>();
    ASSERT_EQ(TIDYVNC_OK, tidyvnc_export_loss_at(i, &info, nullptr));
    EXPECT_EQ(corpus["catalog"].items[i]["name"].string(), info.name);
    EXPECT_EQ(corpus["catalog"].items[i]["parameters"].string(), info.parameters);
  }
  for (const auto& entry : corpus["cases"].items) {
    SCOPED_TRACE(entry["name"].string());
    auto request = init<tidyvnc_export_request>();
    request.selected_displays = entry.flag("selectedDisplays", false);
    request.ignored_input = entry.flag("ignoredInput", false);
    request.ssh_gateway = entry.flag("sshGateway", false);
    const auto priority = entry.string("tlsPriority", "");
    request.tls_priority = {reinterpret_cast<const uint8_t*>(priority.data()), priority.size()};
    uint32_t losses = 0xffffffff;
    auto error = init<tidyvnc_error>();
    const auto status = tidyvnc_export_losses(&request, &losses, &error);
    if (entry.has("error")) {
      EXPECT_EQ(TIDYVNC_INVALID_ARGUMENT, status);
      EXPECT_EQ(TIDYVNC_DOMAIN_EXPORT, error.domain);
      EXPECT_EQ(static_cast<uint32_t>(TIDYVNC_EXPORT_SECURITY_POLICY), error.detail);
      EXPECT_EQ(0xffffffffu, losses);
      continue;
    }
    ASSERT_EQ(TIDYVNC_OK, status);
    uint32_t expected = 0;
    for (const auto& name : entry["expect"].items) expected |= names.at(name.string());
    EXPECT_EQ(expected, losses);
  }
}

// Every parameter a loss names is a real command-line/file parameter.
TEST(ExportLoss, CatalogParametersExist)
{
  std::set<std::string> schema;
  for (uint32_t i = 0;; i++) {
    auto option = init<tidyvnc_invocation_option>();
    if (tidyvnc_invocation_option_at(i, &option, nullptr) != TIDYVNC_OK) break;
    schema.insert(option.name);
  }
  ASSERT_FALSE(schema.empty());
  for (uint32_t i = 0;; i++) {
    auto info = init<tidyvnc_export_loss_info>();
    if (tidyvnc_export_loss_at(i, &info, nullptr) != TIDYVNC_OK) break;
    std::stringstream list(info.parameters);
    std::string parameter;
    while (std::getline(list, parameter, ','))
      EXPECT_TRUE(schema.count(parameter)) << info.name << ": " << parameter;
  }
}
