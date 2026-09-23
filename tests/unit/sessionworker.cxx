/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/SessionWorker.h>
#include <rfb/PixelFormat.h>
#include <rfb/encodings.h>
#include <rfb/screenTypes.h>
#include <rdr/BufferedInStream.h>
#include <rdr/MemOutStream.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <system_error>
#include <thread>
#include <vector>

using namespace viewer;
using namespace std::chrono;
namespace {
struct Probe : TransportControl {
  void wake() noexcept override { std::lock_guard<std::mutex> lock(mutex); woken = true; changed.notify_all(); }
  void cancel() noexcept override { std::lock_guard<std::mutex> lock(mutex); cancelled = true; changed.notify_all(); }
  void closePeer() { std::lock_guard<std::mutex> lock(mutex); peerClosed = true; changed.notify_all(); }
  void releaseObserver() { std::lock_guard<std::mutex> lock(mutex); holdObserver = false; changed.notify_all(); }
  void releaseWorker() { std::lock_guard<std::mutex> lock(mutex); holdWorker = false; changed.notify_all(); }
  std::mutex mutex;
  std::condition_variable changed;
  bool woken = false, cancelled = false, peerClosed = false, holdObserver = false;
  bool failWait = false, failObserver = false;
  bool holdWorker = false;
  std::atomic<bool> destroyed{false}, observerEntered{false};
  std::atomic<bool> workerWaiting{false};
  std::vector<uint8_t> output, incoming;
  void feed(const std::vector<uint8_t>& bytes) {
    std::lock_guard<std::mutex> lock(mutex);
    incoming.insert(incoming.end(), bytes.begin(), bytes.end());
    woken = true; changed.notify_all();
  }
};
class Feed : public rdr::BufferedInStream {
public:
  Feed(std::vector<uint8_t> bytes_, std::shared_ptr<Probe> probe_)
    : bytes(std::move(bytes_)), probe(std::move(probe_)) {}
private:
  bool fillBuffer() override {
    if (position == bytes.size()) {
      std::lock_guard<std::mutex> lock(probe->mutex);
      bytes = std::move(probe->incoming); position = 0;
      probe->incoming.clear();
    }
    auto count = std::min(availSpace(), bytes.size() - position);
    if (!count) return false;
    std::memcpy(const_cast<uint8_t*>(end), bytes.data() + position, count);
    end += count; position += count;
    return true;
  }
  std::vector<uint8_t> bytes;
  std::shared_ptr<Probe> probe;
  size_t position = 0;
};
class FakeTransport : public SessionTransport {
public:
  FakeTransport(std::shared_ptr<Probe> probe_, std::vector<uint8_t> bytes)
    : probe(std::move(probe_)), in(std::move(bytes), probe) {}
  ~FakeTransport() override { probe->destroyed.store(true); }
  rdr::InStream& input() override { return in; }
  rdr::OutStream& output() override { return out; }
  bool outputPending() override { return false; }
  void flush() override {
    std::lock_guard<std::mutex> lock(probe->mutex);
    probe->output.assign(out.data(), out.data() + out.length());
    probe->changed.notify_all();
  }
  std::shared_ptr<TransportControl> control() const override { return probe; }
  TransportReady wait(TimePoint deadline, bool) override {
    std::unique_lock<std::mutex> lock(probe->mutex);
    probe->workerWaiting.store(true);
    probe->changed.wait(lock, [&] { return !probe->holdWorker; });
    probe->changed.wait_until(lock, deadline, [&] {
      return probe->cancelled || probe->woken || probe->peerClosed || probe->failWait;
    });
    if (probe->failWait) throw std::system_error(EIO, std::system_category(), "fixture wait");
    TransportReady ready;
    ready.cancelled = probe->cancelled; ready.peerClosed = probe->peerClosed;
    ready.woken = probe->woken; probe->woken = false;
    ready.timedOut = Clock::now() >= deadline;
    return ready;
  }
  TransportReady waitPeerClosure(TimePoint deadline) override {
    std::unique_lock<std::mutex> lock(probe->mutex);
    probe->observerEntered.store(true);
    probe->changed.wait_until(lock, deadline, [&] {
      return (probe->cancelled && !probe->holdObserver) || probe->peerClosed || probe->failObserver;
    });
    if (probe->failObserver) throw std::system_error(EIO, std::system_category(), "fixture peer");
    TransportReady ready;
    ready.cancelled = probe->cancelled; ready.peerClosed = probe->peerClosed;
    ready.timedOut = Clock::now() >= deadline;
    return ready;
  }
private:
  std::shared_ptr<Probe> probe;
  Feed in;
  rdr::MemOutStream out;
};
std::vector<uint8_t> wire(bool authenticate = false, bool frame = false)
{
  rdr::MemOutStream out;
  out.writeBytes(reinterpret_cast<const uint8_t*>("RFB 003.008\n"), 12);
  out.writeU8(1); out.writeU8(authenticate ? rfb::secTypeVncAuth : rfb::secTypeNone);
  if (authenticate) out.pad(16);
  else {
    out.writeU32(0); out.writeU16(2); out.writeU16(2);
    rfb::PixelFormat(32,24,false,true,255,255,255,16,8,0).write(&out);
    out.writeU32(4); out.writeBytes(reinterpret_cast<const uint8_t*>("peer"), 4);
    if (frame) {
      out.writeU8(0); out.pad(1); out.writeU16(1);
      out.writeU16(0); out.writeU16(0); out.writeU16(2); out.writeU16(2); out.writeU32(0);
      for (int i = 0; i < 4; ++i) {
        out.writeU8(10); out.writeU8(20); out.writeU8(30); out.writeU8(0);
      }
    }
  }
  return {out.data(), out.data() + out.length()};
}
std::unique_ptr<SessionTransport> transport(const std::shared_ptr<Probe>& probe,
                                          std::vector<uint8_t> bytes = {})
{
  return std::unique_ptr<SessionTransport>(new FakeTransport(probe, std::move(bytes)));
}
template<class F> bool until(F predicate)
{
  const auto deadline = steady_clock::now() + seconds(3);
  do {
    if (predicate()) return true;
    std::this_thread::sleep_for(milliseconds(1));
  } while (steady_clock::now() < deadline);
  return predicate();
}
rfb::SecurityClient security(bool authenticate = false)
{
  return rfb::SecurityClient({static_cast<uint32_t>(authenticate ? rfb::secTypeVncAuth : rfb::secTypeNone)});
}
struct ReleaseWorker {
  std::shared_ptr<Probe> probe;
  ~ReleaseWorker() { probe->releaseWorker(); }
};
std::vector<SessionEvent> takeEvents(const std::shared_ptr<SessionEvents>& events)
{
  std::vector<SessionEvent> result;
  SessionEvent event;
  while (events->take(event)) result.push_back(event);
  return result;
}
struct SetupProbe : TransportControl {
  void wake() noexcept override { changed.notify_all(); }
  void cancel() noexcept override { std::lock_guard<std::mutex> lock(mutex); cancelled = true; changed.notify_all(); }
  void release() { std::lock_guard<std::mutex> lock(mutex); released = true; changed.notify_all(); }
  std::mutex mutex;
  std::condition_variable changed;
  bool cancelled = false, released = false, returnAfterCancel = false, fail = false;
  bool authenticate = false, frame = false;
  ConnectionPhase phase = ConnectionPhase::Resolving;
  ConnectionErrorCode error = ConnectionErrorCode::Resolution;
  std::atomic<bool> entered{false}, destroyed{false};
  std::thread::id executor;
  std::shared_ptr<Probe> connected = std::make_shared<Probe>();
};
class FakeConnection : public ConnectionAttempt {
public:
  explicit FakeConnection(std::shared_ptr<SetupProbe> probe_) : probe(std::move(probe_)) {}
  ~FakeConnection() override { probe->destroyed.store(true); }
  std::string serverName() const override { return "fixture"; }
  std::shared_ptr<TransportControl> control() const override { return probe; }
  std::unique_ptr<SessionTransport> run(const Progress& progress) override {
    progress(probe->phase);
    probe->executor = std::this_thread::get_id(); probe->entered.store(true);
    std::unique_lock<std::mutex> lock(probe->mutex);
    probe->changed.wait(lock, [&] { return probe->released || probe->cancelled; });
    if (probe->cancelled && !probe->returnAfterCancel)
      throw ConnectionError(ConnectionErrorCode::Cancelled, probe->phase);
    if (probe->fail) throw ConnectionError(probe->error, probe->phase, 123);
    lock.unlock();
    progress(ConnectionPhase::Connecting);
    return transport(probe->connected, wire(probe->authenticate, probe->frame));
  }
private:
  std::shared_ptr<SetupProbe> probe;
};
std::unique_ptr<ConnectionAttempt> connection(const std::shared_ptr<SetupProbe>& probe)
{
  return std::unique_ptr<ConnectionAttempt>(new FakeConnection(probe));
}
}

TEST(SessionWorker, DrivesProtocolInputAndTimersThenPreservesRetainedFrameOnDrain)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<Probe>();
  SessionWorkerOptions options; options.statisticsInterval = milliseconds(10);
  auto worker = runtime.start(transport(probe, wire(false, true)), "fixture", security(), options);
  auto events = worker->events();
  SessionEvent event;
  ASSERT_TRUE(events->take(event)); EXPECT_EQ(event.kind, SessionEventKind::Snapshot);
  EXPECT_EQ(event.snapshot.state, SessionState::Idle);
  ASSERT_TRUE(until([&] { return events->snapshot().frames == 1; }));
  EXPECT_EQ(events->snapshot().state, SessionState::Connected);
  ViewUpdate update;
  ASSERT_TRUE(worker->view()->take(update)); ASSERT_TRUE(update.frame);
  auto retained = update.frame;
  EXPECT_EQ(retained->pixels.data()[0], 10);
  size_t before;
  { std::lock_guard<std::mutex> lock(probe->mutex); before = probe->output.size(); }
  auto input = worker->input();
  EXPECT_EQ(input->key(input->status().generation, 1, 'a', 0, true), InputResult::Accepted);
  worker->wake();
  ASSERT_TRUE(until([&] { std::lock_guard<std::mutex> lock(probe->mutex); return probe->output.size() >= before + 8; }));
  auto done = worker->closeAndDrain();
  ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(done.get().code, WorkerResultCode::Cancelled);
  EXPECT_TRUE(probe->destroyed.load()); EXPECT_TRUE(events->sealed());
  {
    std::lock_guard<std::mutex> lock(probe->mutex);
    ASSERT_GE(probe->output.size(), before + 16);
    // Last RFB key event releases the held key before final transport shutdown.
    EXPECT_EQ(probe->output[probe->output.size() - 8], 4);
    EXPECT_EQ(probe->output[probe->output.size() - 7], 0);
  }
  EXPECT_FALSE(input->status().connected);
  ASSERT_TRUE(worker->view()->take(update)); EXPECT_FALSE(update.frame);
  worker.reset(); EXPECT_EQ(retained->pixels.data()[0], 10);
  EXPECT_EQ(runtime.active(), 0u);
}

