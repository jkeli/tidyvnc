/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/StartupLogging.h>
#include <atomic>
#include <algorithm>
#include <mutex>
#include <thread>

using namespace viewer;
namespace {
struct Writers {
  core::LogWriter older{"TLS"}, connection{"CConnection"}, newer{"TLS"};
  std::vector<core::LogWriter*> ordered() { return {&newer,&connection,&older}; }
};
Writers& writers() { static Writers value; return value; }
struct Detach {
  ~Detach() { for (auto* writer : writers().ordered()) writer->setLog(nullptr); }
};
struct State {
  std::mutex mutex;
  std::vector<std::string> opened, records;
  unsigned closed = 0;
  bool writeOnClose = false;
};
class Sink : public core::Logger {
public:
  Sink(const std::string& name_, State& state_) : Logger("fixture"), name(name_), state(state_) {
    state.opened.push_back(name);
  }
  ~Sink() {
    ++state.closed;
    if (state.writeOnClose) writers().newer.info("TLS handshake completed with %s","late-private");
  }
  void write(int, const char* source, const char* text) override {
    std::lock_guard<std::mutex> lock(state.mutex);
    state.records.push_back(name+":"+source+":"+text);
  }
private:
  std::string name;
  State& state;
};
StartupLogging::Factory factory(State& state) {
  return [&](const std::string& name) { return std::unique_ptr<core::Logger>(new Sink(name,state)); };
}
}

TEST(StartupLogging, ResolvesThenInstallsRedactedSinksWithLegacyDuplicateWriterSemantics) {
  auto& nodes = writers(); Detach detach; State state;
  StartupLogging owner(nodes.ordered(),{"stderr","stdout","unused"});
  owner.configure(LoggingPolicy::parse("*:stderr:30,TLS:STDOUT:100"),factory(state));
  EXPECT_EQ(state.opened,(std::vector<std::string>{"stdout","stderr"}));
  nodes.newer.info("TLS handshake completed with %s","private-new");
  nodes.older.info("TLS handshake completed with %s","private-old");
  nodes.connection.debug("Key pressed: %d => 0x%02x / XK_%s (0x%04x)",1,2,"private-key",3);
  nodes.connection.info("Reading protocol version");
  ASSERT_EQ(state.records.size(),3u);
  EXPECT_EQ(state.records[0],"stdout:TLS:TLS handshake completed with [redacted]");
  EXPECT_EQ(state.records[1],"stderr:TLS:TLS handshake completed with [redacted]");
  EXPECT_EQ(state.records[2],"stderr:CConnection:Reading protocol version");
  EXPECT_EQ(nodes.newer.getLevel(),100); EXPECT_EQ(nodes.older.getLevel(),30);
  EXPECT_THROW(owner.configure(LoggingPolicy::parse("*::0"),factory(state)),LoggingFrozen);
  EXPECT_NO_THROW(owner.validate(LoggingPolicy::parse("TLS:stdout:0")));
}

TEST(StartupLogging, ValidationAndFactoryFailuresCannotPublishPartialRoutes) {
  auto& nodes = writers(); Detach detach; State old, pending;
  Sink legacy("old",old); nodes.newer.setLog(&legacy); nodes.newer.setLevel(17);
  StartupLogging owner(nodes.ordered(),{"stderr","stdout"});
  EXPECT_THROW(owner.configure(LoggingPolicy::parse("*:stderr:100,missing:stdout:30"),factory(pending)),LoggingError);
  EXPECT_TRUE(pending.opened.empty()); EXPECT_EQ(nodes.newer.getLevel(),17);
  EXPECT_THROW(owner.configure(LoggingPolicy::parse("TLS:stdout:100,CConnection:stderr:30"),
    [&](const std::string& name) -> std::unique_ptr<core::Logger> {
      if (name == "stderr") throw std::bad_alloc();
      return std::unique_ptr<core::Logger>(new Sink(name,pending));
    }),std::bad_alloc);
  ASSERT_EQ(pending.opened.size(),1u); EXPECT_EQ(pending.closed,1u);
  EXPECT_EQ(nodes.newer.getLevel(),17);
  nodes.newer.error("unchanged route"); ASSERT_EQ(old.records.size(),1u);
  EXPECT_EQ(old.records[0],"old:TLS:unchanged route");
  EXPECT_THROW(owner.configure(LoggingPolicy::parse("*:stderr:30"),
    [](const std::string&) { return std::unique_ptr<core::Logger>(); }),std::invalid_argument);
  // Failed preparation does not freeze admission. Only the successful commit
  // below changes routing; all destinations have been staged at that point.
  EXPECT_NO_THROW(owner.configure(LoggingPolicy::parse("*:stderr:30"),factory(pending)));
  nodes.newer.info("TLS handshake completed with %s","private");
  ASSERT_EQ(pending.records.size(),1u);
  EXPECT_EQ(pending.records[0],"stderr:TLS:TLS handshake completed with [redacted]");
}

