/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "ListenerWorker.h"
#include <algorithm>
#include <array>
#include <condition_variable>
#include <limits>
#include <list>
#include <mutex>
#include <thread>
namespace viewer {
struct ListenerEvents::Impl {
  explicit Impl(size_t capacity_) : capacity(capacity_) { queue.reserve(capacity+2); publish(ListenerEventKind::State,{}); }
  void publish(ListenerEventKind kind, std::shared_ptr<const IncomingPeer> peer) {
    ListenerEvent event; event.sequence = ++sequence; event.kind = kind;
    event.snapshot = snapshot; event.peer = std::move(peer); queue.push_back(std::move(event));
  }
  const size_t capacity;
  mutable std::mutex mutex;
  ListenerSnapshot snapshot;
  std::vector<ListenerEvent> queue;
  uint64_t sequence = 0;
};
ListenerEvents::ListenerEvents(size_t capacity) : impl(new Impl(capacity)) {}
ListenerEvents::~ListenerEvents() = default;
ListenerSnapshot ListenerEvents::snapshot() const { std::lock_guard<std::mutex> lock(impl->mutex); return impl->snapshot; }
bool ListenerEvents::take(ListenerEvent& event) {
  ListenerEvent next;
  {
    std::lock_guard<std::mutex> lock(impl->mutex);
    if (impl->queue.empty()) return false;
    next = std::move(impl->queue.front()); impl->queue.erase(impl->queue.begin());
  }
  // Replacing a caller's previous output may invoke its custom deleter.
  event = std::move(next); return true;
}
struct ListenerWorker::State {
  using Clock = SessionTransport::Clock;
  struct Pending {
    std::shared_ptr<const IncomingPeer> peer;
    std::unique_ptr<SessionTransport> transport;
    Clock::time_point expires;
  };
  State(std::unique_ptr<ListenerSource> source_, ListenerOptions options_)
    : source(std::move(source_)), options(options_), done(completion.get_future().share()) {
    if (!source || !options.pendingCapacity || options.pendingCapacity > 64 || options.eventCapacity < 4 ||
        options.eventCapacity > 4096 || options.pendingTimeout.count() < 1 || options.pendingTimeout.count() > 60000)
      throw std::invalid_argument("Invalid listener construction");
    control = source->control();
    if (!control) throw std::invalid_argument("Missing listener control");
    events.reset(new ListenerEvents(options.eventCapacity)); pending.reserve(options.pendingCapacity);
  }
  bool emit(ListenerEventKind kind, const std::shared_ptr<const IncomingPeer>& peer = {}) {
    auto& stream = *events->impl;
    if (stream.queue.size() >= stream.capacity || stream.sequence >= std::numeric_limits<uint64_t>::max()-2) {
      failure = ListenerErrorCode::EventOverflow; stopping = true; return false;
    }
    stream.snapshot.pending = pending.size(); stream.publish(kind,peer); return true;
  }
  void notify() noexcept { if (options.mailboxWakeup) options.mailboxWakeup->wake(); }
  void cancel() noexcept {
    { std::lock_guard<std::mutex> lock(events->impl->mutex); stopping = true; }
    control->cancel(); changed.notify_all();
  }
  AcceptedPeer consume(uint64_t id, bool accept) {
    AcceptedPeer result;
    {
      std::lock_guard<std::mutex> lock(events->impl->mutex);
      if (stopping) { result.status = PeerAdmission::Closing; return result; }
      auto found = std::find_if(pending.begin(),pending.end(),[&](const Pending& peer) { return peer.peer->id == id; });
      if (found == pending.end()) return result;
      const bool expired = Clock::now() >= found->expires;
      auto peer = found->peer;
      // Reserve event delivery before transferring ownership or closing a peer.
      if (events->impl->queue.size() >= events->impl->capacity ||
          events->impl->sequence >= std::numeric_limits<uint64_t>::max()-2) {
        failure = ListenerErrorCode::EventOverflow; stopping = true;
        result.status = PeerAdmission::EventCapacity;
      } else {
        result.peer = peer; result.transport = std::move(found->transport); pending.erase(found);
        emit(expired ? ListenerEventKind::Expired : accept ? ListenerEventKind::Accepted : ListenerEventKind::Rejected,peer);
        result.status = expired ? PeerAdmission::Expired : PeerAdmission::Accepted;
      }
    }
    control->wake(); changed.notify_all(); notify();
    if (!accept || result.status != PeerAdmission::Accepted) result.transport.reset();
    return result;
  }
  void run() noexcept {
    try {
      auto addresses = source->start();
      if (addresses.empty() || addresses.size() > 2) throw std::runtime_error("Invalid listener endpoints");
      for (const auto& address : addresses)
        if (address.host.empty() || address.host.size() > 255 || address.host.find('\0') != std::string::npos || !address.port)
          throw std::runtime_error("Invalid listener endpoint");
      auto owned = std::make_shared<const std::vector<ListenerAddress>>(std::move(addresses));
      {
        std::lock_guard<std::mutex> lock(events->impl->mutex);
        if (!stopping) {
          events->impl->snapshot.addresses = std::move(owned);
          events->impl->snapshot.state = ListenerState::Listening; emit(ListenerEventKind::State);
        }
      }
      notify();
      for (;;) {
        auto deadline = Clock::time_point::max(); std::unique_ptr<SessionTransport> expired;
        {
          std::unique_lock<std::mutex> lock(events->impl->mutex);
          if (stopping) break;
          if (!pending.empty()) deadline = pending.front().expires;
          if (Clock::now() >= deadline) {
            auto peer = pending.front().peer; expired = std::move(pending.front().transport); pending.erase(pending.begin());
            emit(ListenerEventKind::Expired,peer);
          } else if (pending.size() == options.pendingCapacity) {
            changed.wait_until(lock,deadline); continue;
          }
        }
        if (expired) { notify(); continue; } // Close outside locks before waiting for another peer.
        auto incoming = source->wait(deadline);
        if (!incoming) continue;
        if (!incoming->transport || incoming->peer.host.empty() || incoming->peer.host.size() > 255 ||
            incoming->peer.host.find('\0') != std::string::npos)
          throw std::runtime_error("Invalid incoming transport");
        auto peer = std::make_shared<IncomingPeer>(); peer->address = std::move(incoming->peer);
        {
          std::lock_guard<std::mutex> lock(events->impl->mutex);
          if (stopping) break;
          if (nextId == std::numeric_limits<uint64_t>::max()) throw std::overflow_error("Incoming ID exhausted");
          peer->id = ++nextId;
          pending.push_back({peer,std::move(incoming->transport),Clock::now()+options.pendingTimeout});
          emit(ListenerEventKind::Incoming,peer);
        }
        notify();
      }
    } catch (const ListenerError& error) {
      std::lock_guard<std::mutex> lock(events->impl->mutex);
      if (!stopping) {
        if (failure == ListenerErrorCode::None) { failure = error.code; nativeError = error.nativeError; }
      }
    } catch (...) {
      std::lock_guard<std::mutex> lock(events->impl->mutex);
      if (!stopping && failure == ListenerErrorCode::None) failure = ListenerErrorCode::Internal;
    }
    std::vector<Pending> retired;
    {
      std::lock_guard<std::mutex> lock(events->impl->mutex);
      stopping = true; auto& stream = *events->impl;
      stream.snapshot.state = ListenerState::Stopping;
      stream.snapshot.pending = pending.size();
      stream.publish(ListenerEventKind::State,{}); pending.swap(retired); stream.snapshot.pending = 0;
    }
    notify();
    retired.clear(); source.reset(); // Unclaimed peers and listening sockets are worker-owned until disposal.
    {
      std::lock_guard<std::mutex> lock(events->impl->mutex);
      auto& stream = *events->impl;
      stream.snapshot.state = failure == ListenerErrorCode::None ? ListenerState::Closed : ListenerState::Failed;
      stream.snapshot.error = failure; stream.snapshot.nativeError = nativeError;
      stream.publish(ListenerEventKind::State,{}); terminalResult = stream.snapshot;
    }
    notify();
  }
  std::unique_ptr<ListenerSource> source;
  const ListenerOptions options;
  std::shared_ptr<TransportControl> control;
  std::shared_ptr<ListenerEvents> events;
  std::condition_variable changed;
  std::vector<Pending> pending;
  uint64_t nextId = 0;
  bool stopping = false;
  ListenerErrorCode failure = ListenerErrorCode::None;
  int nativeError = 0;
  ListenerSnapshot terminalResult;
  std::promise<ListenerSnapshot> completion;
  const std::shared_future<ListenerSnapshot> done;
};
struct ListenerRuntime::Impl {
  struct Job { std::shared_ptr<ListenerWorker::State> state; std::thread thread; bool finished = false; };
  explicit Impl(size_t capacity_) : capacity(capacity_), done(completion.get_future().share()) {
    if (!capacity || capacity > 16) throw std::invalid_argument("Invalid listener capacity");
    coordinator = std::thread([this] { reap(); });
  }
  void reap() {
    std::unique_lock<std::mutex> lock(mutex);
    for (;;) {
      auto ready = std::find_if(jobs.begin(),jobs.end(),[](const Job& job) { return job.finished; });
      if (ready == jobs.end()) { if (stopping && !admitted) break; changed.wait(lock); continue; }
      std::list<Job> retired; retired.splice(retired.end(),jobs,ready); lock.unlock();
      auto& job = retired.front(); job.thread.join();
      lock.lock(); --admitted; lock.unlock();
      job.state->completion.set_value(job.state->terminalResult); retired.clear(); lock.lock();
    }
    lock.unlock(); completion.set_value();
  }
  const size_t capacity;
  mutable std::mutex mutex;
  std::condition_variable changed;
  std::list<Job> jobs;
  size_t admitted = 0;
  bool stopping = false;
  std::promise<void> completion;
  const std::shared_future<void> done;
  std::thread coordinator;
};
ListenerWorker::ListenerWorker(std::shared_ptr<State> state_) : state(std::move(state_)) {}
ListenerWorker::~ListenerWorker() { state->cancel(); }
std::shared_ptr<ListenerEvents> ListenerWorker::events() const { return state->events; }
AcceptedPeer ListenerWorker::takePeer(uint64_t id) { return state->consume(id,true); }
PeerAdmission ListenerWorker::reject(uint64_t id) { return state->consume(id,false).status; }
std::shared_ptr<SessionWorker> ListenerWorker::accept(uint64_t id, SessionRuntime& runtime,
  const rfb::SecurityClient& security, const SessionWorkerOptions& options) {
  auto peer = takePeer(id);
  if (peer.status != PeerAdmission::Accepted) return {};
  auto identity = peer.peer->address.host;
  // An IPv6 interface scope identifies routing, not the certificate hostname.
  const auto scope = identity.find('%');
  if (identity.find(':') != std::string::npos && scope != std::string::npos) identity.resize(scope);
  return runtime.start(std::move(peer.transport),identity,security,options);
}
std::shared_future<ListenerSnapshot> ListenerWorker::closeAndDrain() noexcept { state->cancel(); return state->done; }
std::shared_future<ListenerSnapshot> ListenerWorker::drained() const { return state->done; }
ListenerRuntime::ListenerRuntime(size_t capacity) : impl(new Impl(capacity)) {}
ListenerRuntime::~ListenerRuntime() { shutdown(); impl->coordinator.join(); }
std::shared_ptr<ListenerWorker> ListenerRuntime::listen(std::unique_ptr<ListenerSource> source,const ListenerOptions& options) {
  auto state = std::make_shared<ListenerWorker::State>(std::move(source),options);
  auto handle = std::shared_ptr<ListenerWorker>(new ListenerWorker(state));
  std::list<Impl::Job> pending; pending.emplace_back(); auto& job = pending.front(); job.state = state;
  {
    std::lock_guard<std::mutex> lock(impl->mutex);
    if (impl->stopping) throw std::logic_error("Listener runtime is shut down");
    if (impl->admitted == impl->capacity) throw std::length_error("Listener runtime is full");
    auto* runtime = impl.get(); auto* entry = &job;
    job.thread = std::thread([state,runtime,entry] {
      state->run();
      { std::lock_guard<std::mutex> done(runtime->mutex); entry->finished = true; }
      runtime->changed.notify_one();
    });
    impl->jobs.splice(impl->jobs.end(),pending); ++impl->admitted;
  }
  return handle;
}
void ListenerRuntime::shutdown() noexcept {
  std::array<std::shared_ptr<ListenerWorker::State>,16> active; size_t count = 0;
  {
    std::lock_guard<std::mutex> lock(impl->mutex); impl->stopping = true;
    for (auto& job : impl->jobs) active[count++] = job.state;
  }
  for (size_t i = 0; i < count; ++i) active[i]->cancel();
  impl->changed.notify_one();
}
std::shared_future<void> ListenerRuntime::drained() const { return impl->done; }
size_t ListenerRuntime::active() const { std::lock_guard<std::mutex> lock(impl->mutex); return impl->admitted; }
}
