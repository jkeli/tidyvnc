/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/LoggingPolicy.h>
#include <viewer/core/Invocation.h>
#include <core/LogWriter.h>
#include <atomic>
#include <climits>
#include <cstdlib>
#include <thread>

using namespace viewer;
namespace {
void problem(const std::string& text, LoggingProblem expected, size_t entry) {
  try { LoggingPolicy::parse(text); FAIL() << "Invalid policy accepted"; }
  catch (const LoggingError& error) {
    EXPECT_EQ(error.problem,expected); EXPECT_EQ(error.entry,entry);
    EXPECT_EQ(std::string(error.what()),"Invalid logging policy");
  }
}
class Sink : public core::Logger {
public:
  Sink(const char* name) : Logger(name) { registerLogger(); }
  void write(int, const char* name, const char*) override { last = name; }
  std::string last;
};
// The legacy registries do not unregister objects. Keep differential fixtures
// alive for the process and never attach a user stream or filesystem destination.
Sink& firstSink() { static Sink value("policy-first"); return value; }
Sink& secondSink() { static Sink value("policy-second"); return value; }
core::LogWriter& firstWriter() { static core::LogWriter value("PolicyOne"); return value; }
core::LogWriter& secondWriter() { static core::LogWriter value("PolicyTwo"); return value; }
struct DisableLegacyLogs {
  ~DisableLegacyLogs() { core::LogWriter::setLogParams("*::0"); }
};
}

TEST(LoggingPolicy, PreservesDefinedRetainedDecimalPrefixLevels) {
  for (const auto* text : {"", " ", "+", "-", "abc", "0x64", "0100", "-30", "+100tail",
                          " \t\n30", "  -2147483648", "2147483647", "000000000000000000000000001"}) {
    const auto policy = LoggingPolicy::parse(std::string("*:stderr:")+text);
    ASSERT_EQ(policy.rules().size(),1u);
    EXPECT_EQ(policy.rules()[0].level,std::atoi(text));
  }
  problem("*:stderr:2147483648",LoggingProblem::LevelOverflow,1);
  problem(",,*:stderr:-2147483649",LoggingProblem::LevelOverflow,3);
  problem("*:stderr:"+std::string(5000,'9'),LoggingProblem::LevelOverflow,1);
}

TEST(LoggingPolicy, EmptyEntriesWhitespaceBoundsAndOwnedValues) {
  EXPECT_TRUE(LoggingPolicy::parse(" \f\n\r\t\v,, ,").rules().empty());
  std::string input = " ,\tOne:STDERR:30\n,,*: :100,";
  const auto policy = LoggingPolicy::parse(input); input.assign(input.size(),'x');
  ASSERT_EQ(policy.rules().size(),2u);
  EXPECT_EQ(policy.rules()[0].writer,"One"); EXPECT_EQ(policy.rules()[0].target,"STDERR");
  EXPECT_EQ(policy.rules()[0].entry,2u); EXPECT_EQ(policy.rules()[1].entry,4u);
  EXPECT_EQ(policy.rules()[1].target," "); // No trimming inside a triple.
  EXPECT_TRUE(LoggingPolicy::parse(std::string(LoggingPolicy::maximumBytes,',')).rules().empty());
  problem(std::string(LoggingPolicy::maximumBytes+1,','),LoggingProblem::TooLarge,0);
  problem(std::string("*::0\0secret",11),LoggingProblem::NullByte,0);
  for (const auto* malformed : {"secret", "secret:target", "secret:target:0:extra"})
    problem(std::string(",")+malformed,LoggingProblem::InvalidRule,2);
}

TEST(LoggingPolicy, ResolvesAllRulesTransactionallyWithOrderedWildcardOverrides) {
  const std::vector<std::string> writers{"One","Two","Three"}, targets{"stderr","stdout"};
  const auto routes = LoggingPolicy::parse("*:STDERR:30,tWo:stdout:100,one::0,Two:stderr:50").resolve(writers,targets);
  ASSERT_EQ(routes.size(),3u);
  EXPECT_EQ(routes[0].writer,"One"); EXPECT_EQ(routes[0].target,""); EXPECT_EQ(routes[0].level,0);
  EXPECT_EQ(routes[1].writer,"Two"); EXPECT_EQ(routes[1].target,"stderr"); EXPECT_EQ(routes[1].level,50);
  EXPECT_EQ(routes[2].target,"stderr"); EXPECT_EQ(routes[2].level,30);
  const auto reset = LoggingPolicy::parse("Two:stdout:100").resolve(writers,targets);
  EXPECT_EQ(reset[0].target,""); EXPECT_EQ(reset[0].level,0); EXPECT_EQ(reset[2].target,"");
  const auto overridden = LoggingPolicy::parse("Two:stdout:100,*::0").resolve(writers,targets);
  for (const auto& route : overridden) { EXPECT_EQ(route.target,""); EXPECT_EQ(route.level,0); }
  for (const auto& pair : std::vector<std::pair<std::string,LoggingProblem>>{
        {"private-writer:stderr:30,*::0",LoggingProblem::UnknownWriter},
        {"*:private-target:30,*::0",LoggingProblem::UnknownTarget},
        {":stderr:30",LoggingProblem::UnknownWriter},
        {"*: stderr:30",LoggingProblem::UnknownTarget}}) {
    try { LoggingPolicy::parse(pair.first).resolve(writers,targets); FAIL() << "Unknown name accepted"; }
    catch (const LoggingError& error) {
      EXPECT_EQ(error.problem,pair.second); EXPECT_EQ(error.entry,1u);
      EXPECT_EQ(std::string(error.what()),"Invalid logging policy");
    }
  }
}