TEST(StartupLogging, DestructionDetachesEveryBindingBeforeDestroyingDestinations) {
  auto& nodes = writers(); Detach detach; State state; state.writeOnClose = true;
  {
    StartupLogging owner(nodes.ordered(),{"stderr","stdout"});
    owner.configure(LoggingPolicy::parse("*:stderr:100,TLS:stdout:100"),factory(state));
    std::vector<std::thread> workers;
    for (int i = 0; i < 4; ++i) workers.emplace_back([&] {
      for (int j = 0; j < 100; ++j) nodes.newer.info("TLS handshake completed with %s","private");
    });
    for (auto& worker : workers) worker.join();
    ASSERT_EQ(state.records.size(),400u);
  }
  EXPECT_EQ(state.closed,2u); EXPECT_EQ(state.records.size(),400u);
  nodes.newer.info("TLS handshake completed with %s","private-after-destruction");
  EXPECT_EQ(state.records.size(),400u);
}

TEST(StartupLogging, FreezeWithoutConfigurationPreservesExistingRoutingAndNeverCreatesSinks) {
  auto& nodes = writers(); Detach detach; State state;
  Sink legacy("old",state); nodes.newer.setLog(&legacy); nodes.newer.setLevel(17);
  {
    StartupLogging owner(nodes.ordered(),{"stderr"}); owner.freeze(); owner.freeze();
    EXPECT_THROW(owner.configure(LoggingPolicy::parse("*:stderr:30"),factory(state)),LoggingFrozen);
    EXPECT_NO_THROW(owner.validate(LoggingPolicy::parse("*::0")));
    EXPECT_THROW(owner.validate(LoggingPolicy::parse("missing:stderr:30")),LoggingError);
  }
  EXPECT_EQ(state.opened,(std::vector<std::string>{"old"})); EXPECT_EQ(state.closed,0u);
  EXPECT_EQ(nodes.newer.getLevel(),17); nodes.newer.error("still attached");
  ASSERT_EQ(state.records.size(),1u); EXPECT_EQ(state.records[0],"old:TLS:still attached");
}

TEST(StartupLogging, DisabledAndOverriddenDestinationsNeverInvokeTheFactory) {
  auto& nodes = writers(); Detach detach; State state;
  StartupLogging owner(nodes.ordered(),{"stderr","stdout"});
  owner.configure(LoggingPolicy::parse("*:stdout:100,*::0"),factory(state));
  EXPECT_TRUE(state.opened.empty());
  for (auto* writer : nodes.ordered()) { EXPECT_EQ(writer->getLevel(),0); writer->error("not emitted"); }
  EXPECT_TRUE(state.records.empty());
}

TEST(StartupLogging, FreezeRacingConfigurationPublishesAllOrNothingBeforeWorkers) {
  auto& nodes = writers(); Detach detach;
  for (int i = 0; i < 100; ++i) {
    for (auto* writer : nodes.ordered()) writer->setLog(nullptr);
    State state; StartupLogging owner(nodes.ordered(),{"stderr"});
    std::atomic<bool> start{false}, configured{false};
    std::thread configure([&] {
      while (!start.load()) std::this_thread::yield();
      try { owner.configure(LoggingPolicy::parse("*:stderr:100"),factory(state)); configured = true; }
      catch (const LoggingFrozen&) {}
    });
    start = true; owner.freeze();
    // Admission has closed and published any successful startup mutation. Log
    // immediately, without waiting for the competing configure caller to return.
    nodes.newer.info("TLS handshake completed with %s","private");
    configure.join();
    EXPECT_EQ(state.records.size(),configured ? 1u : 0u);
    EXPECT_EQ(state.opened.size(),configured ? 1u : 0u);
  }
}

TEST(StartupLogging, RegistrySnapshotKeepsLegacyLookupOrderAndRejectsInvalidNodes) {
  auto& nodes = writers(); Detach detach;
  const auto snapshot = core::LogWriter::registeredWriters();
  const auto newer = std::find(snapshot.begin(),snapshot.end(),&nodes.newer);
  const auto older = std::find(snapshot.begin(),snapshot.end(),&nodes.older);
  ASSERT_NE(newer,snapshot.end()); ASSERT_NE(older,snapshot.end()); EXPECT_LT(newer,older);
  EXPECT_EQ(core::LogWriter::getLogWriter("TLS"),&nodes.newer);
  EXPECT_THROW((StartupLogging({nullptr},{"stderr"})),LoggingError);
  EXPECT_THROW((StartupLogging({&nodes.newer,&nodes.newer},{"stderr"})),LoggingError);
  EXPECT_THROW((StartupLogging(nodes.ordered(),{"stderr","STDERR"})),LoggingError);
}
