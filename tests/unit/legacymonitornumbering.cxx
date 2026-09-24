/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// LegacyMonitorNumbering (plans/native-ui-winui TODO W2.6): the shared corpus
// (tests/conformance/legacy-monitor-numbering.json) through
// tidyvnc_legacy_monitor_order.
#include <tidyvnc.h>

#include <map>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "conformance-json.h"

TEST(LegacyMonitorNumbering, SharedConformanceCorpus)
{
  const auto corpus = conformance::load(std::string(TIDYVNC_CONFORMANCE_DIR) + "/legacy-monitor-numbering.json");
  ASSERT_EQ("LegacyMonitorNumbering", corpus["module"].string());
  const std::map<std::string, uint32_t> reasons = {
    {"empty", TIDYVNC_MONITORS_EMPTY}, {"tooMany", TIDYVNC_MONITORS_TOO_MANY},
    {"duplicateId", TIDYVNC_MONITORS_DUPLICATE_ID}, {"ambiguousOrigin", TIDYVNC_MONITORS_AMBIGUOUS_ORIGIN}};
  for (const auto& entry : corpus["cases"].items) {
    SCOPED_TRACE(entry["name"].string());
    std::vector<tidyvnc_display_monitor> monitors;
    for (const auto& item : entry["monitors"].items) {
      tidyvnc_display_monitor monitor{};
      monitor.id = item["id"].u32();
      monitor.x = static_cast<int32_t>(item["x"].number);
      monitor.y = static_cast<int32_t>(item["y"].number);
      monitor.width = monitor.height = monitor.backing_width = monitor.backing_height = 100;
      monitors.push_back(monitor);
    }
    std::vector<uint32_t> ids(monitors.size() + 1, 0xdeadbeef);
    tidyvnc_error error{};
    error.size = sizeof(error);
    error.version = TIDYVNC_ABI_VERSION;
    const auto status = tidyvnc_legacy_monitor_order(monitors.data(), static_cast<uint32_t>(monitors.size()), ids.data(), &error);
    if (entry.has("error")) {
      EXPECT_NE(TIDYVNC_OK, status);
      EXPECT_EQ(TIDYVNC_DOMAIN_MONITORS, error.domain);
      EXPECT_EQ(reasons.at(entry["error"].string()), error.detail);
      for (auto id : ids) EXPECT_EQ(0xdeadbeefu, id);
      continue;
    }
    ASSERT_EQ(TIDYVNC_OK, status) << error.message;
    std::vector<uint32_t> expected;
    for (const auto& id : entry["expect"].items) expected.push_back(id.u32());
    EXPECT_EQ(expected, std::vector<uint32_t>(ids.begin(), ids.begin() + static_cast<long>(monitors.size())));
    EXPECT_EQ(0xdeadbeefu, ids.back()); // Nothing past count.
  }
}
