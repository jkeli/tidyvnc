/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <tidyvnc.h>
#include <array>
#include <atomic>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

extern "C" void abi_test_fail_after(unsigned);
namespace {
template<class T> T init() { T v{}; v.size = sizeof(T); v.version = TIDYVNC_ABI_VERSION; return v; }
tidyvnc_bytes bytes(const std::string& s) { return {reinterpret_cast<const uint8_t*>(s.data()),s.size()}; }
std::string fixture() { return "TidyVNC Configuration file Version 1.0\nServerName=host\\\\path\nFuture=\\q\nServerName=last\n"; }
struct Handle { uint64_t id = 0; ~Handle() { if (id) tidyvnc_release(id,nullptr); } };
}
TEST(DocumentABI, OwnedCopiesDeferredDecodeAndReferenceLifetime) {
  auto input = fixture(); Handle owner;
  ASSERT_EQ(tidyvnc_document_parse(bytes(input),&owner.id,nullptr),TIDYVNC_OK);
  input.assign("destroyed input");
  auto info = init<tidyvnc_document_info>();
  ASSERT_EQ(tidyvnc_document_get(owner.id,&info,nullptr),TIDYVNC_OK);
  EXPECT_EQ(info.count,3u); EXPECT_EQ(info.legacy_header,0u);
  auto entry = init<tidyvnc_document_entry>();
  ASSERT_EQ(tidyvnc_document_entry_at(owner.id,0,1,&entry,nullptr),TIDYVNC_OK);
  EXPECT_STREQ(entry.name,"ServerName"); EXPECT_STREQ(entry.value,"host\\path"); EXPECT_EQ(entry.line,2u);
  ASSERT_EQ(tidyvnc_document_entry_at(owner.id,1,0,&entry,nullptr),TIDYVNC_OK);
  EXPECT_STREQ(entry.value,"\\q");
  auto before = entry; auto error = init<tidyvnc_error>();
  EXPECT_EQ(tidyvnc_document_entry_at(owner.id,1,1,&entry,&error),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(error.domain,TIDYVNC_DOMAIN_DOCUMENT);
  EXPECT_EQ(error.detail,(3u << 8) | TIDYVNC_DOCUMENT_INVALID_ESCAPE);
  EXPECT_EQ(std::memcmp(&entry,&before,sizeof(entry)),0);
  EXPECT_EQ(tidyvnc_document_entry_at(owner.id,99,0,&entry,nullptr),TIDYVNC_NO_CHANGE);
  EXPECT_EQ(tidyvnc_document_entry_at(owner.id,0,2,&entry,nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(std::memcmp(&entry,&before,sizeof(entry)),0);
  ASSERT_EQ(tidyvnc_retain(owner.id,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_release(owner.id,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_document_entry_at(owner.id,2,1,&entry,nullptr),TIDYVNC_OK);
  EXPECT_STREQ(entry.value,"last");
  const auto old = owner.id; ASSERT_EQ(tidyvnc_release(old,nullptr),TIDYVNC_OK); owner.id = 0;
  EXPECT_STREQ(entry.value,"last");
  EXPECT_EQ(tidyvnc_document_get(old,&info,nullptr),TIDYVNC_INVALID_HANDLE);
}

TEST(DocumentABI, InvalidInputsHaveTypedRedactedErrorsAndNeverWriteOutputs) {
  uint64_t handle = 777; auto error = init<tidyvnc_error>();
  EXPECT_EQ(tidyvnc_document_parse({nullptr,1},&handle,&error),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(handle,777u);
  EXPECT_EQ(tidyvnc_document_parse({nullptr,UINT64_MAX},&handle,&error),TIDYVNC_RESOURCE_LIMIT);
  EXPECT_EQ(error.domain,TIDYVNC_DOMAIN_DOCUMENT); EXPECT_EQ(error.detail,TIDYVNC_DOCUMENT_TOO_LARGE);
  EXPECT_EQ(tidyvnc_document_parse(bytes("secret-endpoint"),&handle,&error),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(error.detail,(1u << 8) | TIDYVNC_DOCUMENT_INVALID_HEADER);
  EXPECT_EQ(std::strstr(error.message,"secret"),nullptr); EXPECT_EQ(handle,777u);
  EXPECT_EQ(tidyvnc_document_parse(bytes(fixture()),nullptr,&error),TIDYVNC_INVALID_ARGUMENT);
  auto input = fixture(); input.push_back('\0');
  EXPECT_EQ(tidyvnc_document_parse(bytes(input),&handle,&error),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(error.detail & 255,TIDYVNC_DOCUMENT_NULL_BYTE);
  error.version = 0;
  EXPECT_EQ(tidyvnc_document_parse(bytes(fixture()),&handle,&error),TIDYVNC_ABI_MISMATCH);
  EXPECT_EQ(handle,777u);
  Handle endpoint;
  ASSERT_EQ(tidyvnc_endpoint_create(bytes("localhost"),{nullptr,0},1,&endpoint.id,nullptr),TIDYVNC_OK);
  auto info = init<tidyvnc_document_info>(); auto before = info;
  EXPECT_EQ(tidyvnc_document_get(endpoint.id,&info,nullptr),TIDYVNC_WRONG_HANDLE_TYPE);
  EXPECT_EQ(std::memcmp(&info,&before,sizeof(info)),0);
  info.version = 0;
  EXPECT_EQ(tidyvnc_document_get(endpoint.id,&info,nullptr),TIDYVNC_ABI_MISMATCH);
}

TEST(DocumentABI, SerializationQueryCapacityCanariesAndSafeCatalog) {
  const std::string name = "ServerName", address = "héllo\\socket";
  tidyvnc_document_assignment field{bytes(name),bytes(address)};
  uint64_t size = 999; auto error = init<tidyvnc_error>();
  ASSERT_EQ(tidyvnc_document_serialize(&field,1,{nullptr,0},&size,&error),TIDYVNC_OK);
  std::vector<uint8_t> output(size+16,0xaa); const auto before = output;
  const auto needed = size; size = 999;
  EXPECT_EQ(tidyvnc_document_serialize(&field,1,{output.data(),needed-1},&size,&error),TIDYVNC_RESOURCE_LIMIT);
  EXPECT_EQ(size,999u); EXPECT_EQ(output,before);
  ASSERT_EQ(tidyvnc_document_serialize(&field,1,{output.data(),needed},&size,&error),TIDYVNC_OK);
  EXPECT_EQ(size,needed);
  for (size_t i = size; i < output.size(); ++i) EXPECT_EQ(output[i],0xaa);
  Handle document;
  ASSERT_EQ(tidyvnc_document_parse({output.data(),size},&document.id,nullptr),TIDYVNC_OK);
  auto entry = init<tidyvnc_document_entry>();
  ASSERT_EQ(tidyvnc_document_entry_at(document.id,0,1,&entry,nullptr),TIDYVNC_OK);
  EXPECT_EQ(std::string(entry.value),address);
  auto after = output; size = 999;
  for (const std::string key : {"PasswordFile","Password","UserName","Via","Future","DotWhenNoCursor"}) {
    field.name = bytes(key);
    EXPECT_EQ(tidyvnc_document_serialize(&field,1,{output.data(),output.size()},&size,&error),TIDYVNC_INVALID_ARGUMENT);
    EXPECT_EQ(error.detail,TIDYVNC_DOCUMENT_INVALID_EXPORT_NAME);
    EXPECT_EQ(output,after); EXPECT_EQ(size,999u);
  }
  field.name = bytes(name);
  EXPECT_EQ(tidyvnc_document_serialize(&field,4097,{nullptr,0},&size,&error),TIDYVNC_RESOURCE_LIMIT);
  EXPECT_EQ(error.detail,TIDYVNC_DOCUMENT_TOO_MANY_ENTRIES);
  EXPECT_EQ(tidyvnc_document_serialize(nullptr,1,{nullptr,0},&size,nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(tidyvnc_document_serialize(&field,1,{nullptr,1},&size,nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(tidyvnc_document_serialize(&field,1,{nullptr,0},nullptr,nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(size,999u);
}

TEST(DocumentABI, AllocationFailuresAreContainedAndTransactional) {
#if defined(_MSC_VER) && defined(_ITERATOR_DEBUG_LEVEL) && _ITERATOR_DEBUG_LEVEL > 0
  // MSVC debug iterators allocate container proxies inside noexcept moves, so
  // injected allocation failures terminate there; Release builds run this.
  GTEST_SKIP() << "Allocation injection needs _ITERATOR_DEBUG_LEVEL=0 (MSVC Release)";
#endif
  const auto input = fixture(); unsigned failures = 0, successes = 0;
  const std::string name = "ServerName", value(120,'x');
  tidyvnc_document_assignment field{bytes(name),bytes(value)};
  for (unsigned n = 1; n <= 48; ++n) {
    uint64_t handle = 777;
    abi_test_fail_after(n);
    const auto status = tidyvnc_document_parse(bytes(input),&handle,nullptr);
    abi_test_fail_after(0);
    if (status == TIDYVNC_OK) { ++successes; tidyvnc_release(handle,nullptr); }
    else { ++failures; EXPECT_EQ(status,TIDYVNC_OUT_OF_MEMORY); EXPECT_EQ(handle,777u); }
    std::array<uint8_t,512> output; output.fill(0xaa); const auto before = output; uint64_t size = 999;
    abi_test_fail_after(n);
    const auto written = tidyvnc_document_serialize(&field,1,{output.data(),output.size()},&size,nullptr);
    abi_test_fail_after(0);
    if (written != TIDYVNC_OK) {
      EXPECT_EQ(written,TIDYVNC_OUT_OF_MEMORY); EXPECT_EQ(output,before); EXPECT_EQ(size,999u);
    }
  }
  EXPECT_GT(failures,5u); EXPECT_GT(successes,0u);
}

TEST(DocumentABI, ConcurrentReadersUseCopiedStorageAndRetainedHandles) {
  Handle document; ASSERT_EQ(tidyvnc_document_parse(bytes(fixture()),&document.id,nullptr),TIDYVNC_OK);
  std::atomic<unsigned> failures{0}; std::vector<std::thread> readers;
  for (int n = 0; n < 8; ++n) readers.emplace_back([&] {
    for (int i = 0; i < 1000; ++i) {
      auto entry = init<tidyvnc_document_entry>();
      if (tidyvnc_retain(document.id,nullptr) != TIDYVNC_OK) ++failures;
      if (tidyvnc_document_entry_at(document.id,0,1,&entry,nullptr) != TIDYVNC_OK || std::strcmp(entry.value,"host\\path")) ++failures;
      if (tidyvnc_release(document.id,nullptr) != TIDYVNC_OK) ++failures;
    }
  });
  for (auto& reader : readers) reader.join();
  EXPECT_EQ(failures,0u);
}

TEST(DocumentABI, OpaqueBytesAndVersionedOutputTails) {
  auto source = std::string("TidyVNC Configuration file Version 1.0\nServerName=");
  source += char(0xff);
  Handle document; ASSERT_EQ(tidyvnc_document_parse(bytes(source),&document.id,nullptr),TIDYVNC_OK);
  struct Extended { tidyvnc_document_info info; uint64_t tail; } extended;
  extended.info = init<tidyvnc_document_info>(); extended.info.size = sizeof(extended); extended.tail = 0xabcdef;
  ASSERT_EQ(tidyvnc_document_get(document.id,&extended.info,nullptr),TIDYVNC_OK);
  EXPECT_EQ(extended.tail,0xabcdefu); EXPECT_EQ(extended.info.count,1u);
  auto entry = init<tidyvnc_document_entry>();
  ASSERT_EQ(tidyvnc_document_entry_at(document.id,0,1,&entry,nullptr),TIDYVNC_OK);
  EXPECT_EQ(static_cast<unsigned char>(entry.value[0]),255u); EXPECT_EQ(entry.value[1],0);
  entry.size = sizeof(entry) - 1; const auto before = entry;
  EXPECT_EQ(tidyvnc_document_entry_at(document.id,0,1,&entry,nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(std::memcmp(&before,&entry,sizeof(entry)),0);
}

TEST(DocumentABI, SemanticOptionValidationIsCopiedRedactedAndDeferred) {
  const std::string input = "TidyVNC Configuration file Version 1.0\nviewonly=YES\nFuture=\\q\nShared=private-bad\nShortcutModifiers=Cmd,Option,Ctrl\n";
  Handle document; ASSERT_EQ(tidyvnc_document_parse(bytes(input),&document.id,nullptr),TIDYVNC_OK);
  auto entry = init<tidyvnc_document_entry>(); auto error = init<tidyvnc_error>();
  ASSERT_EQ(tidyvnc_document_option_at(document.id,0,&entry,&error),TIDYVNC_OK);
  EXPECT_STREQ(entry.name,"ViewOnly"); EXPECT_STREQ(entry.value,"on"); EXPECT_EQ(entry.line,2u);
  auto before = entry;
  EXPECT_EQ(tidyvnc_document_option_at(document.id,1,&entry,&error),TIDYVNC_NO_CHANGE);
  EXPECT_EQ(tidyvnc_document_option_at(document.id,99,&entry,&error),TIDYVNC_NO_CHANGE);
  EXPECT_EQ(std::memcmp(&entry,&before,sizeof(entry)),0);
  EXPECT_EQ(tidyvnc_document_option_at(document.id,2,&entry,&error),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(error.domain,TIDYVNC_DOMAIN_DOCUMENT); EXPECT_EQ(error.detail,(4u << 8) | TIDYVNC_DOCUMENT_INVALID_VALUE);
  EXPECT_EQ(std::strstr(error.message,"private"),nullptr); EXPECT_EQ(std::memcmp(&entry,&before,sizeof(entry)),0);
  ASSERT_EQ(tidyvnc_document_option_at(document.id,3,&entry,&error),TIDYVNC_OK);
  EXPECT_STREQ(entry.value,"Ctrl,Alt,Super");
  const std::string key = "QualityLevel", level = "7";
  tidyvnc_encoding_assignment field{bytes(key),bytes(level)}; Handle encoding;
  ASSERT_EQ(tidyvnc_encoding_create(0,&field,1,TIDYVNC_SOURCE_DOCUMENT,&encoding.id,&error),TIDYVNC_OK);
  auto value = init<tidyvnc_encoding_value>();
  ASSERT_EQ(tidyvnc_encoding_get(encoding.id,TIDYVNC_ENCODING_QUALITY,&value,&error),TIDYVNC_OK);
  EXPECT_EQ(value.source,TIDYVNC_SOURCE_DOCUMENT);
  before = entry;
  EXPECT_EQ(tidyvnc_document_option_at(encoding.id,0,&entry,&error),TIDYVNC_WRONG_HANDLE_TYPE);
  EXPECT_EQ(std::memcmp(&entry,&before,sizeof(entry)),0);
}
