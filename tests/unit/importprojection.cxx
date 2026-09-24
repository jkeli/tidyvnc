/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// ImportProjection (plans/native-ui-winui TODO W2.4): the shared corpus
// (tests/conformance/import-projection.json) through tidyvnc_import_defaults
// and tidyvnc_import_history, for file bytes and registry-style values.
#include <tidyvnc.h>

#include <map>
#include <string>
#include <vector>

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
tidyvnc_bytes bytes(const std::string& text) { return {reinterpret_cast<const uint8_t*>(text.data()), text.size()}; }
std::string copy(tidyvnc_bytes value) { return value.length ? std::string(reinterpret_cast<const char*>(value.data), value.length) : std::string(); }

const std::map<std::string, uint32_t> reasons = {
  {"unrepresentable", TIDYVNC_IMPORT_UNREPRESENTABLE}, {"tooLarge", TIDYVNC_IMPORT_TOO_LARGE},
  {"invalidText", TIDYVNC_IMPORT_INVALID_TEXT}, {"lineTooLong", TIDYVNC_IMPORT_LINE_TOO_LONG},
  {"tooManyEntries", TIDYVNC_IMPORT_TOO_MANY_ENTRIES}};
const std::map<uint32_t, std::string> kinds = {
  {TIDYVNC_IMPORT_EXCLUDED, "excluded"}, {TIDYVNC_IMPORT_UNKNOWN, "unknown"}, {TIDYVNC_IMPORT_PLATFORM_ONLY, "platformOnly"}};

// Holds the source strings alive for the spans passed to the ABI.
struct Source {
  std::string file;
  bool hasFile = false;
  std::vector<std::string> texts;
  std::vector<tidyvnc_import_value> values;
  std::vector<tidyvnc_bytes> history;
};

Source source(const conformance::Json& entry)
{
  Source out;
  if (entry["source"].string() == "file") {
    out.hasFile = true;
    out.file = entry.has("fileHex") ? conformance::hexBytes(entry["fileHex"].string()) : conformance::text(entry["file"]);
    return out;
  }
  const auto& items = entry["values"].items;
  out.texts.reserve(items.size() * 2);
  for (const auto& item : items) {
    if (item.type == conformance::Json::Type::Array) {
      out.texts.push_back(item.items[0].string());
      out.texts.push_back(item.items[1].string());
    } else {
      out.texts.push_back(item.string());
    }
  }
  if (!items.empty() && items[0].type == conformance::Json::Type::Array)
    for (size_t i = 0; i < out.texts.size(); i += 2) out.values.push_back({bytes(out.texts[i]), bytes(out.texts[i + 1])});
  else
    for (const auto& text : out.texts) out.history.push_back(bytes(text));
  return out;
}
}

