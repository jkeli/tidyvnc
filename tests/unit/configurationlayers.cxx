/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// ConfigurationLayers (plans/native-ui-winui TODO W2.2): the shared corpus
// (tests/conformance/configuration-layers.json) through tidyvnc_config_resolve.
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

const std::map<std::string, uint32_t> sources = {
  {"compiled", TIDYVNC_SOURCE_COMPILED}, {"appDefaults", TIDYVNC_SOURCE_APP_DEFAULTS}, {"profile", TIDYVNC_SOURCE_PROFILE},
  {"session", TIDYVNC_SOURCE_SESSION}, {"commandLine", TIDYVNC_SOURCE_COMMAND_LINE}, {"document", TIDYVNC_SOURCE_DOCUMENT}};
const std::map<std::string, uint32_t> reasons = {
  {"unknownParameter", TIDYVNC_CONFIG_UNKNOWN_PARAMETER}, {"invalidValue", TIDYVNC_CONFIG_INVALID_VALUE},
  {"invalidSource", TIDYVNC_CONFIG_INVALID_SOURCE}, {"unavailable", TIDYVNC_CONFIG_UNAVAILABLE}, {"tooMany", TIDYVNC_CONFIG_TOO_MANY}};
const std::map<std::string, uint32_t> notes = {
  {"dotWhenNoCursor", TIDYVNC_CONFIG_NOTE_DOT_WHEN_NO_CURSOR}, {"fullScreenAllMonitors", TIDYVNC_CONFIG_NOTE_FULL_SCREEN_ALL_MONITORS}};
}

TEST(ConfigurationLayers, SharedConformanceCorpus)
{
  const auto corpus = conformance::load(std::string(TIDYVNC_CONFORMANCE_DIR) + "/configuration-layers.json");
  ASSERT_EQ("ConfigurationLayers", corpus["module"].string());
  for (const auto& entry : corpus["cases"].items) {
    SCOPED_TRACE(entry["name"].string());
    std::vector<std::string> texts;
    for (const auto& item : entry["assignments"].items) { texts.push_back(item["name"].string()); texts.push_back(item["value"].string()); }
    std::vector<tidyvnc_config_assignment> input;
    size_t index = 0;
    for (const auto& item : entry["assignments"].items) {
      input.push_back({bytes(texts[index]), bytes(texts[index + 1]), sources.at(item["source"].string()), item["position"].u32()});
      index += 2;
    }
    tidyvnc_handle handle = 0;
    auto error = init<tidyvnc_error>();
    const auto status = tidyvnc_config_resolve(input.data(), static_cast<uint32_t>(input.size()), &handle, &error);
    if (entry.has("error")) {
      EXPECT_NE(TIDYVNC_OK, status);
      EXPECT_EQ(TIDYVNC_DOMAIN_CONFIG, error.domain);
      EXPECT_EQ(reasons.at(entry["error"]["reason"].string()), error.detail & 0xff);
      EXPECT_EQ(entry["error"]["index"].u32(), error.detail >> 8);
      continue;
    }
    ASSERT_EQ(TIDYVNC_OK, status) << error.message;
    auto info = init<tidyvnc_config_info>();
    ASSERT_EQ(TIDYVNC_OK, tidyvnc_config_get(handle, &info, nullptr));
    const auto& values = entry["values"].items;
    const auto& expectedNotes = entry["notes"].items;
    ASSERT_EQ(values.size(), info.value_count);
    ASSERT_EQ(expectedNotes.size(), info.note_count);
    for (uint32_t i = 0; i < info.value_count; i++) {
      auto value = init<tidyvnc_config_value>();
      ASSERT_EQ(TIDYVNC_OK, tidyvnc_config_value_at(handle, i, &value, nullptr));
      EXPECT_EQ(values[i]["name"].string(), std::string(value.name));
      EXPECT_EQ(values[i]["value"].string(), copy(value.value));
      EXPECT_EQ(sources.at(values[i]["source"].string()), value.source);
      EXPECT_EQ(values[i]["position"].u32(), value.position);
      EXPECT_EQ(values[i].flag("dormant", false), value.dormant != 0) << value.name;
    }
    for (uint32_t i = 0; i < info.note_count; i++) {
      auto note = init<tidyvnc_config_note>();
      ASSERT_EQ(TIDYVNC_OK, tidyvnc_config_note_at(handle, i, &note, nullptr));
      EXPECT_EQ(notes.at(expectedNotes[i]["kind"].string()), note.kind);
      EXPECT_EQ(expectedNotes[i]["parameter"].string(), std::string(note.parameter));
      EXPECT_EQ(sources.at(expectedNotes[i]["source"].string()), note.source);
      EXPECT_EQ(expectedNotes[i]["position"].u32(), note.position);
    }
    auto past = init<tidyvnc_config_value>();
    EXPECT_EQ(TIDYVNC_NO_CHANGE, tidyvnc_config_value_at(handle, info.value_count, &past, nullptr));
    EXPECT_EQ(TIDYVNC_OK, tidyvnc_release(handle, nullptr));
  }
}

// The command line's own validation and this resolver agree for every
// available parameter: canonicalizing through one never disagrees with the other.
TEST(ConfigurationLayers, AgreesWithInvocationValidation)
{
  const std::vector<std::pair<std::string, std::string>> samples = {
    {"Shared", "yes"}, {"QualityLevel", "4"}, {"PreferredEncoding", "hextile"}, {"ScalingFactor", "150%"},
    {"MaxCutText", "0x100"}, {"FullScreenSelectedMonitors", "3,1"}, {"ShortcutModifiers", "alt,ctrl"}};
  for (const auto& sample : samples) {
    SCOPED_TRACE(sample.first);
    const auto argument = "-" + sample.first + "=" + sample.second;
    const tidyvnc_bytes arguments[] = {bytes(argument)};
    tidyvnc_handle parsed = 0, validated = 0, resolved = 0;
    ASSERT_EQ(TIDYVNC_OK, tidyvnc_invocation_parse(arguments, 1, &parsed, nullptr));
    ASSERT_EQ(TIDYVNC_OK, tidyvnc_invocation_validate(parsed, &validated, nullptr));
    auto assignment = init<tidyvnc_invocation_assignment>();
    ASSERT_EQ(TIDYVNC_OK, tidyvnc_invocation_assignment_at(validated, 0, &assignment, nullptr));
    const tidyvnc_config_assignment input[] = {{bytes(sample.first), bytes(sample.second), TIDYVNC_SOURCE_COMMAND_LINE, 1}};
    ASSERT_EQ(TIDYVNC_OK, tidyvnc_config_resolve(input, 1, &resolved, nullptr));
    auto value = init<tidyvnc_config_value>();
    ASSERT_EQ(TIDYVNC_OK, tidyvnc_config_value_at(resolved, 0, &value, nullptr));
    EXPECT_EQ(copy(assignment.value), copy(value.value));
    for (auto handle : {parsed, validated, resolved}) EXPECT_EQ(TIDYVNC_OK, tidyvnc_release(handle, nullptr));
  }
}
