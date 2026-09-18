/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */

#include <gtest/gtest.h>
#include <rfb/ClientCredentialCache.h>

#include <atomic>
#include <thread>
#include <type_traits>

static_assert(!std::is_copy_constructible<rfb::ClientCredentialCache>::value,
              "Credential owners must not be copied");
static_assert(!std::is_move_constructible<rfb::ClientCredentialCache>::value,
              "Connection references require a stable owner");

TEST(ClientCredentials, ReusesOwnedValuesAcrossAttempts)
{
  rfb::ClientCredentialCache cache;
  std::string user = "alice", password = "secret";
  cache.remember(&user, password, true);
  user = "changed";
  password = "changed";
  for (int attempt = 0; attempt < 3; ++attempt) {
    std::string nextUser, nextPassword;
    ASSERT_TRUE(cache.recall(&nextUser, nextPassword));
    EXPECT_EQ(nextUser, "alice");
    EXPECT_EQ(nextPassword, "secret");
  }
  ASSERT_TRUE(cache.recall(nullptr, password));
  EXPECT_EQ(password, "secret");
}

TEST(ClientCredentials, RetentionOptOutDiscardsEarlierCredentials)
{
  rfb::ClientCredentialCache cache;
  std::string user = "alice", password = "retained";
  cache.remember(&user, password, true);
  cache.remember(&user, "use once", false);
  user = "untouched";
  password = "untouched";
  EXPECT_FALSE(cache.recall(&user, password));
  EXPECT_FALSE(cache.recall(nullptr, password));
  EXPECT_EQ(user, "untouched");
  EXPECT_EQ(password, "untouched");
}

TEST(ClientCredentials, PasswordOnlyReplacementCannotReuseOldUsername)
{
  rfb::ClientCredentialCache cache;
  std::string user = "alice", password;
  cache.remember(&user, std::string(1024, 'a'), true);
  cache.remember(nullptr, "new", true);
  EXPECT_FALSE(cache.recall(&user, password));
  ASSERT_TRUE(cache.recall(nullptr, password));
  EXPECT_EQ(password, "new");
  cache.remember(&user, "pair", true);
  ASSERT_TRUE(cache.recall(&user, password));
  EXPECT_EQ(user, "alice");
  EXPECT_EQ(password, "pair");
}

TEST(ClientCredentials, EmptyValuesPreserveLegacyReuseRules)
{
  rfb::ClientCredentialCache cache;
  std::string user = "", password = "output";
  cache.remember(&user, "password", true);
  EXPECT_FALSE(cache.recall(&user, password));
  ASSERT_TRUE(cache.recall(nullptr, password));
  EXPECT_EQ(password, "password");
  user = "alice";
  cache.remember(&user, "", true);
  EXPECT_FALSE(cache.recall(&user, password));
  EXPECT_FALSE(cache.recall(nullptr, password));
}

TEST(ClientCredentials, FailureAndTeardownDoNotAffectOtherSessions)
{
  rfb::ClientCredentialCache other;
  std::string otherUser = "bob", user, password;
  other.remember(&otherUser, "other", true);
  {
    rfb::ClientCredentialCache failed;
    std::string failedUser = "alice";
    failed.remember(&failedUser, "failed", true);
    failed.clear(); // The authentication-error path clears this session only.
    failed.clear();
    EXPECT_FALSE(failed.recall(nullptr, password));
    ASSERT_TRUE(other.recall(&user, password));
    EXPECT_EQ(user, "bob");
    EXPECT_EQ(password, "other");
  }
  rfb::ClientCredentialCache fresh;
  EXPECT_FALSE(fresh.recall(nullptr, password));
  ASSERT_TRUE(other.recall(&user, password));
  EXPECT_EQ(password, "other");
}

TEST(ClientCredentials, ConcurrentSessionsRetainIndependentSecrets)
{
  std::atomic<bool> failed{false};
  auto run = [&](const std::string& name) {
    rfb::ClientCredentialCache cache;
    for (int i = 0; i < 1000; ++i) {
      const std::string secret = name + std::to_string(i);
      cache.remember(&name, secret, true);
      std::this_thread::yield();
      std::string user, password;
      if (!cache.recall(&user, password) || user != name || password != secret)
        failed = true;
      cache.clear();
      if (cache.recall(nullptr, password))
        failed = true;
    }
  };
  std::thread first(run, "alice"), second(run, "bob");
  first.join();
  second.join();
  EXPECT_FALSE(failed);
}