TEST(SessionWorker, HandleReleaseDoesNotJoinAndDrainWaitsForObserverExit)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<Probe>(); probe->holdObserver = true;
  auto worker = runtime.start(transport(probe), "fixture", security());
  ASSERT_TRUE(until([&] { return probe->observerEntered.load(); }));
  auto done = worker->drained();
  auto release = std::async(std::launch::async, [&] { worker.reset(); });
  const auto releaseStatus = release.wait_for(milliseconds(100));
  const auto drainStatus = done.wait_for(milliseconds(20));
  const bool destroyedEarly = probe->destroyed.load();
  probe->releaseObserver(); // Always release before assertions can abort cleanup.
  EXPECT_EQ(releaseStatus, std::future_status::ready); release.get();
  EXPECT_EQ(drainStatus, std::future_status::timeout); EXPECT_FALSE(destroyedEarly);
  ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(done.get().code, WorkerResultCode::Cancelled); EXPECT_TRUE(probe->destroyed.load());
}

TEST(SessionWorker, CloseIsIdempotentAndImmediateCancellationCannotLoseToStartup)
{
  SessionRuntime runtime(2);
  for (int i = 0; i < 100; ++i) {
    auto probe = std::make_shared<Probe>();
    auto worker = runtime.start(transport(probe, wire(true)), "fixture", security(true));
    auto first = worker->closeAndDrain(), second = worker->closeAndDrain();
    ASSERT_EQ(first.wait_for(seconds(3)), std::future_status::ready);
    EXPECT_EQ(first.get().code, WorkerResultCode::Cancelled);
    EXPECT_EQ(second.get().code, WorkerResultCode::Cancelled);
    EXPECT_EQ(worker->events()->snapshot().state, SessionState::Closed);
    EXPECT_EQ(worker->events()->snapshot().endReason, SessionEndReason::Cancelled);
    unsigned terminals = 0;
    for (const auto& event : takeEvents(worker->events())) {
      if (event.kind == SessionEventKind::State &&
          (event.snapshot.state == SessionState::Closed || event.snapshot.state == SessionState::Failed)) ++terminals;
    }
    EXPECT_EQ(terminals, 1u);
    EXPECT_TRUE(probe->destroyed.load());
    AuthenticationPrompt prompt;
    EXPECT_FALSE(worker->authentication()->takeRequest(prompt));
  }
}

TEST(SessionWorker, CapacityAndShutdownRejectBeforeAdmittingAndDisposeTransport)
{
  SessionRuntime runtime(1);
  auto first = runtime.start(transport(std::make_shared<Probe>()), "fixture", security());
  auto rejected = std::make_shared<Probe>();
  EXPECT_THROW(runtime.start(transport(rejected), "fixture", security()), std::length_error);
  EXPECT_TRUE(rejected->destroyed.load());
  runtime.shutdown(); runtime.shutdown();
  ASSERT_EQ(runtime.drained().wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(first->drained().get().code, WorkerResultCode::Cancelled);
  EXPECT_EQ(runtime.active(), 0u);
  rejected = std::make_shared<Probe>();
  EXPECT_THROW(runtime.start(transport(rejected), "fixture", security()), std::logic_error);
  EXPECT_TRUE(rejected->destroyed.load());
}

TEST(SessionWorker, RuntimeDestructionOnServiceThreadDrainsRemainingHandles)
{
  std::unique_ptr<SessionRuntime> runtime(new SessionRuntime);
  auto probe = std::make_shared<Probe>();
  auto worker = runtime->start(transport(probe), "fixture", security());
  auto service = std::async(std::launch::async, [&] { runtime.reset(); });
  ASSERT_EQ(service.wait_for(seconds(3)), std::future_status::ready); service.get();
  EXPECT_TRUE(probe->destroyed.load());
  EXPECT_EQ(worker->drained().get().code, WorkerResultCode::Cancelled);
  worker->wake(); worker->closeAndDrain();
}

TEST(SessionWorker, PromptCancellationIsDirectAndDoesNotWaitForWorkerCommands)
{
  SessionRuntime runtime;
  auto worker = runtime.start(transport(std::make_shared<Probe>(), wire(true)), "fixture", security(true));
  AuthenticationPrompt prompt;
  ASSERT_TRUE(until([&] { return worker->authentication()->takeRequest(prompt); }));
  ASSERT_EQ(prompt.kind, PromptKind::Credentials);
  EXPECT_EQ(worker->events()->snapshot().state, SessionState::Authenticating);
  auto done = worker->closeAndDrain();
  ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(done.get().code, WorkerResultCode::Cancelled);
  EXPECT_EQ(worker->events()->snapshot().state, SessionState::Closed);
  EXPECT_EQ(worker->events()->snapshot().endReason, SessionEndReason::Cancelled);
  EXPECT_EQ(worker->authentication()->replyCredentials(prompt.id, prompt.generation, "", "secret"), PromptReply::NoPendingRequest);
}

TEST(SessionWorker, PromptTimeoutAndPeerClosureHaveDistinctResults)
{
  SessionRuntime runtime;
  SessionWorkerOptions options; options.promptTimeout = milliseconds(20);
  auto timeout = runtime.start(transport(std::make_shared<Probe>(), wire(true)), "fixture", security(true), options);
  ASSERT_EQ(timeout->drained().wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(timeout->drained().get().code, WorkerResultCode::PromptTimedOut);
  EXPECT_EQ(timeout->events()->snapshot().state, SessionState::Failed);
  EXPECT_EQ(timeout->events()->snapshot().endReason, SessionEndReason::PromptTimedOut);
  auto probe = std::make_shared<Probe>();
  auto peer = runtime.start(transport(probe, wire(true)), "fixture", security(true));
  AuthenticationPrompt prompt;
  ASSERT_TRUE(until([&] { return peer->authentication()->takeRequest(prompt); }));
  probe->closePeer();
  ASSERT_EQ(peer->drained().wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(peer->drained().get().code, WorkerResultCode::PeerClosed);
  EXPECT_EQ(peer->events()->snapshot().state, SessionState::Closed);
  EXPECT_EQ(peer->events()->snapshot().endReason, SessionEndReason::PeerClosed);
  EXPECT_TRUE(probe->destroyed.load());
}

TEST(SessionWorker, AnotherSessionProgressesWhileAuthenticationIsParked)
{
  SessionRuntime runtime;
  auto parked = runtime.start(transport(std::make_shared<Probe>(), wire(true)), "first", security(true));
  AuthenticationPrompt prompt;
  ASSERT_TRUE(until([&] { return parked->authentication()->takeRequest(prompt); }));
  auto live = runtime.start(transport(std::make_shared<Probe>(), wire(false, true)), "second", security());
  ASSERT_TRUE(until([&] { return live->events()->snapshot().frames == 1; }));
  EXPECT_EQ(parked->drained().wait_for(milliseconds(1)), std::future_status::timeout);
  EXPECT_EQ(parked->events()->snapshot().state, SessionState::Authenticating);
  live->closeAndDrain();
  EXPECT_EQ(parked->drained().wait_for(milliseconds(1)), std::future_status::timeout);
  parked->closeAndDrain(); runtime.shutdown();
  ASSERT_EQ(runtime.drained().wait_for(seconds(3)), std::future_status::ready);
}

TEST(SessionWorker, TransportAndObserverFailuresDrainWithNativeErrorCodes)
{
  SessionRuntime runtime;
  for (bool observer : {false, true}) {
    auto probe = std::make_shared<Probe>();
    probe->failWait = !observer; probe->failObserver = observer;
    auto worker = runtime.start(transport(probe), "fixture", security());
    ASSERT_EQ(worker->drained().wait_for(seconds(3)), std::future_status::ready);
    EXPECT_EQ(worker->drained().get().code, WorkerResultCode::TransportFailure);
    EXPECT_EQ(worker->drained().get().nativeError, EIO);
    EXPECT_EQ(worker->events()->snapshot().state, SessionState::Failed);
    EXPECT_EQ(worker->events()->snapshot().endReason, SessionEndReason::TransportFailure);
    EXPECT_EQ(worker->events()->snapshot().nativeError, EIO);
    EXPECT_EQ(worker->closeAndDrain().get().code, WorkerResultCode::TransportFailure);
    EXPECT_TRUE(probe->destroyed.load()); EXPECT_TRUE(worker->events()->sealed());
  }
}

TEST(SessionWorker, ProtocolFailureIsStructuredAndResourcesAreReleased)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<Probe>();
  auto bytes = wire(); bytes[0] = 'X';
  auto worker = runtime.start(transport(probe, bytes), "fixture", security());
  ASSERT_EQ(worker->drained().wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(worker->drained().get().code, WorkerResultCode::ProtocolFailure);
  EXPECT_EQ(worker->events()->snapshot().state, SessionState::Failed);
  EXPECT_TRUE(probe->destroyed.load());
}

TEST(SessionWorker, InvalidConstructionDoesNotConsumeRuntimeCapacity)
{
  EXPECT_THROW(SessionRuntime(0), std::invalid_argument);
  EXPECT_THROW(SessionRuntime(65), std::invalid_argument);
  SessionRuntime runtime;
  EXPECT_THROW(runtime.start(nullptr, "fixture", security()), std::invalid_argument);
  auto probe = std::make_shared<Probe>();
  SessionWorkerOptions options; options.eventCapacity = 1;
  EXPECT_THROW(runtime.start(transport(probe), "fixture", security(), options), std::invalid_argument);
  EXPECT_TRUE(probe->destroyed.load()); EXPECT_EQ(runtime.active(), 0u);
  options.eventCapacity = 128; options.commandCapacity = 0;
  EXPECT_THROW(runtime.start(transport(std::make_shared<Probe>()), "fixture", security(), options), std::invalid_argument);
  options.commandCapacity = 257;
  EXPECT_THROW(runtime.start(transport(std::make_shared<Probe>()), "fixture", security(), options), std::invalid_argument);
  auto next = runtime.start(transport(std::make_shared<Probe>()), "fixture", security());
  next->closeAndDrain();
}

TEST(SessionWorker, ConcurrentAdmissionAndShutdownLeaveNoLiveJobs)
{
  SessionRuntime runtime(8);
  std::atomic<unsigned> admitted{0};
  std::vector<std::future<void>> producers;
  for (int i = 0; i < 8; ++i) producers.push_back(std::async(std::launch::async, [&] {
    for (int j = 0; j < 20; ++j) {
      auto probe = std::make_shared<Probe>();
      try {
        auto worker = runtime.start(transport(probe), "fixture", security());
        ++admitted;
        auto done = worker->closeAndDrain();
        if (done.wait_for(seconds(3)) != std::future_status::ready)
          throw std::runtime_error("Concurrent worker failed to drain");
        if (done.get().code != WorkerResultCode::Cancelled)
          throw std::runtime_error("Unexpected concurrent worker result");
      } catch (const std::logic_error&) {
        // Shutdown or capacity rejection is synchronous and owns disposal.
        if (!probe->destroyed.load()) throw std::runtime_error("Rejected transport leaked");
        break;
      }
      if (!probe->destroyed.load()) throw std::runtime_error("Drained transport leaked");
    }
  }));
  EXPECT_TRUE(until([&] { return admitted.load() != 0; }));
  runtime.shutdown();
  for (auto& producer : producers) EXPECT_NO_THROW(producer.get());
  ASSERT_EQ(runtime.drained().wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(runtime.active(), 0u);
}

TEST(SessionWorker, CommandsRejectInvalidStateAndGenerationWithoutCompletion)
{
  SessionRuntime runtime;
  auto worker = runtime.start(transport(std::make_shared<Probe>()), "fixture", security());
  EXPECT_EQ(worker->requestRefresh(1).status, CommandAdmission::NotConnected);
  EXPECT_EQ(worker->requestRefresh(2).status, CommandAdmission::StaleGeneration);
  EXPECT_EQ(worker->applyEncodingOptions(1, EncodingOptions()).operation, 0u);
  auto done = worker->closeAndDrain();
  EXPECT_EQ(worker->requestRefresh(1).status, CommandAdmission::Closing);
  ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  for (const auto& event : takeEvents(worker->events())) EXPECT_NE(event.kind, SessionEventKind::Completion);
}

TEST(SessionWorker, BoundedCommandQueueCancellationWinsBeforeDequeue)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<Probe>(); probe->holdWorker = true;
  ReleaseWorker release{probe};
  SessionWorkerOptions options; options.commandCapacity = 2;
  auto worker = runtime.start(transport(probe, wire()), "fixture", security(), options);
  ASSERT_TRUE(until([&] { return probe->workerWaiting.load(); }));
  auto changed = worker->encodingOptions().withPatch({{"QualityLevel", "3"}}, OptionSource::Session);
  const auto first = worker->applyEncodingOptions(1, changed);
  const auto second = worker->requestRefresh(1);
  EXPECT_EQ(first.status, CommandAdmission::Accepted); EXPECT_EQ(second.status, CommandAdmission::Accepted);
  EXPECT_NE(first.operation, second.operation);
  EXPECT_EQ(worker->requestRefresh(1).status, CommandAdmission::QueueFull);
  EXPECT_EQ(worker->cancelOperation(2, first.operation), CommandCancellation::StaleGeneration);
  EXPECT_EQ(worker->cancelOperation(1, first.operation), CommandCancellation::Cancelled);
  EXPECT_EQ(worker->cancelOperation(1, first.operation), CommandCancellation::NotPending);
  probe->releaseWorker();
  std::vector<SessionEvent> completions;
  ASSERT_TRUE(until([&] {
    for (auto event : takeEvents(worker->events()))
      if (event.kind == SessionEventKind::Completion) completions.push_back(event);
    return completions.size() == 2;
  }));
  EXPECT_EQ(completions[0].operation, first.operation); EXPECT_EQ(completions[0].result, OperationResult::Cancelled);
  EXPECT_EQ(completions[1].operation, second.operation); EXPECT_EQ(completions[1].result, OperationResult::Succeeded);
  EXPECT_EQ(worker->encodingOptions().qualityLevel(), 8);
  EXPECT_EQ(worker->cancelOperation(1, second.operation), CommandCancellation::NotPending);
  auto done = worker->closeAndDrain(); ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  for (const auto& event : takeEvents(worker->events())) EXPECT_NE(event.kind, SessionEventKind::Completion);
}

TEST(SessionWorker, EncodingCommandsOwnSnapshotsAndPublishPolicyBeforeCompletion)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<Probe>(); probe->holdWorker = true;
  ReleaseWorker release{probe};
  auto worker = runtime.start(transport(probe, wire()), "fixture", security());
  ASSERT_TRUE(until([&] { return probe->workerWaiting.load(); }));
  auto policy = worker->encodingOptions().withPatch({{"QualityLevel", "3"}}, OptionSource::Session);
  const auto first = worker->applyEncodingOptions(1, policy);
  policy = policy.withPatch({{"QualityLevel", "7"}, {"AutoSelect", "0"}}, OptionSource::CommandLine);
  const auto second = worker->applyEncodingOptions(1, policy);
  policy = EncodingOptions();
  probe->releaseWorker();
  std::vector<uint64_t> ids;
  ASSERT_TRUE(until([&] {
    for (const auto& event : takeEvents(worker->events())) {
      if (event.kind != SessionEventKind::Completion) continue;
      EXPECT_EQ(event.result, OperationResult::Succeeded); ids.push_back(event.operation);
      if (event.operation == second.operation) {
        EXPECT_EQ(worker->encodingOptions().qualityLevel(), 7);
        EXPECT_FALSE(worker->encodingOptions().autoSelect());
        EXPECT_EQ(worker->encodingOptions().source(EncodingOption::QualityLevel), OptionSource::CommandLine);
      }
    }
    return ids.size() == 2;
  }));
  EXPECT_EQ(ids, (std::vector<uint64_t>{first.operation, second.operation}));
}

TEST(SessionWorker, EventCapacityRejectsBeforeEnqueueAndMutation)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<Probe>(); probe->holdWorker = true;
  ReleaseWorker release{probe};
  SessionWorkerOptions options; options.eventCapacity = 4; options.commandCapacity = 8;
  auto worker = runtime.start(transport(probe, wire()), "fixture", security(), options);
  ASSERT_TRUE(until([&] { return probe->workerWaiting.load(); }));
  takeEvents(worker->events());
  std::vector<uint64_t> ids;
  for (int i = 0; i < 4; ++i) {
    auto accepted = worker->requestRefresh(1); ASSERT_EQ(accepted.status, CommandAdmission::Accepted);
    ids.push_back(accepted.operation);
  }
  const auto rejected = worker->applyEncodingOptions(1,
    worker->encodingOptions().withPatch({{"QualityLevel", "3"}}, OptionSource::Session));
  EXPECT_EQ(rejected.status, CommandAdmission::EventCapacity); EXPECT_EQ(rejected.operation, 0u);
  for (auto id : ids) EXPECT_EQ(worker->cancelOperation(1, id), CommandCancellation::Cancelled);
  EXPECT_EQ(takeEvents(worker->events()).size(), 4u);
  EXPECT_EQ(worker->encodingOptions().qualityLevel(), 8);
  probe->releaseWorker();
}

TEST(SessionWorker, CloseCancelsQueuedCommandsAndPreservesOrderedTerminalState)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<Probe>(); probe->holdWorker = true;
  ReleaseWorker release{probe};
  auto worker = runtime.start(transport(probe, wire()), "fixture", security());
  ASSERT_TRUE(until([&] { return probe->workerWaiting.load(); }));
  const auto command = worker->requestRefresh(1);
  auto done = worker->closeAndDrain();
  EXPECT_EQ(worker->requestRefresh(1).status, CommandAdmission::Closing);
  EXPECT_EQ(done.wait_for(milliseconds(10)), std::future_status::timeout);
  probe->releaseWorker();
  ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  unsigned completions = 0, terminals = 0, disconnecting = 0;
  uint64_t sequence = 0;
  for (const auto& event : takeEvents(worker->events())) {
    EXPECT_GT(event.sequence, sequence); sequence = event.sequence;
    if (event.kind == SessionEventKind::Completion) {
      ++completions; EXPECT_EQ(event.operation, command.operation);
      EXPECT_EQ(event.result, OperationResult::Cancelled);
    }
    if (event.kind != SessionEventKind::State) continue;
    if (event.snapshot.state == SessionState::Disconnecting) ++disconnecting;
    if (event.snapshot.state == SessionState::Closed || event.snapshot.state == SessionState::Failed) {
      ++terminals; EXPECT_EQ(disconnecting, 1u);
      EXPECT_EQ(event.snapshot.state, SessionState::Closed);
      EXPECT_EQ(event.snapshot.endReason, SessionEndReason::Cancelled);
      EXPECT_EQ(event.snapshot.generation, 1u);
    }
  }
  EXPECT_EQ(completions, 1u); EXPECT_EQ(terminals, 1u);
}