TEST(ImportProjection, SharedConformanceCorpus)
{
  const auto corpus = conformance::load(std::string(TIDYVNC_CONFORMANCE_DIR) + "/import-projection.json");
  ASSERT_EQ("ImportProjection", corpus["module"].string());
  size_t cases = 0;
  for (const auto& entry : corpus["cases"].items) {
    SCOPED_TRACE(entry["name"].string());
    ++cases;
    const auto input = source(entry);
    const tidyvnc_bytes file = input.hasFile ? tidyvnc_bytes{reinterpret_cast<const uint8_t*>(input.file.data()), input.file.size()}
                                             : tidyvnc_bytes{nullptr, 0};
    // A file source must pass a non-NULL pointer even when empty.
    const tidyvnc_bytes fileArgument = input.hasFile && input.file.empty() ? tidyvnc_bytes{reinterpret_cast<const uint8_t*>(""), 0} : file;
    tidyvnc_handle handle = 0;
    auto error = init<tidyvnc_error>();
    const bool history = entry.flag("history", false);
    const auto status = history
      ? tidyvnc_import_history(fileArgument, input.history.data(), static_cast<uint32_t>(input.history.size()), &handle, &error)
      : tidyvnc_import_defaults(fileArgument, input.values.data(), static_cast<uint32_t>(input.values.size()), &handle, &error);
    if (entry.has("error") || entry.has("documentError")) {
      EXPECT_NE(TIDYVNC_OK, status);
      EXPECT_EQ(0u, handle);
      if (entry.has("documentError")) {
        EXPECT_EQ(TIDYVNC_DOMAIN_DOCUMENT, error.domain);
        EXPECT_EQ(entry["documentError"]["line"].u32(), error.detail >> 8);
      } else {
        EXPECT_EQ(TIDYVNC_DOMAIN_IMPORT, error.domain);
        EXPECT_EQ(reasons.at(entry["error"]["reason"].string()), error.detail & 0xff);
        EXPECT_EQ(entry["error"]["line"].u32(), error.detail >> 8);
      }
      continue;
    }
    ASSERT_EQ(TIDYVNC_OK, status) << error.message;
    if (history) {
      auto value = init<tidyvnc_import_history_info>();
      ASSERT_EQ(TIDYVNC_OK, tidyvnc_import_history_get(handle, &value, nullptr));
      std::vector<std::string> endpoints, expected;
      for (uint32_t i = 0; i < value.count; i++) endpoints.push_back(copy(value.endpoints[i]));
      for (const auto& item : entry["endpoints"].items) expected.push_back(item.string());
      EXPECT_EQ(expected, endpoints);
      EXPECT_EQ(entry["duplicates"].u32(), value.duplicates);
      EXPECT_EQ(entry["omittedOlder"].u32(), value.omitted_older);
    } else {
      auto info = init<tidyvnc_import_info>();
      ASSERT_EQ(TIDYVNC_OK, tidyvnc_import_defaults_get(handle, &info, nullptr));
      const auto& assignments = entry["assignments"].items;
      const auto& notices = entry["notices"].items;
      ASSERT_EQ(assignments.size(), info.assignment_count);
      ASSERT_EQ(notices.size(), info.notice_count);
      for (uint32_t i = 0; i < info.assignment_count; i++) {
        auto value = init<tidyvnc_import_assignment>();
        ASSERT_EQ(TIDYVNC_OK, tidyvnc_import_assignment_at(handle, i, &value, nullptr));
        EXPECT_EQ(assignments[i]["name"].string(), std::string(value.name));
        EXPECT_EQ(assignments[i]["value"].string(), copy(value.value));
        EXPECT_EQ(assignments[i]["line"].u32(), value.line);
      }
      for (uint32_t i = 0; i < info.notice_count; i++) {
        auto value = init<tidyvnc_import_notice>();
        ASSERT_EQ(TIDYVNC_OK, tidyvnc_import_notice_at(handle, i, &value, nullptr));
        EXPECT_EQ(notices[i]["name"].string(), copy(value.name));
        EXPECT_EQ(notices[i]["line"].u32(), value.line);
        EXPECT_EQ(notices[i]["kind"].string(), kinds.at(value.kind));
      }
      auto past = init<tidyvnc_import_assignment>();
      EXPECT_EQ(TIDYVNC_NO_CHANGE, tidyvnc_import_assignment_at(handle, info.assignment_count, &past, nullptr));
      // Excluded values never reach the projection.
      for (uint32_t i = 0; i < info.assignment_count; i++) {
        auto value = init<tidyvnc_import_assignment>();
        ASSERT_EQ(TIDYVNC_OK, tidyvnc_import_assignment_at(handle, i, &value, nullptr));
        EXPECT_EQ(std::string::npos, copy(value.value).find("private"));
      }
    }
    EXPECT_EQ(TIDYVNC_OK, tidyvnc_release(handle, nullptr));
  }
  EXPECT_GE(cases, 25u);
}

TEST(ImportProjection, RejectsAmbiguousSources)
{
  const std::string file = "TidyVNC Configuration file Version 1.0\nShared=on\n";
  const std::string name = "Shared", value = "on";
  const tidyvnc_import_value values[] = {{bytes(name), bytes(value)}};
  tidyvnc_handle handle = 0;
  EXPECT_EQ(TIDYVNC_INVALID_ARGUMENT, tidyvnc_import_defaults(bytes(file), values, 1, &handle, nullptr));
  EXPECT_EQ(TIDYVNC_INVALID_ARGUMENT, tidyvnc_import_defaults({nullptr, 0}, nullptr, 1, &handle, nullptr));
  EXPECT_EQ(TIDYVNC_INVALID_ARGUMENT, tidyvnc_import_defaults(bytes(file), nullptr, 0, nullptr, nullptr));
  // An empty source is an empty projection.
  ASSERT_EQ(TIDYVNC_OK, tidyvnc_import_history({nullptr, 0}, nullptr, 0, &handle, nullptr));
  auto history = init<tidyvnc_import_history_info>();
  ASSERT_EQ(TIDYVNC_OK, tidyvnc_import_history_get(handle, &history, nullptr));
  EXPECT_EQ(0u, history.count);
  auto info = init<tidyvnc_import_info>();
  EXPECT_EQ(TIDYVNC_WRONG_HANDLE_TYPE, tidyvnc_import_defaults_get(handle, &info, nullptr));
  EXPECT_EQ(TIDYVNC_OK, tidyvnc_release(handle, nullptr));
}
