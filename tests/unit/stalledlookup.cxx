/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
// Manual resolver check, deliberately not registered with CTest: it needs a name
// whose lookup cannot finish (for example, an unresponsive configured nameserver).
//   TIDYVNC_TEST_STALLED_HOSTNAME=stalled.example ./stalledlookup
// Cancellation and the resolve deadline must return promptly while it is pending.
#include <gtest/gtest.h>
#include <viewer/platform/SocketConnector.h>
#include <cstdlib>
#include <future>

using namespace viewer;
using namespace std::chrono;

TEST(StalledLookup, CancellationAndDeadlineInterruptPendingLookup)
{
  const char* host = std::getenv("TIDYVNC_TEST_STALLED_HOSTNAME");
  ASSERT_TRUE(host && *host) << "Set TIDYVNC_TEST_STALLED_HOSTNAME to a stalled name";
  SocketConnectOptions options; options.resolveTimeout = milliseconds(300);
  auto expired = prepareSocketConnection(Endpoint::parse(host), options);
  const auto before = steady_clock::now();
  try { expired->run({}); FAIL() << "Expected stalled lookup timeout"; }
  catch (const ConnectionError& error) {
    EXPECT_EQ(error.code, ConnectionErrorCode::TimedOut); EXPECT_EQ(error.phase, ConnectionPhase::Resolving);
  }
  EXPECT_LT(steady_clock::now() - before, seconds(2));

  options.resolveTimeout = milliseconds(30000);
  auto attempt = prepareSocketConnection(Endpoint::parse(host), options);
  auto control = attempt->control();
  std::promise<void> entered;
  auto executor = std::async(std::launch::async, [&] {
    try { attempt->run([&](ConnectionPhase) { entered.set_value(); }); }
    catch (const ConnectionError& error) { return error.code; }
    return ConnectionErrorCode::Connection;
  });
  entered.get_future().wait();
  EXPECT_EQ(executor.wait_for(milliseconds(100)), std::future_status::timeout);
  control->cancel();
  ASSERT_EQ(executor.wait_for(seconds(1)), std::future_status::ready);
  EXPECT_EQ(executor.get(), ConnectionErrorCode::Cancelled);
}