TEST(SessionWorker, TerminalOverflowStillCompletesEveryAcceptedCommandOnce)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<Probe>(); probe->holdWorker = true;
  ReleaseWorker release{probe};
  SessionWorkerOptions options; options.eventCapacity = 4;
  auto worker = runtime.start(transport(probe, wire()), "fixture", security(), options);
  ASSERT_TRUE(until([&] { return probe->workerWaiting.load(); }));
  takeEvents(worker->events());
  std::vector<uint64_t> ids;
  for (int i = 0; i < 4; ++i) {
    auto accepted = worker->requestRefresh(1); ASSERT_EQ(accepted.status, CommandAdmission::Accepted);
    ids.push_back(accepted.operation);
  }
  auto done = worker->closeAndDrain(); probe->releaseWorker();
  ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(done.get().code, WorkerResultCode::EventOverflow);
  std::vector<uint64_t> completed; unsigned overflow = 0;
  for (const auto& event : takeEvents(worker->events())) {
    if (event.kind == SessionEventKind::Completion) {
      completed.push_back(event.operation); EXPECT_EQ(event.result, OperationResult::Cancelled);
    }
    if (event.kind == SessionEventKind::Overflow) ++overflow;
  }
  EXPECT_EQ(completed, ids); EXPECT_EQ(overflow, 1u);
  EXPECT_EQ(worker->events()->snapshot().endReason, SessionEndReason::EventOverflow);
  EXPECT_TRUE(worker->events()->sealed());
}

TEST(SessionWorker, ConcurrentCommandAdmissionCancellationAndConsumptionCompleteExactlyOnce)
{
  SessionRuntime runtime;
  auto worker = runtime.start(transport(std::make_shared<Probe>(), wire()), "fixture", security());
  ASSERT_TRUE(until([&] { return worker->events()->snapshot().state == SessionState::Connected; }));
  auto events = worker->events();
  auto consumer = std::async(std::launch::async, [&] {
    std::vector<uint64_t> completed;
    const auto deadline = steady_clock::now() + seconds(5);
    auto drain = [&] {
      for (const auto& event : takeEvents(events))
        if (event.kind == SessionEventKind::Completion) completed.push_back(event.operation);
    };
    do {
      drain();
      if (events->sealed()) { drain(); break; }
      std::this_thread::sleep_for(milliseconds(1));
    } while (steady_clock::now() < deadline);
    return completed;
  });
  std::vector<std::future<std::vector<uint64_t>>> producers;
  for (int i = 0; i < 4; ++i) producers.push_back(std::async(std::launch::async, [&] {
    std::vector<uint64_t> admitted;
    for (int j = 0; j < 64; ++j) {
      const auto result = worker->requestRefresh(1);
      if (result.status != CommandAdmission::Accepted) continue;
      admitted.push_back(result.operation);
      if (j % 2) worker->cancelOperation(1, result.operation);
    }
    return admitted;
  }));
  std::vector<uint64_t> admitted;
  for (auto& producer : producers) {
    const auto ids = producer.get(); admitted.insert(admitted.end(), ids.begin(), ids.end());
  }
  auto done = worker->closeAndDrain();
  EXPECT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  auto completed = consumer.get();
  std::sort(admitted.begin(), admitted.end()); std::sort(completed.begin(), completed.end());
  EXPECT_FALSE(admitted.empty()); EXPECT_EQ(completed, admitted);
  EXPECT_EQ(std::adjacent_find(completed.begin(), completed.end()), completed.end());
}