TEST(LoggingPolicy, RejectsAmbiguousCatalogsWithoutInterpretingInputAsNames) {
  const auto policy = LoggingPolicy::parse("");
  for (const auto& names : std::vector<std::vector<std::string>>{
       {""}, {"*"}, {"one:two"}, {"one,two"}, {std::string("one\0two",7)}}) {
    for (bool writers : {false,true}) {
      try { policy.resolve(writers ? names : std::vector<std::string>{"One"},
                           writers ? std::vector<std::string>{"stderr"} : names); FAIL() << "Invalid catalog accepted"; }
      catch (const LoggingError& error) {
        EXPECT_EQ(error.problem,LoggingProblem::InvalidCatalog); EXPECT_EQ(error.entry,0u);
      }
    }
  }
  EXPECT_TRUE(LoggingPolicy::parse("*::0").resolve({},{}).empty());
  EXPECT_THROW(policy.resolve({"One"},{"stderr","STDERR"}),LoggingError);
}

TEST(LoggingPolicy, DuplicateWritersFollowLegacyFirstNamedMatchAndAllWildcardMatches) {
  const auto routes = LoggingPolicy::parse("*:stderr:30,tls:stdout:100").resolve({"TLS","Other","TLS"},{"stderr","stdout"});
  ASSERT_EQ(routes.size(),3u);
  EXPECT_EQ(routes[0].target,"stdout"); EXPECT_EQ(routes[0].level,100);
  EXPECT_EQ(routes[1].target,"stderr"); EXPECT_EQ(routes[2].target,"stderr"); EXPECT_EQ(routes[2].level,30);
  const auto cleared = LoggingPolicy::parse("tls:stdout:100,*::0").resolve({"TLS","TLS"},{"stdout"});
  for (const auto& route : cleared) { EXPECT_TRUE(route.target.empty()); EXPECT_EQ(route.level,0); }
}

TEST(LoggingPolicy, MatchesRetainedRegistryRoutingWithoutOpeningDestinations) {
  auto& a = firstSink(); auto& b = secondSink();
  auto& one = firstWriter(); auto& two = secondWriter(); DisableLegacyLogs cleanup;
  for (const auto* input : {"", " , ,", "*:policy-first:30", "*:POLICY-FIRST:30,policyone:policy-second:100",
                           "PolicyTwo:policy-first:0", "*:policy-first:100,PolicyOne::0",
                           "PolicyOne:policy-first:30,*:policy-second:1",
                           "\tPolicyOne:policy-first:+30tail,PolicyTwo:policy-second:0100\n"}) {
    SCOPED_TRACE(input);
    const auto routes = LoggingPolicy::parse(input).resolve({one.getName(),two.getName()},{a.getName(),b.getName()});
    ASSERT_TRUE(core::logParams.setParam(input));
    for (size_t i = 0; i < routes.size(); ++i) {
      auto& writer = i == 0 ? one : two;
      EXPECT_EQ(writer.getLevel(),routes[i].level);
      a.last.clear(); b.last.clear(); writer.write(INT_MIN,"fixture");
      EXPECT_EQ(a.last.empty(),routes[i].target != a.getName());
      EXPECT_EQ(b.last.empty(),routes[i].target != b.getName());
    }
  }
}

TEST(LoggingPolicy, ConcurrentResolutionAndFailuresNeverMutateLegacyRegistry) {
  auto& sink = firstSink(); auto& writer = firstWriter(); DisableLegacyLogs cleanup;
  writer.setLog(&sink); writer.setLevel(17);
  const auto policy = LoggingPolicy::parse("*:stderr:30,one::0");
  const auto invalid = LoggingPolicy::parse("*:private:30");
  std::atomic<unsigned> failures{0}; std::vector<std::thread> threads;
  for (int n = 0; n < 6; ++n) threads.emplace_back([&] {
    for (int i = 0; i < 100; ++i) {
      const auto routes = policy.resolve({"One","Two"},{"stderr"});
      if (routes.size() != 2 || !routes[0].target.empty() || routes[1].level != 30) ++failures;
      try { invalid.resolve({"One"},{"stderr"}); ++failures; }
      catch (const LoggingError&) {}
    }
  });
  for (auto& thread : threads) thread.join();
  EXPECT_EQ(failures,0u); EXPECT_EQ(writer.getLevel(),17);
  sink.last.clear(); writer.error("fixture"); EXPECT_EQ(sink.last,writer.getName());
}

TEST(LoggingPolicy, InvocationChecksEveryLevelBeforeTerminalActions) {
  for (const auto* value : {"2147483648", "-2147483649"}) {
    const auto syntax = InvocationSyntax::parse({std::string("-Log=private:private:")+value,"-Log=*::0","--help"});
    try { syntax.validatingValues(); FAIL() << "Overflow accepted"; }
    catch (const InvocationError& error) {
      EXPECT_EQ(error.problem,InvocationProblem::InvalidValue); EXPECT_EQ(error.argument,1u);
      EXPECT_EQ(std::string(error.what()),"Invalid viewer invocation");
    }
  }
  const std::string text = " , *:stderr:+30tail,,";
  const auto value = InvocationSyntax::parse({"-Log="+text}).validatingValues();
  ASSERT_EQ(value.assignments().size(),1u); EXPECT_EQ(value.assignments()[0].value,text);
}
