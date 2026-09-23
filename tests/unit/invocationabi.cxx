/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <tidyvnc.h>
#include <atomic>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
extern "C" void abi_test_fail_after(unsigned);
namespace {
template<class T> T init() { T v{}; v.size = sizeof(T); v.version = TIDYVNC_ABI_VERSION; return v; }
tidyvnc_bytes bytes(const std::string& s) { return {reinterpret_cast<const uint8_t*>(s.data()),s.size()}; }
std::string copied(tidyvnc_bytes s) { return s.length ? std::string(reinterpret_cast<const char*>(s.data),s.length) : ""; }
struct Handle { uint64_t id = 0; ~Handle() { if (id) tidyvnc_release(id,nullptr); } };
}
TEST(InvocationABI, LogLevelOverflowIsRedactedAndDoesNotPublishValidatedOwner) {
  for (const auto* level : {"2147483648","-2147483649"}) {
    const std::string text = std::string("-Log=private-writer:private-target:")+level;
    const std::string replacement = "-Log=*::0", help = "--help";
    const tidyvnc_bytes args[] = {bytes(text),bytes(replacement),bytes(help)};
    Handle syntax; ASSERT_EQ(tidyvnc_invocation_parse(args,3,&syntax.id,nullptr),TIDYVNC_OK);
    uint64_t output = 777; auto error = init<tidyvnc_error>();
    EXPECT_EQ(tidyvnc_invocation_validate(syntax.id,&output,&error),TIDYVNC_INVALID_ARGUMENT);
    EXPECT_EQ(output,777u); EXPECT_EQ(error.domain,TIDYVNC_DOMAIN_INVOCATION);
    EXPECT_EQ(error.detail,(1u<<8)|TIDYVNC_INVOCATION_INVALID_VALUE);
    EXPECT_EQ(std::strstr(error.message,"private"),nullptr);
    auto field = init<tidyvnc_invocation_assignment>();
    ASSERT_EQ(tidyvnc_invocation_assignment_at(syntax.id,0,&field,nullptr),TIDYVNC_OK);
    EXPECT_EQ(copied(field.value),text.substr(5));
  }
}
TEST(InvocationABI, OwnedInputBorrowedValuesAndReferenceLifetime) {
  std::string arg = "-passwd=fixture path\\q", address = "fixture-host";
  tidyvnc_bytes input[] = {bytes(arg),bytes(address)}; Handle owner;
  ASSERT_EQ(tidyvnc_invocation_parse(input,2,&owner.id,nullptr),TIDYVNC_OK);
  arg.assign("destroyed"); address.clear();
  auto info = init<tidyvnc_invocation_info>(); auto entry = init<tidyvnc_invocation_assignment>();
  ASSERT_EQ(tidyvnc_invocation_get(owner.id,&info,nullptr),TIDYVNC_OK);
  EXPECT_EQ(info.action,TIDYVNC_INVOCATION_LAUNCH); EXPECT_EQ(info.count,1u); EXPECT_EQ(info.operand_argument,2u);
  EXPECT_EQ(copied(info.operand),"fixture-host");
  ASSERT_EQ(tidyvnc_invocation_assignment_at(owner.id,0,&entry,nullptr),TIDYVNC_OK);
  EXPECT_STREQ(entry.name,"PasswordFile"); EXPECT_EQ(entry.category,TIDYVNC_INVOCATION_CREDENTIAL_FILE);
  EXPECT_EQ(entry.argument,1u); EXPECT_EQ(entry.value_argument,1u);
  EXPECT_EQ(copied(entry.value),"fixture path\\q");
  auto before = entry;
  EXPECT_EQ(tidyvnc_invocation_assignment_at(owner.id,UINT32_MAX,&entry,nullptr),TIDYVNC_NO_CHANGE);
  EXPECT_EQ(std::memcmp(&before,&entry,sizeof(entry)),0);
  ASSERT_EQ(tidyvnc_retain(owner.id,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_release(owner.id,nullptr),TIDYVNC_OK);
  EXPECT_EQ(copied(entry.value),"fixture path\\q");
  const auto saved = copied(entry.value); const auto old = owner.id;
  ASSERT_EQ(tidyvnc_release(old,nullptr),TIDYVNC_OK); owner.id = 0;
  EXPECT_EQ(saved,"fixture path\\q");
  EXPECT_EQ(tidyvnc_invocation_get(old,&info,nullptr),TIDYVNC_INVALID_HANDLE);
}
TEST(InvocationABI, BoundsRedactionWrongTypesAndOutputsRemainUnchanged) {
  uint64_t owner = 777; auto error = init<tidyvnc_error>();
  std::string privateValue = "--Unknown=private-value"; tidyvnc_bytes arg = bytes(privateValue);
  EXPECT_EQ(tidyvnc_invocation_parse(&arg,1,&owner,&error),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(error.domain,TIDYVNC_DOMAIN_INVOCATION);
  EXPECT_EQ(error.detail,(1u<<8)|TIDYVNC_INVOCATION_UNKNOWN_OPTION);
  EXPECT_EQ(std::strstr(error.message,"private"),nullptr); EXPECT_EQ(owner,777u);
  EXPECT_EQ(tidyvnc_invocation_parse(nullptr,1,&owner,nullptr),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(tidyvnc_invocation_parse(&arg,4097,&owner,&error),TIDYVNC_RESOURCE_LIMIT);
  EXPECT_EQ(error.detail,TIDYVNC_INVOCATION_TOO_MANY_ARGUMENTS);
  arg = {nullptr,UINT64_MAX};
  EXPECT_EQ(tidyvnc_invocation_parse(&arg,1,&owner,&error),TIDYVNC_RESOURCE_LIMIT);
  EXPECT_EQ(error.detail,(1u<<8)|TIDYVNC_INVOCATION_TOO_LARGE);
  arg = {nullptr,1}; EXPECT_EQ(tidyvnc_invocation_parse(&arg,1,&owner,nullptr),TIDYVNC_INVALID_ARGUMENT);
  error.version = 0; EXPECT_EQ(tidyvnc_invocation_parse(nullptr,0,&owner,&error),TIDYVNC_ABI_MISMATCH);
  EXPECT_EQ(owner,777u);
  Handle endpoint; ASSERT_EQ(tidyvnc_endpoint_create(bytes("host"),{nullptr,0},1,&endpoint.id,nullptr),TIDYVNC_OK);
  auto info = init<tidyvnc_invocation_info>(), before = info;
  EXPECT_EQ(tidyvnc_invocation_get(endpoint.id,&info,nullptr),TIDYVNC_WRONG_HANDLE_TYPE);
  EXPECT_EQ(std::memcmp(&before,&info,sizeof(info)),0);
  Handle empty; ASSERT_EQ(tidyvnc_invocation_parse(nullptr,0,&empty.id,nullptr),TIDYVNC_OK);
  info.size = 0; EXPECT_EQ(tidyvnc_invocation_get(empty.id,&info,nullptr),TIDYVNC_INVALID_ARGUMENT);
  info = init<tidyvnc_invocation_info>(); info.version = 0;
  EXPECT_EQ(tidyvnc_invocation_get(empty.id,&info,nullptr),TIDYVNC_ABI_MISMATCH);
  auto option = init<tidyvnc_invocation_option>(), optionBefore = option;
  EXPECT_EQ(tidyvnc_invocation_option_at(UINT32_MAX,&option,nullptr),TIDYVNC_NO_CHANGE);
  EXPECT_EQ(std::memcmp(&optionBefore,&option,sizeof(option)),0);
}
TEST(InvocationABI, OpaqueTextAndCatalogMetadata) {
  const std::string raw = std::string("PasswordFile=")+char(0xff); const auto arg = bytes(raw); Handle owner;
  ASSERT_EQ(tidyvnc_invocation_parse(&arg,1,&owner.id,nullptr),TIDYVNC_OK);
  auto value = init<tidyvnc_invocation_assignment>();
  ASSERT_EQ(tidyvnc_invocation_assignment_at(owner.id,0,&value,nullptr),TIDYVNC_OK);
  EXPECT_EQ(copied(value.value),std::string(1,char(0xff)));
  unsigned count = 0; bool password = false;
  for (;; ++count) {
    auto option = init<tidyvnc_invocation_option>();
    const auto result = tidyvnc_invocation_option_at(count,&option,nullptr);
    if (result == TIDYVNC_NO_CHANGE) break;
    ASSERT_EQ(result,TIDYVNC_OK); ASSERT_LT(count,128u);
    EXPECT_LE(option.boolean,1u); EXPECT_LE(option.available,1u);
    if (std::string(option.name) == "PasswordFile") { password = true; EXPECT_STREQ(option.alias,"passwd"); }
  }
  EXPECT_TRUE(password); EXPECT_GT(count,40u);
}
TEST(InvocationABI, AllocationFailuresNeverPublishPartialOwners) {
  const std::string text = "-PasswordFile="+std::string(512,'x'); const auto arg = bytes(text);
  unsigned failures = 0, successes = 0;
  for (unsigned n = 1; n <= 128; ++n) {
    uint64_t handle = 777; abi_test_fail_after(n);
    const auto result = tidyvnc_invocation_parse(&arg,1,&handle,nullptr);
    abi_test_fail_after(0);
    if (result == TIDYVNC_OK) { ++successes; tidyvnc_release(handle,nullptr); }
    else { ++failures; EXPECT_EQ(result,TIDYVNC_OUT_OF_MEMORY); EXPECT_EQ(handle,777u); }
  }
  EXPECT_GT(failures,5u); EXPECT_GT(successes,0u);
}
TEST(InvocationABI, ConcurrentImmutableReads) {
  const std::string text = "-Shared"; const auto arg = bytes(text); Handle owner;
  ASSERT_EQ(tidyvnc_invocation_parse(&arg,1,&owner.id,nullptr),TIDYVNC_OK);
  std::atomic<unsigned> failures{0}; std::vector<std::thread> readers;
  for (unsigned i = 0; i < 8; ++i) readers.emplace_back([&] {
    for (unsigned j = 0; j < 100; ++j) {
      auto value = init<tidyvnc_invocation_assignment>();
      if (tidyvnc_invocation_assignment_at(owner.id,0,&value,nullptr) != TIDYVNC_OK || copied(value.value) != "1") ++failures;
    }
  });
  for (auto& reader : readers) reader.join();
  EXPECT_EQ(failures,0u);
}
TEST(InvocationABI, ValidationCreatesIndependentCanonicalOwnerAndPreservesFailures) {
  const std::string raw = "-Shared=YES"; const auto arg = bytes(raw); Handle syntax, validated;
  ASSERT_EQ(tidyvnc_invocation_parse(&arg,1,&syntax.id,nullptr),TIDYVNC_OK);
  ASSERT_EQ(tidyvnc_invocation_validate(syntax.id,&validated.id,nullptr),TIDYVNC_OK);
  EXPECT_NE(syntax.id,validated.id);
  auto field = init<tidyvnc_invocation_assignment>();
  ASSERT_EQ(tidyvnc_invocation_assignment_at(syntax.id,0,&field,nullptr),TIDYVNC_OK);
  EXPECT_EQ(copied(field.value),"YES");
  ASSERT_EQ(tidyvnc_release(syntax.id,nullptr),TIDYVNC_OK); syntax.id = 0;
  ASSERT_EQ(tidyvnc_invocation_assignment_at(validated.id,0,&field,nullptr),TIDYVNC_OK);
  EXPECT_EQ(copied(field.value),"on");
  EXPECT_EQ(tidyvnc_invocation_validate(validated.id,nullptr,nullptr),TIDYVNC_INVALID_ARGUMENT);
  uint64_t output = 777; Handle endpoint;
  ASSERT_EQ(tidyvnc_endpoint_create(bytes("host"),{nullptr,0},1,&endpoint.id,nullptr),TIDYVNC_OK);
  EXPECT_EQ(tidyvnc_invocation_validate(endpoint.id,&output,nullptr),TIDYVNC_WRONG_HANDLE_TYPE);
  EXPECT_EQ(output,777u);
  const std::string invalid = "-Shared=private", help = "--help";
  tidyvnc_bytes args[] = {bytes(invalid),bytes(help)}; Handle bad;
  ASSERT_EQ(tidyvnc_invocation_parse(args,2,&bad.id,nullptr),TIDYVNC_OK);
  auto error = init<tidyvnc_error>();
  EXPECT_EQ(tidyvnc_invocation_validate(bad.id,&output,&error),TIDYVNC_INVALID_ARGUMENT);
  EXPECT_EQ(output,777u); EXPECT_EQ(error.domain,TIDYVNC_DOMAIN_INVOCATION);
  EXPECT_EQ(error.detail,(1u<<8)|TIDYVNC_INVOCATION_INVALID_VALUE);
  EXPECT_EQ(std::strstr(error.message,"private"),nullptr);
  unsigned failures = 0, successes = 0;
  for (unsigned n = 1; n <= 128; ++n) {
    output = 777; abi_test_fail_after(n);
    const auto status = tidyvnc_invocation_validate(validated.id,&output,nullptr);
    abi_test_fail_after(0);
    if (status == TIDYVNC_OK) { ++successes; tidyvnc_release(output,nullptr); }
    else { ++failures; EXPECT_EQ(status,TIDYVNC_OUT_OF_MEMORY); EXPECT_EQ(output,777u); }
  }
  EXPECT_GT(failures,0u); EXPECT_GT(successes,0u);
}