TEST(SessionWorker, ConnectionSetupRunsOnWorkerAndPublishesOrderedPhases)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<SetupProbe>();
  auto worker = runtime.connect(connection(probe), security());
  ASSERT_TRUE(until([&] { return probe->entered.load(); }));
  EXPECT_NE(probe->executor, std::this_thread::get_id());
  EXPECT_EQ(worker->events()->snapshot().state, SessionState::Resolving);
  EXPECT_EQ(worker->requestRefresh(1).status, CommandAdmission::NotConnected);
  probe->release();
  ASSERT_TRUE(until([&] { return worker->events()->snapshot().state == SessionState::Connected; }));
  std::vector<SessionState> phases;
  for (const auto& event : takeEvents(worker->events()))
    if (event.kind == SessionEventKind::State) phases.push_back(event.snapshot.state);
  EXPECT_EQ(phases, (std::vector<SessionState>{SessionState::Resolving, SessionState::Connecting,
                                             SessionState::Negotiating, SessionState::Connected}));
  EXPECT_TRUE(probe->destroyed.load());
  const auto command = worker->requestRefresh(1); EXPECT_EQ(command.status, CommandAdmission::Accepted);
  auto done = worker->closeAndDrain(); ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  EXPECT_TRUE(probe->connected->destroyed.load());
}

TEST(SessionWorker, CloseCancelsSlowResolveAndConnectDirectly)
{
  SessionRuntime runtime;
  for (auto phase : {ConnectionPhase::Resolving, ConnectionPhase::Connecting}) {
    auto probe = std::make_shared<SetupProbe>(); probe->phase = phase;
    auto worker = runtime.connect(connection(probe), security());
    ASSERT_TRUE(until([&] { return probe->entered.load(); }));
    auto done = worker->closeAndDrain();
    ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
    EXPECT_EQ(done.get().code, WorkerResultCode::Cancelled);
    EXPECT_TRUE(probe->destroyed.load());
    EXPECT_EQ(worker->events()->snapshot().state, SessionState::Closed);
    EXPECT_FALSE(worker->input()->status().connected);
  }
}

TEST(SessionWorker, CancellationWinsWhenConnectedSocketArrivesAfterClose)
{
  SessionRuntime runtime;
  for (int i = 0; i < 30; ++i) {
    auto probe = std::make_shared<SetupProbe>(); probe->returnAfterCancel = true;
    auto worker = runtime.connect(connection(probe), security());
    ASSERT_TRUE(until([&] { return probe->entered.load(); }));
    auto done = worker->closeAndDrain();
    ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
    EXPECT_EQ(done.get().code, WorkerResultCode::Cancelled);
    EXPECT_TRUE(probe->connected->destroyed.load()); EXPECT_TRUE(probe->destroyed.load());
    for (const auto& event : takeEvents(worker->events()))
      EXPECT_NE(event.snapshot.state, SessionState::Negotiating);
  }
}

TEST(SessionWorker, SetupFailuresCarryStageSpecificReasonsAndNativeCodes)
{
  SessionRuntime runtime;
  struct Failure { ConnectionErrorCode code; ConnectionPhase phase; WorkerResultCode result; };
  const Failure failures[] = {
    {ConnectionErrorCode::Resolution, ConnectionPhase::Resolving, WorkerResultCode::ResolutionFailure},
    {ConnectionErrorCode::Connection, ConnectionPhase::Connecting, WorkerResultCode::ConnectionFailure},
    {ConnectionErrorCode::TimedOut, ConnectionPhase::Resolving, WorkerResultCode::ResolutionTimedOut},
    {ConnectionErrorCode::TimedOut, ConnectionPhase::Connecting, WorkerResultCode::ConnectionTimedOut},
    {ConnectionErrorCode::Unsupported, ConnectionPhase::Connecting, WorkerResultCode::UnsupportedEndpoint},
    {ConnectionErrorCode::InvalidAddress, ConnectionPhase::Connecting, WorkerResultCode::InvalidEndpoint}
  };
  for (const auto& failure : failures) {
    auto probe = std::make_shared<SetupProbe>();
    probe->fail = probe->released = true; probe->error = failure.code; probe->phase = failure.phase;
    auto worker = runtime.connect(connection(probe), security());
    auto done = worker->drained(); ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
    EXPECT_EQ(done.get().code, failure.result); EXPECT_EQ(done.get().nativeError, 123);
    EXPECT_EQ(worker->events()->snapshot().state, SessionState::Failed);
    EXPECT_EQ(worker->events()->snapshot().endReason, failure.result);
    EXPECT_TRUE(probe->destroyed.load());
  }
  EXPECT_THROW(runtime.connect(nullptr, security()), std::invalid_argument);
}

TEST(SessionWorker, RuntimeShutdownCancelsSetupAndLiveSessionsTogether)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<SetupProbe>();
  auto pending = runtime.connect(connection(probe), security());
  ASSERT_TRUE(until([&] { return probe->entered.load(); }));
  auto live = runtime.start(transport(std::make_shared<Probe>(), wire()), "fixture", security());
  ASSERT_TRUE(until([&] { return live->events()->snapshot().state == SessionState::Connected; }));
  runtime.shutdown();
  ASSERT_EQ(runtime.drained().wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(pending->drained().get().code, WorkerResultCode::Cancelled);
  EXPECT_EQ(live->drained().get().code, WorkerResultCode::Cancelled);
  EXPECT_TRUE(probe->destroyed.load());
}


namespace {
bool completion(const std::shared_ptr<SessionWorker>& session, uint64_t id, SessionEvent& found)
{
  return until([&] {
    SessionEvent event;
    while (session->events()->take(event)) {
      if (event.kind == SessionEventKind::Completion && event.operation == id) { found = event; return true; }
    }
    return false;
  });
}
std::shared_ptr<SetupProbe> prepared(bool frame = false, bool authenticate = false)
{
  auto probe = std::make_shared<SetupProbe>();
  probe->released = true; probe->frame = frame; probe->authenticate = authenticate;
  return probe;
}
}
TEST(SessionWorker, ReusableIdleSessionOwnsRuntimeSlotAndClosesWithoutConnecting)
{
  SessionRuntime runtime(1);
  auto session = runtime.createSession(security());
  EXPECT_EQ(runtime.active(), 1u);
  EXPECT_EQ(session->events()->snapshot().state, SessionState::Idle);
  EXPECT_EQ(session->requestRefresh(1).status, CommandAdmission::NotConnected);
  EXPECT_THROW(runtime.createSession(security()), std::length_error);
  EXPECT_THROW(session->connect(nullptr), std::invalid_argument);
  auto done = session->closeAndDrain();
  ASSERT_EQ(done.wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(done.get().code, WorkerResultCode::Cancelled);
  EXPECT_TRUE(session->events()->sealed());
  EXPECT_EQ(session->events()->snapshot().state, SessionState::Closed);
  auto rejected = prepared();
  EXPECT_EQ(session->connect(connection(rejected)).status, CommandAdmission::Closing);
  EXPECT_TRUE(rejected->destroyed.load());
}
TEST(SessionWorker, ReconnectPreservesMailboxesSettingsAndOldFrameLeases)
{
  SessionRuntime runtime;
  auto session = runtime.createSession(security());
  auto events = session->events(); auto view = session->view();
  auto input = session->input(); auto auth = session->authentication();
  FrameLease retained;
  uint64_t oldGeneration = 0, oldOperation = 0;
  std::thread::id executor;
  SessionEvent event;
  for (int attempt = 0; attempt < 3; ++attempt) {
    auto probe = prepared(true);
    auto accepted = session->connect(connection(probe));
    ASSERT_EQ(accepted.status, CommandAdmission::Accepted);
    EXPECT_GT(accepted.generation, oldGeneration);
    EXPECT_GT(accepted.operation, oldOperation);
    ASSERT_TRUE(completion(session, accepted.operation, event));
    EXPECT_EQ(event.result, OperationResult::Succeeded);
    EXPECT_EQ(event.snapshot.generation, accepted.generation);
    EXPECT_EQ(event.snapshot.state, SessionState::Connected);
    if (attempt) { EXPECT_EQ(probe->executor, executor); }
    executor = probe->executor;
    EXPECT_EQ(events, session->events()); EXPECT_EQ(view, session->view());
    EXPECT_EQ(input, session->input()); EXPECT_EQ(auth, session->authentication());
    ASSERT_TRUE(until([&] { return events->snapshot().frames == 1; }));
    ViewUpdate update; ASSERT_TRUE(view->take(update)); ASSERT_TRUE(update.frame);
    EXPECT_EQ(update.frame->generation, accepted.generation);
    if (!retained) retained = update.frame;
    EXPECT_EQ(retained->pixels.data()[0], 10);
    if (oldGeneration) {
      EXPECT_EQ(input->key(oldGeneration, 1, 'x', 0, true), InputResult::StaleGeneration);
      EXPECT_EQ(session->requestRefresh(oldGeneration).status, CommandAdmission::StaleGeneration);
      EXPECT_EQ(session->disconnect(oldGeneration).status, CommandAdmission::StaleGeneration);
      EXPECT_EQ(session->cancelOperation(oldGeneration, oldOperation), CommandCancellation::StaleGeneration);
      EXPECT_TRUE(input->status().viewOnly);
      EXPECT_FALSE(session->encodingOptions().autoSelect());
    } else {
      auto settings = EncodingOptions::resolve({}, {}, { {"AutoSelect", "0"} }, {});
      auto applied = session->applyEncodingOptions(accepted.generation, settings);
      ASSERT_EQ(applied.status, CommandAdmission::Accepted);
      ASSERT_TRUE(completion(session, applied.operation, event));
      EXPECT_EQ(event.result, OperationResult::Succeeded);
      input->setViewOnly(true); session->wake();
    }
    auto disconnect = session->disconnect(accepted.generation);
    ASSERT_EQ(disconnect.status, CommandAdmission::Accepted);
    ASSERT_TRUE(completion(session, disconnect.operation, event));
    EXPECT_EQ(event.result, OperationResult::Succeeded);
    EXPECT_TRUE(probe->connected->destroyed.load());
    EXPECT_FALSE(events->sealed()); EXPECT_FALSE(input->status().connected);
    EXPECT_EQ(session->drained().wait_for(milliseconds(0)), std::future_status::timeout);
    oldGeneration = accepted.generation; oldOperation = disconnect.operation;
  }
  ASSERT_EQ(session->closeAndDrain().wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(retained->pixels.data()[2], 30);
}
TEST(SessionWorker, ReconnectKeepsPromptIdsAndRejectsOldRepliesAndCancellation)
{
  SessionRuntime runtime;
  auto session = runtime.createSession(security(true));
  AuthenticationPrompt old;
  for (int attempt = 0; attempt < 2; ++attempt) {
    auto accepted = session->connect(connection(prepared(false, true)));
    ASSERT_EQ(accepted.status, CommandAdmission::Accepted);
    AuthenticationPrompt prompt;
    ASSERT_TRUE(until([&] { return session->authentication()->takeRequest(prompt); }));
    EXPECT_EQ(prompt.generation, accepted.generation);
    if (attempt) {
      EXPECT_GT(prompt.id, old.id);
      EXPECT_EQ(session->authentication()->replyCredentials(old.id, old.generation, "", "old"), PromptReply::StaleRequest);
      session->authentication()->cancelAttempt(old.generation);
      // The current prompt is still awaiting a reply after an old cancellation.
      EXPECT_EQ(session->authentication()->replyTrust(prompt.id, prompt.generation, true), PromptReply::WrongKind);
    }
    auto disconnected = session->disconnect(accepted.generation);
    ASSERT_EQ(disconnected.status, CommandAdmission::Accepted);
    SessionEvent event;
    ASSERT_TRUE(completion(session, accepted.operation, event));
    EXPECT_EQ(event.result, OperationResult::Cancelled);
    ASSERT_TRUE(completion(session, disconnected.operation, event));
    EXPECT_EQ(event.result, OperationResult::Succeeded);
    old = prompt;
  }
  ASSERT_EQ(session->closeAndDrain().wait_for(seconds(3)), std::future_status::ready);
}
TEST(SessionWorker, SetupFailureCanRetryOnSameSessionAndCompletesOnce)
{
  SessionRuntime runtime;
  auto session = runtime.createSession(security());
  auto failure = prepared(); failure->fail = true;
  auto first = session->connect(connection(failure));
  ASSERT_EQ(first.status, CommandAdmission::Accepted);
  SessionEvent event;
  ASSERT_TRUE(completion(session, first.operation, event));
  EXPECT_EQ(event.result, OperationResult::Failed);
  EXPECT_EQ(event.snapshot.endReason, SessionEndReason::ResolutionFailure);
  EXPECT_EQ(event.snapshot.nativeError, 123);
  EXPECT_TRUE(failure->destroyed.load()); EXPECT_FALSE(session->events()->sealed());
  auto second = session->connect(connection(prepared()));
  ASSERT_EQ(second.status, CommandAdmission::Accepted);
  EXPECT_GT(second.generation, first.generation);
  ASSERT_TRUE(completion(session, second.operation, event));
  EXPECT_EQ(event.result, OperationResult::Succeeded);
  EXPECT_EQ(event.snapshot.endReason, SessionEndReason::None);
  ASSERT_EQ(session->closeAndDrain().wait_for(seconds(3)), std::future_status::ready);
  for (const auto& remaining : takeEvents(session->events()))
    EXPECT_NE(remaining.operation, first.operation);
}
TEST(SessionWorker, ConnectCancellationWorksBeforeWorkerSetupAndDuringResolve)
{
  SessionRuntime runtime;
  auto session = runtime.createSession(security());
  for (int n = 0; n < 30; ++n) {
    auto probe = std::make_shared<SetupProbe>();
    auto accepted = session->connect(connection(probe));
    ASSERT_EQ(accepted.status, CommandAdmission::Accepted);
    if (n % 2) { ASSERT_TRUE(until([&] { return probe->entered.load(); })); }
    EXPECT_EQ(session->cancelOperation(accepted.generation, accepted.operation), CommandCancellation::Cancelled);
    SessionEvent event;
    ASSERT_TRUE(completion(session, accepted.operation, event));
    EXPECT_EQ(event.result, OperationResult::Cancelled);
    EXPECT_EQ(event.snapshot.generation, accepted.generation);
    EXPECT_EQ(event.snapshot.state, SessionState::Closed);
    EXPECT_TRUE(probe->destroyed.load());
    EXPECT_FALSE(session->events()->sealed());
  }
  ASSERT_EQ(session->closeAndDrain().wait_for(seconds(3)), std::future_status::ready);
}
TEST(SessionWorker, DisconnectCompletionWaitsForObserverAndRejectsEarlyReconnect)
{
  SessionRuntime runtime;
  auto session = runtime.createSession(security());
  auto probe = prepared(); probe->connected->holdObserver = true;
  struct Release { std::shared_ptr<Probe> probe; ~Release() { probe->releaseObserver(); } } release{probe->connected};
  auto accepted = session->connect(connection(probe));
  SessionEvent event;
  ASSERT_TRUE(completion(session, accepted.operation, event));
  auto disconnect = session->disconnect(accepted.generation);
  ASSERT_EQ(disconnect.status, CommandAdmission::Accepted);
  ASSERT_TRUE(until([&] { return session->events()->snapshot().state == SessionState::Disconnecting; }));
  auto rejected = prepared();
  EXPECT_EQ(session->connect(connection(rejected)).status, CommandAdmission::Busy);
  EXPECT_TRUE(rejected->destroyed.load());
  for (const auto& queued : takeEvents(session->events())) EXPECT_NE(queued.operation, disconnect.operation);
  EXPECT_FALSE(probe->connected->destroyed.load());
  const auto policy = session->securityOptions();
  EXPECT_FALSE(policy.editable);
  const auto sharing = session->sharing();
  EXPECT_EQ(session->setShared(sharing.generation,sharing.revision,true),CommandAdmission::Busy);
  EXPECT_EQ(session->setSecurity(policy.generation,policy.revision,security()),CommandAdmission::Busy);
  probe->connected->releaseObserver();
  ASSERT_TRUE(completion(session, disconnect.operation, event));
  EXPECT_TRUE(probe->connected->destroyed.load());
  auto next = session->connect(connection(prepared()));
  ASSERT_EQ(next.status, CommandAdmission::Accepted);
  ASSERT_TRUE(completion(session, next.operation, event));
  ASSERT_EQ(session->closeAndDrain().wait_for(seconds(3)), std::future_status::ready);
}
TEST(SessionWorker, ConcurrentConnectAdmissionAcceptsExactlyOneAttempt)
{
  SessionRuntime runtime;
  auto session = runtime.createSession(security());
  std::array<CommandSubmission, 8> results = {{CommandAdmission::Busy, CommandAdmission::Busy,
    CommandAdmission::Busy, CommandAdmission::Busy, CommandAdmission::Busy, CommandAdmission::Busy,
    CommandAdmission::Busy, CommandAdmission::Busy}};
  std::vector<std::thread> callers;
  for (size_t i = 0; i < results.size(); ++i)
    callers.emplace_back([&, i] { results[i] = session->connect(connection(std::make_shared<SetupProbe>())); });
  for (auto& caller : callers) caller.join();
  size_t accepted = 0;
  for (const auto& result : results) {
    if (result.status == CommandAdmission::Accepted) ++accepted;
    else EXPECT_EQ(result.status, CommandAdmission::Busy);
  }
  EXPECT_EQ(accepted, 1u);
  ASSERT_EQ(session->closeAndDrain().wait_for(seconds(3)), std::future_status::ready);
}
TEST(SessionWorker, ReusableEventOverflowEndsSessionAndPreservesConnectCompletion)
{
  SessionRuntime runtime;
  SessionWorkerOptions options; options.eventCapacity = 2;
  auto session = runtime.createSession(security(), options);
  // Initial snapshot plus connect completion reservation leaves no state slot.
  auto accepted = session->connect(connection(prepared()));
  ASSERT_EQ(accepted.status, CommandAdmission::Accepted);
  ASSERT_EQ(session->drained().wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(session->drained().get().code, WorkerResultCode::EventOverflow);
  int completions = 0, overflows = 0;
  for (const auto& event : takeEvents(session->events())) {
    if (event.kind == SessionEventKind::Completion) {
      ++completions; EXPECT_EQ(event.operation, accepted.operation);
      EXPECT_EQ(event.result, OperationResult::Failed);
    }
    if (event.kind == SessionEventKind::Overflow) ++overflows;
  }
  EXPECT_EQ(completions, 1); EXPECT_EQ(overflows, 1);
  EXPECT_EQ(session->connect(connection(prepared())).status, CommandAdmission::Closing);
}
TEST(SessionWorker, RuntimeShutdownJoinsIdleAndActiveReusableSessions)
{
  SessionRuntime runtime(3);
  auto idle = runtime.createSession(security());
  auto resolving = runtime.createSession(security());
  auto prompting = runtime.createSession(security(true));
  auto first = resolving->connect(connection(std::make_shared<SetupProbe>()));
  auto second = prompting->connect(connection(prepared(false, true)));
  AuthenticationPrompt prompt;
  ASSERT_TRUE(until([&] { return prompting->authentication()->takeRequest(prompt); }));
  for (const auto& active : {resolving,prompting}) {
    const auto policy = active->securityOptions();
    EXPECT_FALSE(policy.editable);
    const auto sharing = active->sharing();
    EXPECT_EQ(active->setShared(sharing.generation,sharing.revision,true),CommandAdmission::Busy);
    EXPECT_EQ(active->setSecurity(policy.generation,policy.revision,security()),CommandAdmission::Busy);
    EXPECT_EQ(active->securityOptions().revision,policy.revision);
  }
  EXPECT_EQ(prompting->authentication()->replyTrust(prompt.id,prompt.generation,true),PromptReply::WrongKind);
  runtime.shutdown();
  ASSERT_EQ(runtime.drained().wait_for(seconds(3)), std::future_status::ready);
  EXPECT_EQ(runtime.active(), 0u);
  EXPECT_TRUE(idle->events()->sealed()); EXPECT_TRUE(resolving->events()->sealed());
  EXPECT_TRUE(prompting->events()->sealed());
  SessionEvent event;
  ASSERT_TRUE(completion(resolving, first.operation, event)); EXPECT_EQ(event.result, OperationResult::Cancelled);
  ASSERT_TRUE(completion(prompting, second.operation, event)); EXPECT_EQ(event.result, OperationResult::Cancelled);
}

TEST(SessionWorker, TerminalEventMakesRetryImmediatelyAdmissible)
{
  SessionRuntime runtime;
  auto session = runtime.createSession(security());
  for (int n = 0; n < 20; ++n) {
    auto probe = prepared(); probe->fail = true;
    auto accepted = session->connect(connection(probe));
    ASSERT_EQ(accepted.status, CommandAdmission::Accepted);
    // React to terminal publication without waiting for the operation completion.
    ASSERT_TRUE(until([&] {
      const auto snapshot = session->events()->snapshot();
      return snapshot.generation == accepted.generation && snapshot.state == SessionState::Failed;
    }));
    EXPECT_TRUE(probe->destroyed.load());
    takeEvents(session->events());
  }
  ASSERT_EQ(session->closeAndDrain().wait_for(seconds(3)), std::future_status::ready);
}

TEST(SessionWorker, ImmediateDisconnectCancelsAdmittedConnectAndAllowsNextAttempt)
{
  SessionRuntime runtime;
  auto session = runtime.createSession(security());
  for (int n = 0; n < 30; ++n) {
    auto accepted = session->connect(connection(std::make_shared<SetupProbe>()));
    ASSERT_EQ(accepted.status, CommandAdmission::Accepted);
    auto disconnected = session->disconnect(accepted.generation);
    ASSERT_EQ(disconnected.status, CommandAdmission::Accepted);
    EXPECT_EQ(session->cancelOperation(disconnected.generation, disconnected.operation), CommandCancellation::NotPending);
    SessionEvent event;
    ASSERT_TRUE(completion(session, accepted.operation, event));
    EXPECT_EQ(event.result, OperationResult::Cancelled);
    ASSERT_TRUE(completion(session, disconnected.operation, event));
    EXPECT_EQ(event.result, OperationResult::Succeeded);
    EXPECT_EQ(event.snapshot.generation, accepted.generation);
  }
  ASSERT_EQ(session->closeAndDrain().wait_for(seconds(3)), std::future_status::ready);
}

TEST(SessionWorker, ReconnectChargesOldFrameLeasesToTheSamePublicationBudget)
{
  SessionRuntime runtime;
  SessionWorkerOptions options; options.buffers.publicationBytes = 32;
  auto session = runtime.createSession(security(), options);
  auto first = session->connect(connection(prepared(true)));
  SessionEvent event; ASSERT_TRUE(completion(session, first.operation, event));
  ASSERT_TRUE(until([&] { return session->events()->snapshot().frames == 1; }));
  ViewUpdate update;
  ASSERT_TRUE(until([&] {
    return session->view()->take(update) && update.frame && update.frame->pixels.data()[0] == 10;
  }));
  auto retained = update.frame; update = {};
  auto closed = session->disconnect(first.generation);
  ASSERT_TRUE(completion(session, closed.operation, event));
  auto second = session->connect(connection(prepared(true)));
  ASSERT_EQ(second.status, CommandAdmission::Accepted);
  ASSERT_TRUE(completion(session, second.operation, event));
  ASSERT_TRUE(until([&] { return session->events()->snapshot().frames == 1; }));
  ASSERT_TRUE(session->view()->take(update));
  EXPECT_EQ(update.generation, second.generation);
  ASSERT_TRUE(update.frame); EXPECT_NE(update.frame->pixels.data()[0], 10);
  EXPECT_EQ(retained->pixels.length(), 16u);
  retained.reset();
  ASSERT_TRUE(until([&] {
    return session->view()->take(update) && update.frame && update.frame->pixels.data()[0] == 10;
  }));
  EXPECT_EQ(update.frame->generation, second.generation);
  ASSERT_EQ(session->closeAndDrain().wait_for(seconds(3)), std::future_status::ready);
}

namespace {
std::vector<uint8_t> resizeReply(unsigned reason, unsigned result, unsigned width) {
  rdr::MemOutStream out;
  out.writeU8(0); out.pad(1); out.writeU16(1);
  out.writeU16(reason); out.writeU16(result); out.writeU16(width); out.writeU16(2);
  out.writeU32(rfb::pseudoEncodingExtendedDesktopSize); out.writeU8(1); out.pad(3);
  out.writeU32(7); out.writeU16(0); out.writeU16(0); out.writeU16(width); out.writeU16(2); out.writeU32(0);
  return {out.data(),out.data()+out.length()};
}
std::vector<uint8_t> resizeHandshake() {
  auto bytes = wire(); auto capability = resizeReply(rfb::reasonServer,0,2);
  bytes.insert(bytes.end(),capability.begin(),capability.end()); return bytes;
}
RemoteDesktopLayout remoteLayout(unsigned width = 4) { return RemoteDesktopLayout(width,2,{{7,0,0,width,2,0}}); }
}
TEST(SessionWorker, DesktopLayoutAdmissionCancellationAndServerCompletion)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<Probe>(); probe->holdWorker = true;
  auto worker = runtime.start(transport(probe,resizeHandshake()),"fixture",security());
  ReleaseWorker release{probe};
  ASSERT_TRUE(until([&] { return probe->workerWaiting.load(); }));
  const auto generation = worker->events()->snapshot().generation;
  ASSERT_TRUE(worker->events()->snapshot().supportsDesktopResize);
  takeEvents(worker->events());
  auto first = worker->requestDesktopLayout(generation,remoteLayout(),101);
  ASSERT_EQ(first.status,CommandAdmission::Accepted);
  EXPECT_EQ(worker->requestDesktopLayout(generation,remoteLayout(3)).status,CommandAdmission::Busy);
  EXPECT_EQ(worker->cancelOperation(generation,first.operation),CommandCancellation::Cancelled);
  SessionEvent event; ASSERT_TRUE(completion(worker,first.operation,event));
  EXPECT_EQ(event.result,OperationResult::Cancelled); EXPECT_EQ(event.origin,101u);
  worker->input()->setViewOnly(true);
  EXPECT_EQ(worker->requestDesktopLayout(generation,remoteLayout()).status,CommandAdmission::ViewOnly);
  worker->input()->setViewOnly(false);
  auto second = worker->requestDesktopLayout(generation,remoteLayout(3),102);
  ASSERT_EQ(second.status,CommandAdmission::Accepted); probe->releaseWorker();
  ASSERT_TRUE(until([&] { return worker->events()->snapshot().resizePending; }));
  EXPECT_EQ(worker->cancelOperation(generation,second.operation),CommandCancellation::NotPending);
  EXPECT_EQ(worker->requestDesktopLayout(generation,remoteLayout()).status,CommandAdmission::Busy);
  probe->feed(resizeReply(rfb::reasonClient,0,3));
  ASSERT_TRUE(completion(worker,second.operation,event));
  EXPECT_EQ(event.result,OperationResult::Succeeded); EXPECT_EQ(event.origin,102u);
  EXPECT_EQ(event.snapshot.layout->width(),3u); EXPECT_FALSE(event.snapshot.resizePending);
  ASSERT_EQ(worker->closeAndDrain().wait_for(seconds(3)),std::future_status::ready);
  EXPECT_FALSE(worker->events()->snapshot().layout); EXPECT_FALSE(worker->events()->snapshot().supportsDesktopResize);
}
TEST(SessionWorker, DesktopLayoutRechecksViewOnlyBeforeSendingAndRejectsOversizedRequest)
{
  SessionRuntime runtime; SessionWorkerOptions options; options.buffers.framebufferBytes = 32;
  auto probe = std::make_shared<Probe>(); probe->holdWorker = true;
  auto worker = runtime.start(transport(probe,resizeHandshake()),"fixture",security(),options);
  ReleaseWorker release{probe};
  ASSERT_TRUE(until([&] { return probe->workerWaiting.load(); }));
  const auto generation = worker->events()->snapshot().generation;
  EXPECT_EQ(worker->requestDesktopLayout(generation+1,remoteLayout()).status,CommandAdmission::StaleGeneration);
  EXPECT_EQ(worker->requestDesktopLayout(generation,remoteLayout(5)).status,CommandAdmission::ResourceLimit);
  takeEvents(worker->events()); size_t before;
  { std::lock_guard<std::mutex> lock(probe->mutex); before = probe->output.size(); }
  auto accepted = worker->requestDesktopLayout(generation,remoteLayout());
  ASSERT_EQ(accepted.status,CommandAdmission::Accepted);
  worker->input()->setViewOnly(true); probe->releaseWorker();
  SessionEvent event; ASSERT_TRUE(completion(worker,accepted.operation,event));
  EXPECT_EQ(event.result,OperationResult::Failed); EXPECT_FALSE(event.snapshot.resizePending);
  { std::lock_guard<std::mutex> lock(probe->mutex); EXPECT_EQ(probe->output.size(),before); }
  EXPECT_EQ(worker->events()->snapshot().state,SessionState::Connected);
  ASSERT_EQ(worker->closeAndDrain().wait_for(seconds(3)),std::future_status::ready);
}
TEST(SessionWorker, DesktopLayoutTimeoutLateReplyAndCloseSettleExactlyOnce)
{
  SessionRuntime runtime; SessionWorkerOptions options; options.desktopResizeTimeout = milliseconds(100);
  auto probe = std::make_shared<Probe>();
  auto worker = runtime.start(transport(probe,resizeHandshake()),"fixture",security(),options);
  ASSERT_TRUE(until([&] { return worker->events()->snapshot().supportsDesktopResize; }));
  const auto generation = worker->events()->snapshot().generation; takeEvents(worker->events());
  auto accepted = worker->requestDesktopLayout(generation,remoteLayout(),71);
  ASSERT_EQ(accepted.status,CommandAdmission::Accepted);
  SessionEvent event; ASSERT_TRUE(completion(worker,accepted.operation,event));
  EXPECT_EQ(event.failure,OperationFailure::TimedOut); EXPECT_EQ(event.origin,71u);
  EXPECT_EQ(worker->requestDesktopLayout(generation,remoteLayout()).status,CommandAdmission::Busy);
  probe->feed(resizeReply(rfb::reasonOtherClient,0,3));
  ASSERT_TRUE(until([&] { return worker->events()->snapshot().width == 3; }));
  EXPECT_TRUE(worker->events()->snapshot().resizePending);
  probe->feed(resizeReply(rfb::reasonClient,0,4));
  ASSERT_TRUE(until([&] { return !worker->events()->snapshot().resizePending; }));
  for (const auto& queued : takeEvents(worker->events())) EXPECT_NE(queued.operation,accepted.operation);
  auto next = worker->requestDesktopLayout(generation,remoteLayout(5),72);
  ASSERT_EQ(next.status,CommandAdmission::Accepted);
  ASSERT_TRUE(until([&] { return worker->events()->snapshot().resizePending; }));
  ASSERT_EQ(worker->closeAndDrain().wait_for(seconds(3)),std::future_status::ready);
  ASSERT_TRUE(completion(worker,next.operation,event));
  EXPECT_EQ(event.result,OperationResult::Cancelled); EXPECT_EQ(event.origin,72u);
  EXPECT_FALSE(worker->events()->snapshot().resizePending);
}

TEST(SessionWorker, ClipboardCommandOwnsTextAndReservesOneSlotUntilCompletion)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<Probe>(); probe->holdWorker = true;
  auto worker = runtime.start(transport(probe,wire()),"fixture",security());
  ReleaseWorker release{probe};
  ASSERT_TRUE(until([&] { return probe->workerWaiting.load(); }));
  takeEvents(worker->events());
  std::string text = "owned";
  auto first = worker->offerClipboard(1,text,{},101); text.assign("changed");
  ASSERT_EQ(first.status,CommandAdmission::Accepted);
  EXPECT_EQ(worker->clearClipboard(1).status,CommandAdmission::Busy);
  EXPECT_EQ(worker->offerClipboard(1,"next").status,CommandAdmission::Busy);
  EXPECT_EQ(worker->clipboard()->bytesInUse(),5u);
  EXPECT_EQ(worker->cancelOperation(1,first.operation),CommandCancellation::Cancelled);
  EXPECT_EQ(worker->clipboard()->bytesInUse(),0u);
  SessionEvent event; ASSERT_TRUE(completion(worker,first.operation,event));
  EXPECT_EQ(event.result,OperationResult::Cancelled); EXPECT_EQ(event.origin,101u);
  auto second = worker->offerClipboard(1,"sent",{},102);
  ASSERT_EQ(second.status,CommandAdmission::Accepted); probe->releaseWorker();
  ASSERT_TRUE(completion(worker,second.operation,event));
  EXPECT_EQ(event.result,OperationResult::Succeeded); EXPECT_EQ(event.origin,102u);
  auto clear = worker->clearClipboard(1);
  ASSERT_EQ(clear.status,CommandAdmission::Accepted);
  ASSERT_TRUE(completion(worker,clear.operation,event));
  EXPECT_EQ(event.result,OperationResult::Succeeded);
  ASSERT_TRUE(until([&] { return worker->clipboard()->bytesInUse() == 0; }));
  const std::vector<uint8_t> expected{6,0,0,0,0,0,0,4,'s','e','n','t'};
  ASSERT_TRUE(until([&] {
    std::lock_guard<std::mutex> lock(probe->mutex);
    return std::search(probe->output.begin(),probe->output.end(),expected.begin(),expected.end()) != probe->output.end();
  }));
}

TEST(SessionWorker, ClipboardRechecksFocusAndPolicyAfterCommandAdmission)
{
  for (bool changePolicy : {false,true}) {
    SessionRuntime runtime;
    auto probe = std::make_shared<Probe>(); probe->holdWorker = true;
    auto worker = runtime.start(transport(probe,wire()),"fixture",security());
    ReleaseWorker release{probe};
    ASSERT_TRUE(until([&] { return probe->workerWaiting.load(); }));
    size_t before;
    { std::lock_guard<std::mutex> lock(probe->mutex); before = probe->output.size(); }
    auto accepted = worker->offerClipboard(1,"must not send");
    ASSERT_EQ(accepted.status,CommandAdmission::Accepted);
    if (changePolicy) {
      worker->setClipboardPolicy({false,true}); worker->setClipboardPolicy({true,true});
    } else {
      worker->input()->setFocused(1,false); worker->input()->setFocused(1,true);
    }
    probe->releaseWorker();
    SessionEvent event; ASSERT_TRUE(completion(worker,accepted.operation,event));
    EXPECT_EQ(event.result,OperationResult::Failed);
    ASSERT_TRUE(until([&] { return worker->clipboard()->bytesInUse() == 0; }));
    { std::lock_guard<std::mutex> lock(probe->mutex); EXPECT_EQ(probe->output.size(),before); }
    EXPECT_EQ(worker->events()->snapshot().state,SessionState::Connected);
  }
}

TEST(SessionWorker, ClipboardAdmissionReportsPolicyValidationAndBudgetFailures)
{
  SessionRuntime runtime; SessionWorkerOptions options;
  options.buffers.clipboardTextBytes = 8; options.buffers.clipboardRetainedBytes = 8;
  auto probe = std::make_shared<Probe>();
  auto worker = runtime.start(transport(probe,wire()),"fixture",security(),options);
  ASSERT_TRUE(until([&] { return probe->workerWaiting.load(); }));
  EXPECT_EQ(worker->offerClipboard(2,"text").status,CommandAdmission::StaleGeneration);
  worker->input()->setFocused(1,false);
  EXPECT_EQ(worker->offerClipboard(1,"text").status,CommandAdmission::Unfocused);
  worker->input()->setFocused(1,true); worker->input()->setViewOnly(true);
  EXPECT_EQ(worker->offerClipboard(1,"text").status,CommandAdmission::ViewOnly);
  worker->input()->setViewOnly(false); worker->setClipboardPolicy({false,true});
  EXPECT_EQ(worker->offerClipboard(1,"text").status,CommandAdmission::Disabled);
  worker->setClipboardPolicy({true,true});
  EXPECT_EQ(worker->offerClipboard(1,"too large").status,CommandAdmission::ResourceLimit);
  EXPECT_EQ(worker->offerClipboard(1,std::string("a\0b",3)).status,CommandAdmission::InvalidValue);
  auto retained = worker->clipboard()->prepareLocal(1,"12345678");
  EXPECT_EQ(worker->offerClipboard(1,"a").status,CommandAdmission::ResourceLimit);
  retained.text.reset();
  auto offer = worker->offerClipboard(1,"allowed");
  ASSERT_EQ(offer.status,CommandAdmission::Accepted);
  SessionEvent event; ASSERT_TRUE(completion(worker,offer.operation,event));
  worker->setClipboardPolicy({false,true});
  ASSERT_TRUE(until([&] { return worker->clipboard()->bytesInUse() == 0; }));
}

TEST(SessionWorker, ClipboardRetainedReceiveSurvivesReconnectAndSuppressesEcho)
{
  SessionRuntime runtime;
  auto worker = runtime.createSession(security()); auto channel = worker->clipboard();
  auto setup = prepared(); auto first = worker->connect(connection(setup));
  SessionEvent event; ASSERT_TRUE(completion(worker,first.operation,event));
  rdr::MemOutStream text;
  text.writeU8(3); text.pad(3); text.writeU32(6);
  text.writeBytes(reinterpret_cast<const uint8_t*>("remote"),6);
  setup->connected->feed({text.data(),text.data()+text.length()});
  ClipboardUpdate update;
  ASSERT_TRUE(until([&] { return channel->take(update) && update.text; }));
  auto retained = update.text;
  EXPECT_EQ(worker->offerClipboard(first.generation,retained->text(),retained).status,CommandAdmission::Echo);
  worker->setClipboardPolicy({false,true});
  auto disconnected = worker->disconnect(first.generation);
  ASSERT_TRUE(completion(worker,disconnected.operation,event));
  auto second = worker->connect(connection(prepared()));
  ASSERT_TRUE(completion(worker,second.operation,event));
  EXPECT_EQ(worker->clipboard(),channel); EXPECT_FALSE(channel->policy().send);
  EXPECT_EQ(retained->text(),"remote"); EXPECT_EQ(channel->bytesInUse(),6u);
  EXPECT_EQ(channel->check(retained->route(),false),ClipboardResult::Stale);
  worker->setClipboardPolicy({true,true});
  EXPECT_EQ(worker->offerClipboard(second.generation,retained->text(),retained).status,CommandAdmission::Echo);
  ASSERT_EQ(worker->closeAndDrain().wait_for(seconds(3)),std::future_status::ready);
  EXPECT_EQ(retained->text(),"remote");
}

TEST(SessionWorker, ClosingCancelsQueuedClipboardAndReleasesItsBudget)
{
  SessionRuntime runtime;
  auto probe = std::make_shared<Probe>(); probe->holdWorker = true;
  auto worker = runtime.start(transport(probe,wire()),"fixture",security());
  ReleaseWorker release{probe};
  ASSERT_TRUE(until([&] { return probe->workerWaiting.load(); }));
  auto offer = worker->offerClipboard(1,"queued",{},42);
  ASSERT_EQ(offer.status,CommandAdmission::Accepted);
  auto done = worker->closeAndDrain(); probe->releaseWorker();
  ASSERT_EQ(done.wait_for(seconds(3)),std::future_status::ready);
  SessionEvent event; ASSERT_TRUE(completion(worker,offer.operation,event));
  EXPECT_EQ(event.result,OperationResult::Cancelled); EXPECT_EQ(event.origin,42u);
  EXPECT_EQ(worker->clipboard()->bytesInUse(),0u);
  for (const auto& extra : takeEvents(worker->events())) EXPECT_NE(extra.kind,SessionEventKind::Completion);
}

TEST(SessionWorker, SecurityRevisionCompareAndReplaceIsAtomicAndRetainsOwnedSnapshots)
{
  SessionRuntime runtime;
  auto worker = runtime.createSession(security());
  const auto first = worker->securityOptions();
  (void)takeEvents(worker->events());
  EXPECT_TRUE(first.editable); EXPECT_EQ(first.revision,1u);
  rfb::ClientTLSOptions tls; tls.priority = "NORMAL"; tls.caFile = "/test/ca";
  rfb::SecurityClient updated({rfb::secTypeVncAuth},tls);
  std::array<CommandAdmission,8> results;
  std::vector<std::thread> callers;
  for (size_t i=0;i<results.size();++i) callers.emplace_back([&,i] {
    results[i] = worker->setSecurity(first.generation,first.revision,updated);
  });
  for (auto& caller : callers) caller.join();
  EXPECT_EQ(std::count(results.begin(),results.end(),CommandAdmission::Accepted),1);
  EXPECT_EQ(std::count(results.begin(),results.end(),CommandAdmission::StaleGeneration),7);
  const auto latest = worker->securityOptions();
  EXPECT_EQ(latest.revision,2u); EXPECT_EQ(latest.options->ToString(),"VncAuth");
  EXPECT_EQ(latest.options->clientTLSOptions().priority,"NORMAL");
  EXPECT_EQ(latest.options->clientTLSOptions().caFile,"/test/ca");
  EXPECT_EQ(first.options->ToString(),"None"); // Old lease is immutable.
  EXPECT_TRUE(takeEvents(worker->events()).empty()); // Synchronous update has no completion obligation.
  ASSERT_EQ(worker->closeAndDrain().wait_for(seconds(3)),std::future_status::ready);
  EXPECT_EQ(worker->setSecurity(latest.generation,latest.revision,security()),CommandAdmission::Closing);
}
TEST(SessionWorker, SecurityChangesReachOnlyNextAttemptAndRejectActiveOrStaleEdits)
{
  SessionRuntime runtime;
  auto worker = runtime.createSession(security());
  const auto initial = worker->securityOptions();
  auto first = worker->connect(connection(prepared())); SessionEvent event;
  ASSERT_TRUE(completion(worker,first.operation,event)); ASSERT_EQ(event.result,OperationResult::Succeeded);
  const auto active = worker->securityOptions(); EXPECT_FALSE(active.editable);
  EXPECT_EQ(worker->setSecurity(active.generation,active.revision,rfb::SecurityClient(std::list<uint32_t>{})),CommandAdmission::Busy);
  auto disconnected = worker->disconnect(first.generation);
  ASSERT_TRUE(completion(worker,disconnected.operation,event));
  const auto idle = worker->securityOptions(); EXPECT_TRUE(idle.editable);
  EXPECT_EQ(worker->setSecurity(initial.generation,initial.revision,security()),CommandAdmission::StaleGeneration);
  EXPECT_EQ(worker->setSecurity(idle.generation,idle.revision,rfb::SecurityClient({rfb::secTypeVncAuth})),CommandAdmission::Accepted);
  auto denied = worker->connect(connection(prepared()));
  ASSERT_TRUE(completion(worker,denied.operation,event)); EXPECT_EQ(event.result,OperationResult::Failed);
  EXPECT_EQ(event.snapshot.endReason,SessionEndReason::ProtocolFailure);
  const auto failed = worker->securityOptions(); EXPECT_TRUE(failed.editable);
  EXPECT_EQ(worker->setSecurity(failed.generation,failed.revision,security()),CommandAdmission::Accepted);
  auto next = worker->connect(connection(prepared()));
  ASSERT_TRUE(completion(worker,next.operation,event)); EXPECT_EQ(event.result,OperationResult::Succeeded);
  ASSERT_EQ(worker->closeAndDrain().wait_for(seconds(3)),std::future_status::ready);
}

TEST(SessionWorker, SharedFlagRevisionAndAttemptAdmissionAreAtomic)
{
  SessionRuntime runtime; auto worker = runtime.createSession(security());
  const auto first = worker->sharing(); EXPECT_FALSE(first.shared); EXPECT_TRUE(first.editable);
  std::array<CommandAdmission,8> results;
  std::vector<std::thread> callers;
  for (size_t i=0;i<results.size();++i) callers.emplace_back([&,i] { results[i] = worker->setShared(first.generation,first.revision,true); });
  for (auto& caller : callers) caller.join();
  EXPECT_EQ(std::count(results.begin(),results.end(),CommandAdmission::Accepted),1);
  EXPECT_EQ(std::count(results.begin(),results.end(),CommandAdmission::StaleGeneration),7);
  auto accepted = worker->connect(connection(prepared())); SessionEvent event;
  ASSERT_TRUE(completion(worker,accepted.operation,event)); ASSERT_EQ(event.result,OperationResult::Succeeded);
  const auto active = worker->sharing(); EXPECT_TRUE(active.shared); EXPECT_FALSE(active.editable);
  EXPECT_EQ(worker->setShared(active.generation,active.revision,false),CommandAdmission::Busy);
  auto disconnected = worker->disconnect(accepted.generation); ASSERT_TRUE(completion(worker,disconnected.operation,event));
  EXPECT_EQ(worker->setShared(first.generation,active.revision,false),CommandAdmission::StaleGeneration);
  auto idle = worker->sharing(); EXPECT_EQ(worker->setShared(idle.generation,idle.revision,false),CommandAdmission::Accepted);
  EXPECT_FALSE(worker->sharing().shared);
  ASSERT_EQ(worker->closeAndDrain().wait_for(seconds(3)),std::future_status::ready);
  idle = worker->sharing(); EXPECT_EQ(worker->setShared(idle.generation,idle.revision,true),CommandAdmission::Closing);
}

namespace {
bool contains(const std::shared_ptr<Probe>& probe, const std::vector<uint8_t>& needle)
{
  std::lock_guard<std::mutex> lock(probe->mutex);
  return std::search(probe->output.begin(), probe->output.end(), needle.begin(), needle.end()) != probe->output.end();
}
std::vector<uint8_t> bytes(const std::string& text) { return {text.begin(), text.end()}; }
}

// N1.14: two simultaneous sessions with different security and encoding settings.
// One stays parked at its credential prompt while the other connects, receives a
// frame, holds a modifier, sends clipboard text and changes its encoding. Nothing
// crosses sessions: secrets, prompts, held input, clipboard or settings.
TEST(SessionWorker, SimultaneousSessionsIsolatePromptSecretInputClipboardAndSettings)
{
  SessionRuntime runtime;
  SessionWorkerOptions parkedOptions;
  parkedOptions.encoding = EncodingOptions().withPatch({{"QualityLevel", "2"}}, OptionSource::Session);
  auto parkedProbe = std::make_shared<Probe>();
  auto parked = runtime.start(transport(parkedProbe, wire(true)), "parked", security(true), parkedOptions);
  AuthenticationPrompt prompt;
  ASSERT_TRUE(until([&] { return parked->authentication()->takeRequest(prompt); }));
  size_t parkedBefore;
  { std::lock_guard<std::mutex> lock(parkedProbe->mutex); parkedBefore = parkedProbe->output.size(); }

  auto liveProbe = std::make_shared<Probe>();
  auto live = runtime.start(transport(liveProbe, wire(false, true)), "live", security());
  ASSERT_TRUE(until([&] { return live->events()->snapshot().frames == 1; }));
  const auto generation = live->events()->snapshot().generation;

  // Held modifier and clipboard on the live session only.
  ASSERT_EQ(live->input()->key(generation, 7, 0xffe3, 0, true), InputResult::Accepted); // Control_L
  live->wake();
  const std::vector<uint8_t> controlDown{4, 1, 0, 0, 0x00, 0x00, 0xff, 0xe3};
  ASSERT_TRUE(until([&] { return contains(liveProbe, controlDown); }));
  auto offer = live->offerClipboard(generation, "live clipboard");
  ASSERT_EQ(offer.status, CommandAdmission::Accepted);
  SessionEvent event; ASSERT_TRUE(completion(live, offer.operation, event));
  EXPECT_EQ(event.result, OperationResult::Succeeded);
  auto changed = live->applyEncodingOptions(generation,
    live->encodingOptions().withPatch({{"QualityLevel", "9"}}, OptionSource::Session));
  ASSERT_EQ(changed.status, CommandAdmission::Accepted);
  ASSERT_TRUE(completion(live, changed.operation, event));

  // The parked session saw none of it and still waits, with its own settings.
  EXPECT_EQ(parked->events()->snapshot().state, SessionState::Authenticating);
  EXPECT_EQ(parked->events()->snapshot().frames, 0u);
  EXPECT_EQ(parked->encodingOptions().value(EncodingOption::QualityLevel), "2");
  EXPECT_EQ(live->encodingOptions().value(EncodingOption::QualityLevel), "9");
  EXPECT_NE(parked->securityOptions().options, live->securityOptions().options);
  EXPECT_EQ(parked->input()->status().queued, 0u);
  EXPECT_FALSE(parked->input()->status().releasePending);
  { std::lock_guard<std::mutex> lock(parkedProbe->mutex); EXPECT_EQ(parkedProbe->output.size(), parkedBefore); }
  EXPECT_FALSE(contains(parkedProbe, bytes("live clipboard")));
  EXPECT_FALSE(contains(parkedProbe, controlDown));
  EXPECT_EQ(parked->clipboard()->bytesInUse(), 0u);

  // Prompts are session-scoped: the live session cannot answer the parked one.
  AuthenticationPrompt none;
  EXPECT_FALSE(live->authentication()->takeRequest(none));
  EXPECT_EQ(live->authentication()->replyCredentials(prompt.id, prompt.generation, "", "wrong session"),
            PromptReply::NoPendingRequest);
  EXPECT_EQ(parked->events()->snapshot().state, SessionState::Authenticating);

  // Answering the parked prompt sends only a VNC challenge response on its own
  // transport; the secret's plaintext reaches neither wire.
  const std::string secret = "parked-secret";
  EXPECT_EQ(parked->authentication()->replyCredentials(prompt.id, prompt.generation, "", secret),
            PromptReply::Accepted);
  // The whole parked transcript is version, VncAuth selection and the 16-byte
  // challenge response; the client may batch these into one flush.
  const size_t transcript = 12 + 1 + 16;
  ASSERT_TRUE(until([&] {
    std::lock_guard<std::mutex> lock(parkedProbe->mutex); return parkedProbe->output.size() == transcript;
  }));
  {
    std::lock_guard<std::mutex> lock(parkedProbe->mutex);
    EXPECT_TRUE(std::equal(parkedProbe->output.begin(), parkedProbe->output.begin() + 12,
                           reinterpret_cast<const uint8_t*>("RFB 003.008\n")));
    EXPECT_EQ(parkedProbe->output[12], rfb::secTypeVncAuth);
  }
  EXPECT_FALSE(contains(parkedProbe, bytes(secret)));
  EXPECT_FALSE(contains(liveProbe, bytes(secret)));
  EXPECT_FALSE(contains(liveProbe, bytes("parked")));

  // Closing the live session releases its held key there, not on the parked one.
  const std::vector<uint8_t> controlUp{4, 0, 0, 0, 0x00, 0x00, 0xff, 0xe3};
  ASSERT_EQ(live->closeAndDrain().wait_for(seconds(3)), std::future_status::ready);
  EXPECT_TRUE(contains(liveProbe, controlUp));
  EXPECT_FALSE(contains(parkedProbe, controlUp));
  EXPECT_EQ(parked->drained().wait_for(milliseconds(1)), std::future_status::timeout);
  parked->closeAndDrain(); runtime.shutdown();
  ASSERT_EQ(runtime.drained().wait_for(seconds(3)), std::future_status::ready);
}

namespace {
struct CountingWakeup : MailboxWakeup {
  void wake() noexcept override { ++count; }
  std::atomic<uint64_t> count{0};
};
}

// N5.10: many reconnect cycles with a slow view consumer that keeps a few old
// leases, a held key at every disconnect and a two-frame publication budget.
TEST(SessionWorker, ReconnectCyclesWithSlowConsumerStayBoundedAndCurrent)
{
  SessionRuntime runtime;
  auto wakeup = std::make_shared<CountingWakeup>();
  SessionWorkerOptions options; options.buffers.publicationBytes = 32; options.mailboxWakeup = wakeup;
  auto session = runtime.createSession(security(), options);
  std::vector<FrameLease> retained;
  uint64_t lastGeneration = 0;
  for (int cycle = 0; cycle < 50; ++cycle) {
    auto attempt = session->connect(connection(prepared(true)));
    ASSERT_EQ(attempt.status, CommandAdmission::Accepted) << cycle;
    SessionEvent event; ASSERT_TRUE(completion(session, attempt.operation, event)) << cycle;
    EXPECT_GT(attempt.generation, lastGeneration); lastGeneration = attempt.generation;
    ASSERT_TRUE(until([&] { return session->events()->snapshot().frames == 1; })) << cycle;
    // Nothing from an earlier attempt is delivered once this one has connected.
    while (session->events()->take(event)) EXPECT_GE(event.snapshot.generation, attempt.generation);
    if (cycle % 3 == 0) {
      ViewUpdate update;
      ASSERT_TRUE(until([&] { return session->view()->take(update) && update.frame; })) << cycle;
      EXPECT_EQ(update.generation, attempt.generation);
      retained.push_back(update.frame);
      if (retained.size() > 1) retained.erase(retained.begin()); // keep at most one old lease
    }
    ASSERT_EQ(session->input()->key(attempt.generation, 7, 'a', 0, true), InputResult::Accepted);
    session->wake();
    auto closed = session->disconnect(attempt.generation);
    ASSERT_EQ(closed.status, CommandAdmission::Accepted) << cycle;
    ASSERT_TRUE(completion(session, closed.operation, event)) << cycle;
    EXPECT_NE(session->input()->key(attempt.generation, 7, 'a', 0, false), InputResult::Accepted);
    EXPECT_EQ(session->input()->status().queued, 0u);
  }
  // Releasing the old leases returns their budget: a new attempt still publishes.
  retained.clear();
  auto last = session->connect(connection(prepared(true)));
  SessionEvent event; ASSERT_TRUE(completion(session, last.operation, event));
  ViewUpdate update;
  ASSERT_TRUE(until([&] { return session->view()->take(update) && update.frame; }));
  EXPECT_EQ(update.generation, last.generation);
  EXPECT_FALSE(session->input()->status().releasePending);
  update = {};
  ASSERT_EQ(session->closeAndDrain().wait_for(seconds(3)), std::future_status::ready);
  runtime.shutdown();
  ASSERT_EQ(runtime.drained().wait_for(seconds(3)), std::future_status::ready);
  // After joined drain no further mailbox wake-ups arrive.
  const auto settled = wakeup->count.load();
  std::this_thread::sleep_for(milliseconds(50));
  EXPECT_EQ(wakeup->count.load(), settled);
  EXPECT_GT(settled, 0u);
}
