/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <viewer/core/SessionWorker.h>
#include <core/Exception.h>
#include <rdr/InStream.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <list>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <system_error>
#include <thread>
#include <type_traits>
#include <vector>

namespace viewer {
namespace {
// Stable cancellation/wakeup identity across the setup -> connected handoff.
// No virtual control call or disposal occurs under this mutex.
class WakeRouter final : public SchedulerWakeup {
public:
  void install(std::shared_ptr<TransportControl> next) {
    std::shared_ptr<TransportControl> old;
    { std::lock_guard<std::mutex> lock(mutex); old = std::move(target); target = std::move(next); }
  }
  void wake() noexcept override {
    std::shared_ptr<TransportControl> current;
    { std::lock_guard<std::mutex> lock(mutex); current = target; }
    if (current) current->wake();
  }
private:
  std::mutex mutex;
  std::shared_ptr<TransportControl> target;
};
class WorkerControl final : public TransportControl {
public:
  WorkerControl(std::shared_ptr<TransportControl> target_, bool connecting_)
    : target(std::move(target_)), connecting(connecting_)
  {
    if (!target) throw std::invalid_argument("Connection has no cancellation control");
  }
  void install(std::shared_ptr<TransportControl> next)
  {
    if (!next) throw std::invalid_argument("Transport has no cancellation control");
    std::shared_ptr<TransportControl> old;
    bool stop, close;
    {
      std::lock_guard<std::mutex> lock(mutex);
      old = std::move(target); target = next; connecting = false;
      stop = stopped; close = closing;
    }
    if (stop) next->cancel(); else if (close) next->wake();
  }
  void wake() noexcept override
  {
    std::shared_ptr<TransportControl> current;
    { std::lock_guard<std::mutex> lock(mutex); current = target; }
    current->wake();
  }
  void cancel() noexcept override
  {
    std::shared_ptr<TransportControl> current;
    { std::lock_guard<std::mutex> lock(mutex); stopped = true; current = target; }
    current->cancel();
  }
  void requestClose() noexcept
  {
    std::shared_ptr<TransportControl> current;
    bool setup;
    {
      std::lock_guard<std::mutex> lock(mutex);
      closing = true; setup = connecting; current = target;
    }
    if (setup) current->cancel(); else current->wake();
  }
private:
  std::mutex mutex;
  std::shared_ptr<TransportControl> target;
  bool connecting, closing = false, stopped = false;
};
}
struct SessionWorker::State {
  enum class CommandKind { Refresh, Encoding, DesktopLayout, ClipboardOffer, ClipboardClear };
  struct Command {
    CommandKind kind;
    uint64_t operation;
    EncodingOptions options;
    std::shared_ptr<const RemoteDesktopLayout> layout;
    ClipboardLease text;
  };
  static_assert(std::is_nothrow_copy_constructible<Command>::value &&
                std::is_nothrow_copy_assignable<Command>::value,
                "Reserved command admission must not allocate or throw");
  State(std::unique_ptr<SessionTransport> transport_, std::unique_ptr<ConnectionAttempt> connection_,
        const std::string& serverName_,
        const rfb::SecurityClient& security, const SessionWorkerOptions& options, bool reusable_ = false)
    : reusable(reusable_), transport(std::move(transport_)), connection(std::move(connection_)), serverName(serverName_),
      commandCapacity(options.commandCapacity), framebufferLimit(options.buffers.framebufferBytes),
      currentEncoding(options.encoding), currentSecurity(std::make_shared<const rfb::SecurityClient>(security)), currentShared(options.shared),
      done(completion.get_future().share())
  {
    if ((!reusable && bool(transport) == bool(connection)) ||
        (reusable && (transport || connection)) || serverName.size() > 4096 || serverName.find('\0') != std::string::npos)
      throw std::invalid_argument("Invalid worker transport or server name");
    if (!commandCapacity || commandCapacity > 256)
      throw std::invalid_argument("Invalid worker command capacity");
    commands.reserve(commandCapacity);
    if (!reusable)
      control = std::make_shared<WorkerControl>(connection ? connection->control() : transport->control(), bool(connection));
    wakeup = std::make_shared<WakeRouter>();
    wakeup->install(control);
    mailboxWakeup = options.mailboxWakeup;
    const auto ready = options.promptReady;
    const auto mailbox = mailboxWakeup;
    auth = std::make_shared<PromptAuthentication>([ready, mailbox] {
      if (auto target = mailbox.lock()) target->wake();
      if (ready) ready();
    }, options.promptTimeout);
    SessionTiming timing;
    timing.statisticsInterval = options.statisticsInterval;
    timing.publicationRetryInterval = options.publicationRetryInterval;
    timing.desktopResizeTimeout = options.desktopResizeTimeout;
    timing.pointerEventInterval = options.pointerEventInterval;
    timing.wakeup = wakeup;
    protocol.reset(new ProtocolSession(security, options.messages, options.buffers,
                                      auth, options.encoding, timing, SessionTerminalOwnership::Host, options.clipboard, options.shared));
    // Construction precedes thread publication; these become worker-owned when
    // admitted. Consumers only receive the independently synchronized mailboxes.
    events = protocol->subscribeEvents(options.eventCapacity);
    view = protocol->attachView();
    events->setWakeup(mailboxWakeup);
    view->setWakeup(mailboxWakeup);
    input = protocol->inputQueue();
    clipboard = protocol->clipboard();
    clipboard->setWakeup(mailboxWakeup);
  }
  void cancel() noexcept
  {
    std::shared_ptr<WorkerControl> current;
    {
      std::lock_guard<std::mutex> lock(commandMutex);
      stopping = true;
      if (!finishing) {
        commandsClosed = true;
        cancelled.store(true);
        finishQueued(OperationResult::Cancelled);
        current = control;
      }
    }
    auth->cancelPending();
    // Capture the attempt's control under the admission gate. A delayed caller
    // must never cancel a later generation's socket after reconnect.
    if (current) current->requestClose();
    changed.notify_one();
  }
  CommandSubmission connect(std::unique_ptr<ConnectionAttempt> next)
  {
    if (!next) throw std::invalid_argument("Missing connection attempt");
    auto name = next->serverName();
    if (name.size() > 4096 || name.find('\0') != std::string::npos)
      throw std::invalid_argument("Invalid connection server name");
    auto nextControl = std::make_shared<WorkerControl>(next->control(), true);
    CommandSubmission accepted{CommandAdmission::Accepted};
    {
      std::lock_guard<std::mutex> lock(commandMutex);
      if (!reusable) return {CommandAdmission::Unsupported};
      if (stopping || events->sealed()) return {CommandAdmission::Closing};
      if (attemptActive) return {CommandAdmission::Busy};
      const auto previous = std::max(events->snapshot().generation, attemptGeneration);
      if (previous >= std::numeric_limits<uint64_t>::max() - 1)
        return {CommandAdmission::GenerationExhausted};
      const auto generation = previous + 1;
      const auto operation = events->reserveAttempt(generation);
      if (!operation) return {CommandAdmission::EventCapacity};
      // All remaining assignments are nonthrowing. No admitted operation can
      // disappear due to allocation failure. Previous resources are already gone.
      connection = std::move(next); serverName = std::move(name);
      control = std::move(nextControl);
      connectOperation = operation; attemptGeneration = generation;
      cancelled.store(false); peerClosed.store(false); observerFailed.store(false);
      observerError.store(0); result = WorkerResult();
      finishing = commandsClosed = false;
      attemptActive = pendingAttempt = true;
      accepted = {CommandAdmission::Accepted, operation, generation};
    }
    changed.notify_one();
    return accepted;
  }
  CommandSubmission disconnect(uint64_t generation)
  {
    std::shared_ptr<WorkerControl> current;
    uint64_t operation;
    {
      std::lock_guard<std::mutex> lock(commandMutex);
      if (!reusable) return {CommandAdmission::Unsupported};
      if (stopping || events->sealed()) return {CommandAdmission::Closing};
      if (generation != attemptGeneration) return {CommandAdmission::StaleGeneration};
      if (!attemptActive) return {CommandAdmission::NotConnected};
      if (finishing || cancelled.load()) return {CommandAdmission::Closing};
      operation = events->reserve(generation);
      if (!operation) return {CommandAdmission::EventCapacity};
      disconnectOperation = operation;
      commandsClosed = true; cancelled.store(true);
      finishQueued(OperationResult::Cancelled);
      current = control;
    }
    auth->cancelAttempt(generation);
    current->requestClose();
    return {CommandAdmission::Accepted, operation, generation};
  }
  // commandMutex held; fixed-size values and preallocated event reservations.
  void finishQueued(OperationResult status)
  {
    for (const auto& command : commands) events->complete(command.operation, status);
    commands.clear();
    layoutQueued = 0;
    clipboardQueued = 0;
  }
  CommandSubmission submit(CommandKind kind, uint64_t generation, const EncodingOptions* options,
                           std::shared_ptr<const RemoteDesktopLayout> layout = nullptr, uint64_t origin = 0,
                           ClipboardLease text = {})
  {
    std::lock_guard<std::mutex> lock(commandMutex);
    if (commandsClosed || events->sealed()) return {CommandAdmission::Closing, 0};
    const auto snapshot = events->snapshot();
    if (generation != (reusable && attemptActive ? attemptGeneration : snapshot.generation))
      return {CommandAdmission::StaleGeneration, 0};
    if (snapshot.state != SessionState::Connected) return {CommandAdmission::NotConnected, 0};
    if (kind == CommandKind::ClipboardOffer || kind == CommandKind::ClipboardClear) {
      if (clipboardQueued) return {CommandAdmission::Busy};
      if (kind == CommandKind::ClipboardOffer && clipboard->check(text->route(),true) != ClipboardResult::Accepted)
        return {CommandAdmission::StaleGeneration};
    }
    if (kind == CommandKind::DesktopLayout) {
      if (input->status().viewOnly) return {CommandAdmission::ViewOnly};
      if (!snapshot.supportsDesktopResize) return {CommandAdmission::Unsupported};
      if (layoutQueued || snapshot.resizePending) return {CommandAdmission::Busy};
      if (size_t(layout->width()) > size_t(std::numeric_limits<int>::max()) / 4 / layout->height() ||
          size_t(layout->width()) * 4 > framebufferLimit / layout->height())
        return {CommandAdmission::ResourceLimit};
    }
    if (commands.size() == commandCapacity) return {CommandAdmission::QueueFull, 0};
    const auto id = events->reserve(generation, origin);
    if (!id) return {CommandAdmission::EventCapacity, 0};
    commands.push_back({kind, id, options ? *options : currentEncoding, std::move(layout), std::move(text)});
    if (kind == CommandKind::DesktopLayout) layoutQueued = id;
    if (kind == CommandKind::ClipboardOffer || kind == CommandKind::ClipboardClear) clipboardQueued = id;
    return {CommandAdmission::Accepted, id, generation};
  }
  CommandCancellation cancelCommand(uint64_t generation, uint64_t id)
  {
    std::shared_ptr<WorkerControl> current;
    {
      std::lock_guard<std::mutex> lock(commandMutex);
      if (reusable && attemptActive && generation == attemptGeneration && id == connectOperation) {
        if (finishing || cancelled.load() || !events->pending(id, generation))
          return CommandCancellation::NotPending;
        cancelled.store(true); commandsClosed = true;
        finishQueued(OperationResult::Cancelled);
        current = control;
      } else {
        if (generation != (reusable && attemptActive ? attemptGeneration : events->snapshot().generation))
          return CommandCancellation::StaleGeneration;
        const auto found = std::find_if(commands.begin(), commands.end(),
          [&](const Command& command) { return command.operation == id; });
        if (found == commands.end()) return CommandCancellation::NotPending;
        const bool completed = events->complete(id, OperationResult::Cancelled);
        if (layoutQueued == id) layoutQueued = 0;
        if (clipboardQueued == id) clipboardQueued = 0;
        commands.erase(found);
        return completed ? CommandCancellation::Cancelled : CommandCancellation::NotPending;
      }
    }
    auth->cancelAttempt(generation);
    current->requestClose();
    return CommandCancellation::Cancelled;
  }
  void drainCommands()
  {
    // Copy the current snapshot outside any protocol call. EncodingOptions is a
    // fixed-size value; no default construction/validation/allocation under locks.
    Command command{CommandKind::Refresh, 0, encoding(), nullptr, {}};
    for (size_t count = 0; count < commandCapacity; ++count) {
      {
        std::lock_guard<std::mutex> lock(commandMutex);
        if (commandsClosed || commands.empty()) return;
        command = commands.front(); commands.erase(commands.begin());
      }
      try {
        const auto executed = command.kind == CommandKind::Refresh ?
          protocol->requestRefresh(command.operation) : command.kind == CommandKind::Encoding ?
          protocol->applyEncodingOptions(command.options, command.operation) : command.kind == CommandKind::DesktopLayout ?
          protocol->requestDesktopLayout(*command.layout, command.operation) : command.kind == CommandKind::ClipboardOffer ?
          protocol->offerClipboard(command.text, command.operation) : protocol->clearClipboard(command.operation);
        if (executed && command.kind == CommandKind::Encoding) {
          std::lock_guard<std::mutex> lock(commandMutex);
          currentEncoding = command.options;
        }
        if (command.kind == CommandKind::DesktopLayout) {
          std::lock_guard<std::mutex> lock(commandMutex);
          if (layoutQueued == command.operation) layoutQueued = 0;
        }
        if (command.kind == CommandKind::ClipboardOffer || command.kind == CommandKind::ClipboardClear) {
          std::lock_guard<std::mutex> lock(commandMutex);
          if (clipboardQueued == command.operation) clipboardQueued = 0;
        }
        // Layout completion belongs to the protocol until reply/timeout/close.
        if (!executed || command.kind != CommandKind::DesktopLayout)
          events->complete(command.operation, executed ? OperationResult::Succeeded : OperationResult::Failed);
      } catch (...) {
        events->complete(command.operation, OperationResult::Failed);
        throw;
      }
    }
  }
  EncodingOptions encoding() const
  {
    std::lock_guard<std::mutex> lock(commandMutex); return currentEncoding;
  }
  void observe() noexcept
  {
    try {
      const auto ready = transport->waitPeerClosure(SessionTransport::TimePoint::max());
      if (ready.peerClosed && !ready.cancelled) {
        peerClosed.store(true);
        auth->cancel(PromptCancelReason::PeerClosed);
        control->wake();
      }
    } catch (const std::system_error& error) {
      observerError.store(error.code().value()); observerFailed.store(true);
      auth->cancel(PromptCancelReason::PeerClosed); control->wake();
    } catch (...) {
      observerFailed.store(true);
      auth->cancel(PromptCancelReason::PeerClosed); control->wake();
    }
  }
  void run() noexcept
  {
    if (!reusable) { runAttempt(); return; }
    for (;;) {
      {
        std::unique_lock<std::mutex> lock(commandMutex);
        changed.wait(lock, [&] { return pendingAttempt || stopping || events->sealed(); });
        if (!pendingAttempt) break;
        pendingAttempt = false;
      }
      wakeup->install(control);
      runAttempt();
      wakeup->install(nullptr);
      std::shared_ptr<WorkerControl> old;
      {
        std::lock_guard<std::mutex> lock(commandMutex);
        old = std::move(control);
        attemptActive = false;
        // A terminal event makes retry admissible. Publish it under the same
        // admission gate after cleanup, so a consumer reacting immediately
        // cannot see a terminal state yet receive a transient Busy rejection.
        if (!events->sealed() && !events->publish(SessionEventKind::State, terminalState)) {
          result.code = WorkerResultCode::EventOverflow; result.nativeError = 0;
        }
        // Both completions are reserved before mutation. Disconnect success
        // means the old transport, observer and decoder are completely drained.
        events->complete(connectOperation, result.code == WorkerResultCode::Cancelled ?
                         OperationResult::Cancelled : OperationResult::Failed);
        connectOperation = 0;
        if (disconnectOperation) events->complete(disconnectOperation, OperationResult::Succeeded);
        disconnectOperation = 0;
        if (events->sealed()) stopping = true;
      }
    }
    auth->cancelPending();
    protocol.reset();
    if (!events->sealed() && events->snapshot().state == SessionState::Idle) {
      auto terminal = events->snapshot(); terminal.state = SessionState::Closed;
      terminal.endReason = SessionEndReason::Cancelled;
      events->publish(SessionEventKind::State, terminal);
    }
    events->seal(OperationResult::Cancelled);
    if (result.code == WorkerResultCode::InternalFailure && !attemptGeneration)
      result.code = WorkerResultCode::Cancelled;
  }
  void runAttempt() noexcept
  {
    std::thread observer;
    try {
      if (reusable) {
        // attemptActive prevents replacement until this attempt is fully drained.
        std::shared_ptr<const rfb::SecurityClient> options;
        bool shared;
        { std::lock_guard<std::mutex> lock(commandMutex); options = currentSecurity; shared = currentShared; }
        protocol->setShared(shared); protocol->setSecurity(*options);
        protocol->prepareAttempt(attemptGeneration);
      }
      if (!cancelled.load()) {
        if (connection) {
          transport = connection->run([this](ConnectionPhase phase) {
            if (cancelled.load()) return;
            auto snapshot = events->snapshot();
            snapshot.state = phase == ConnectionPhase::Resolving ? SessionState::Resolving : SessionState::Connecting;
            if (!events->publish(SessionEventKind::State, snapshot))
              throw std::runtime_error("Connection event queue overflow");
          });
          if (!transport) throw std::logic_error("Connection returned no transport");
          control->install(transport->control());
          connection.reset();
        }
        if (!cancelled.load()) protocol->start(serverName, transport->input(), transport->output());
        // start() resets the authentication bridge. Recheck cancellation before
        // any callback can park: close-before-start must never be lost.
        if (!cancelled.load()) observer = std::thread([this] { observe(); });
        while (!cancelled.load()) {
          if (events->sealed()) { result.code = WorkerResultCode::EventOverflow; break; }
          if (observerFailed.load()) {
            result.code = WorkerResultCode::TransportFailure;
            result.nativeError = observerError.load();
            break;
          }
          drainCommands();
          protocol->drainInput();
          protocol->dispatchScheduled();
          bool progressed = false;
          // Bound bursts so input, timers and cancellation cannot be starved by
          // a continuously readable peer. Never wait while buffered work remains.
          for (size_t n = 0; n < 64 && !cancelled.load(); ++n) {
            progressed = protocol->processMessage();
            if (reusable && protocol->snapshot().state == SessionState::Connected) {
              std::lock_guard<std::mutex> lock(commandMutex);
              // Cancellation and successful negotiation share this boundary.
              if (!cancelled.load() && connectOperation) {
                events->complete(connectOperation, OperationResult::Succeeded);
                connectOperation = 0;
              }
            }
            if (!progressed) break;
          }
          transport->flush();
          if (cancelled.load()) break;
          if (progressed) continue;
          if (peerClosed.load()) { result.code = WorkerResultCode::PeerClosed; break; }
          auto deadline = SessionTransport::TimePoint::max();
          protocol->nextDeadline(deadline);
          const auto ready = transport->wait(deadline, transport->outputPending());
          if (ready.cancelled) { result.code = WorkerResultCode::Cancelled; break; }
          // A FIN can accompany final protocol bytes. Process them on the next
          // iteration; only the independent observer cancels parked prompts.
          if (ready.peerClosed) peerClosed.store(true);
        }
      }
    } catch (const ConnectionError& error) {
      result.nativeError = error.nativeError;
      switch (error.code) {
      case ConnectionErrorCode::Cancelled: result.code = WorkerResultCode::Cancelled; break;
      case ConnectionErrorCode::TimedOut:
        result.code = error.phase == ConnectionPhase::Resolving ? WorkerResultCode::ResolutionTimedOut : WorkerResultCode::ConnectionTimedOut;
        break;
      case ConnectionErrorCode::Resolution: result.code = WorkerResultCode::ResolutionFailure; break;
      case ConnectionErrorCode::Connection: result.code = WorkerResultCode::ConnectionFailure; break;
      case ConnectionErrorCode::Unsupported: result.code = WorkerResultCode::UnsupportedEndpoint; break;
      case ConnectionErrorCode::InvalidAddress: result.code = WorkerResultCode::InvalidEndpoint; break;
      }
    } catch (const PromptInterrupted& error) {
      result.code = error.reason == PromptCancelReason::TimedOut ? WorkerResultCode::PromptTimedOut :
                    error.reason == PromptCancelReason::PeerClosed ? WorkerResultCode::PeerClosed :
                    WorkerResultCode::Cancelled;
    } catch (const rfb::auth_cancelled&) { result.code = WorkerResultCode::Cancelled; }
    catch (const rfb::auth_error&) { result.code = WorkerResultCode::AuthenticationRejected; }
    catch (const rdr::end_of_stream&) { result.code = WorkerResultCode::PeerClosed; }
    catch (const core::socket_error& error) {
      result.code = WorkerResultCode::TransportFailure; result.nativeError = error.err;
    } catch (const std::system_error& error) {
      result.code = WorkerResultCode::TransportFailure; result.nativeError = error.code().value();
    } catch (const std::bad_alloc&) { result.code = WorkerResultCode::ResourceFailure; }
    catch (const std::exception&) { result.code = WorkerResultCode::ProtocolFailure; }
    catch (...) { result.code = WorkerResultCode::InternalFailure; }
    {
      std::lock_guard<std::mutex> lock(commandMutex);
      // This is the terminal-reason boundary. Later close requests cannot change
      // the result, and no new command may race cleanup after this point.
      finishing = commandsClosed = true;
      if (events->snapshot().endReason == SessionEndReason::EventOverflow) {
        result.code = WorkerResultCode::EventOverflow; result.nativeError = 0;
      } else if (cancelled.load()) { result.code = WorkerResultCode::Cancelled; result.nativeError = 0; }
      else if (observerFailed.load()) {
        result.code = WorkerResultCode::TransportFailure; result.nativeError = observerError.load();
      }
      finishQueued(result.code == WorkerResultCode::Cancelled || result.code == WorkerResultCode::PeerClosed ?
                   OperationResult::Cancelled : OperationResult::Failed);
    }
    // The protocol cleans up on exceptions but the worker owns final lifecycle
    // publication, avoiding a premature Failed event for an intentional close.
    auto terminal = protocol->snapshot();
    terminal.generation = reusable ? attemptGeneration : events->snapshot().generation;
    terminal.state = SessionState::Disconnecting;
    if (!events->sealed() && !events->publish(SessionEventKind::State, terminal)) {
      result.code = WorkerResultCode::EventOverflow; result.nativeError = 0;
    }
    auth->cancelPending();
    const bool failed = result.code != WorkerResultCode::Cancelled &&
                        result.code != WorkerResultCode::PeerClosed;
    try { protocol->close(failed); } catch (...) { result.code = WorkerResultCode::InternalFailure; }
    terminal.frames = protocol->snapshot().frames;
    terminal.bells = protocol->snapshot().bells;
    terminal.width = terminal.height = 0;
    terminal.supportsDesktopResize = terminal.resizePending = false;
    terminal.layout.reset();
    if (!reusable) protocol.reset();
    // Best effort only: close never waits indefinitely for a backpressured peer.
    if (transport) { try { transport->flush(); } catch (...) {} }
    control->cancel();
    if (observer.joinable()) observer.join();
    transport.reset();
    connection.reset();
    terminal.state = result.code == WorkerResultCode::Cancelled || result.code == WorkerResultCode::PeerClosed ?
      SessionState::Closed : SessionState::Failed;
    terminal.endReason = result.code; terminal.nativeError = result.nativeError;
    if (!reusable && !events->sealed() && !events->publish(SessionEventKind::State, terminal)) {
      result.code = WorkerResultCode::EventOverflow; result.nativeError = 0;
    }
    terminalState = terminal;
    if (!reusable) events->seal(terminal.state == SessionState::Closed ? OperationResult::Cancelled : OperationResult::Failed);
    // The coordinator sets completion only after joining this thread as well.
  }
  const bool reusable;
  bool stopping = false, attemptActive = false, pendingAttempt = false;
  uint64_t attemptGeneration = 0, connectOperation = 0, disconnectOperation = 0;
  std::condition_variable changed;
  std::shared_ptr<WakeRouter> wakeup;
  std::unique_ptr<SessionTransport> transport;
  std::unique_ptr<ConnectionAttempt> connection;
  std::unique_ptr<ProtocolSession> protocol;
  std::string serverName;
  const size_t commandCapacity;
  const size_t framebufferLimit;
  uint64_t layoutQueued = 0;
  uint64_t clipboardQueued = 0;
  mutable std::mutex commandMutex;
  std::vector<Command> commands;
  EncodingOptions currentEncoding;
  std::shared_ptr<const rfb::SecurityClient> currentSecurity;
  uint64_t securityRevision = 1;
  bool currentShared;
  uint64_t sharingRevision = 1;
  bool commandsClosed = false, finishing = false;
  std::shared_ptr<WorkerControl> control;
  std::shared_ptr<PromptAuthentication> auth;
  std::shared_ptr<SessionEvents> events;
  std::shared_ptr<FrameSubscription> view;
  std::shared_ptr<InputQueue> input;
  std::shared_ptr<ClipboardChannel> clipboard;
  std::weak_ptr<MailboxWakeup> mailboxWakeup;
  std::atomic<bool> cancelled{false}, peerClosed{false}, observerFailed{false};
  std::atomic<int> observerError{0};
  WorkerResult result;
  SessionSnapshot terminalState;
  std::promise<WorkerResult> completion;
  const std::shared_future<WorkerResult> done;
};

struct SessionRuntime::Impl {
  struct Job {
    std::shared_ptr<SessionWorker::State> state;
    std::thread thread;
    bool finished = false;
  };
  explicit Impl(size_t capacity_) : capacity(capacity_), done(completion.get_future().share())
  {
    if (!capacity || capacity > 64) throw std::invalid_argument("Invalid worker capacity");
    coordinator = std::thread([this] { reap(); });
  }
  void reap()
  {
    std::unique_lock<std::mutex> lock(mutex);
    for (;;) {
      auto ready = jobs.end();
      for (auto job = jobs.begin(); job != jobs.end(); ++job)
        if (job->finished) { ready = job; break; }
      if (ready == jobs.end()) {
        if (stopping && !admitted) break;
        changed.wait(lock); continue;
      }
      std::list<Job> retired;
      retired.splice(retired.end(), jobs, ready);
      lock.unlock();
      auto& job = retired.front();
      job.thread.join();
      // Keep the admission slot until resources and the thread are drained.
      lock.lock(); --admitted; lock.unlock();
      job.state->completion.set_value(job.state->result);
      if (auto target = job.state->mailboxWakeup.lock()) target->wake();
      retired.clear();
      lock.lock();
    }
    lock.unlock();
    completion.set_value();
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

SessionWorker::SessionWorker(std::shared_ptr<State> state_) : state(std::move(state_)) {}
SessionWorker::~SessionWorker() { state->cancel(); }
std::shared_ptr<SessionEvents> SessionWorker::events() const { return state->events; }
uint64_t SessionWorker::generation() const {
  std::lock_guard<std::mutex> lock(state->commandMutex);
  return std::max(state->attemptGeneration,state->events->snapshot().generation);
}
std::shared_ptr<FrameSubscription> SessionWorker::view() const { return state->view; }
std::shared_ptr<InputQueue> SessionWorker::input() const { return state->input; }
std::shared_ptr<PromptAuthentication> SessionWorker::authentication() const { return state->auth; }
std::shared_ptr<ClipboardChannel> SessionWorker::clipboard() const { return state->clipboard; }
void SessionWorker::setClipboardPolicy(ClipboardPolicy policy) { state->clipboard->setPolicy(policy); wake(); }
CommandSubmission SessionWorker::offerClipboard(uint64_t generation, const std::string& text,
                                                 const ClipboardLease& origin, uint64_t changeId)
{
  auto prepared = state->clipboard->prepareLocal(generation,text,origin);
  if (prepared.result != ClipboardResult::Accepted) {
    switch (prepared.result) {
    case ClipboardResult::Stale: return {CommandAdmission::StaleGeneration};
    case ClipboardResult::NotConnected: return {CommandAdmission::NotConnected};
    case ClipboardResult::Unfocused: return {CommandAdmission::Unfocused};
    case ClipboardResult::ViewOnly: return {CommandAdmission::ViewOnly};
    case ClipboardResult::Disabled: return {CommandAdmission::Disabled};
    case ClipboardResult::Echo: return {CommandAdmission::Echo};
    case ClipboardResult::TooLarge: case ClipboardResult::Backpressure: return {CommandAdmission::ResourceLimit};
    default: return {CommandAdmission::InvalidValue};
    }
  }
  const auto result = state->submit(State::CommandKind::ClipboardOffer,generation,nullptr,nullptr,changeId,std::move(prepared.text));
  if (result.status == CommandAdmission::Accepted || result.status == CommandAdmission::EventCapacity) wake();
  return result;
}
CommandSubmission SessionWorker::clearClipboard(uint64_t generation)
{
  const auto result = state->submit(State::CommandKind::ClipboardClear,generation,nullptr);
  if (result.status == CommandAdmission::Accepted || result.status == CommandAdmission::EventCapacity) wake();
  return result;
}
CommandSubmission SessionWorker::connect(std::unique_ptr<ConnectionAttempt> connection)
{
  const auto result = state->connect(std::move(connection));
  if (result.status == CommandAdmission::EventCapacity) wake();
  return result;
}
CommandSubmission SessionWorker::disconnect(uint64_t generation)
{
  const auto result = state->disconnect(generation);
  if (result.status == CommandAdmission::EventCapacity) wake();
  return result;
}
CommandSubmission SessionWorker::requestRefresh(uint64_t generation)
{
  const auto result = state->submit(State::CommandKind::Refresh, generation, nullptr);
  if (result.status == CommandAdmission::Accepted || result.status == CommandAdmission::EventCapacity) wake();
  return result;
}
CommandSubmission SessionWorker::applyEncodingOptions(uint64_t generation, const EncodingOptions& options)
{
  const auto result = state->submit(State::CommandKind::Encoding, generation, &options);
  if (result.status == CommandAdmission::Accepted || result.status == CommandAdmission::EventCapacity) wake();
  return result;
}
EncodingOptions SessionWorker::encodingOptions() const { return state->encoding(); }
SessionSharingSnapshot SessionWorker::sharing() const {
  std::lock_guard<std::mutex> lock(state->commandMutex);
  return {state->currentShared,state->reusable && !state->stopping && !state->events->sealed() && !state->attemptActive,
    state->sharingRevision,std::max(state->attemptGeneration,state->events->snapshot().generation)};
}
CommandAdmission SessionWorker::setShared(uint64_t generation,uint64_t revision,bool shared) {
  std::lock_guard<std::mutex> lock(state->commandMutex);
  if (!state->reusable) return CommandAdmission::Unsupported;
  if (state->stopping || state->events->sealed()) return CommandAdmission::Closing;
  if (generation != std::max(state->attemptGeneration,state->events->snapshot().generation) || revision != state->sharingRevision)
    return CommandAdmission::StaleGeneration;
  if (state->attemptActive) return CommandAdmission::Busy;
  if (revision == std::numeric_limits<uint64_t>::max()) return CommandAdmission::ResourceLimit;
  state->currentShared = shared; ++state->sharingRevision; return CommandAdmission::Accepted;
}
SessionSecuritySnapshot SessionWorker::securityOptions() const {
  std::lock_guard<std::mutex> lock(state->commandMutex);
  return {state->currentSecurity,state->securityRevision,
    std::max(state->attemptGeneration,state->events->snapshot().generation),
    state->reusable && !state->stopping && !state->events->sealed() && !state->attemptActive};
}
CommandAdmission SessionWorker::setSecurity(uint64_t generation, uint64_t revision,
                                            const rfb::SecurityClient& options) {
  auto next = std::make_shared<const rfb::SecurityClient>(options);
  std::lock_guard<std::mutex> lock(state->commandMutex);
  if (!state->reusable) return CommandAdmission::Unsupported;
  if (state->stopping || state->events->sealed()) return CommandAdmission::Closing;
  if (generation != std::max(state->attemptGeneration,state->events->snapshot().generation) ||
      revision != state->securityRevision) return CommandAdmission::StaleGeneration;
  if (state->attemptActive) return CommandAdmission::Busy;
  if (revision == std::numeric_limits<uint64_t>::max()) return CommandAdmission::ResourceLimit;
  state->currentSecurity = std::move(next); ++state->securityRevision;
  return CommandAdmission::Accepted;
}
CommandSubmission SessionWorker::requestDesktopLayout(uint64_t generation, const RemoteDesktopLayout& layout,
                                                       uint64_t origin)
{
  // Use an internal copy/deleter; callers cannot install a reentrant custom
  // shared_ptr deleter into the queue that is cleared under the admission lock.
  auto owned = std::make_shared<const RemoteDesktopLayout>(layout);
  const auto result = state->submit(State::CommandKind::DesktopLayout, generation, nullptr, std::move(owned), origin);
  if (result.status == CommandAdmission::Accepted || result.status == CommandAdmission::EventCapacity) wake();
  return result;
}
CommandCancellation SessionWorker::cancelOperation(uint64_t generation, uint64_t operation)
{
  return state->cancelCommand(generation, operation);
}
void SessionWorker::wake() noexcept { state->wakeup->wake(); state->changed.notify_one(); }
std::shared_future<WorkerResult> SessionWorker::closeAndDrain() noexcept
{
  state->cancel(); return state->done;
}
std::shared_future<WorkerResult> SessionWorker::drained() const { return state->done; }
SessionRuntime::SessionRuntime(size_t capacity) : impl(new Impl(capacity)) {}
SessionRuntime::~SessionRuntime()
{
  shutdown(); impl->coordinator.join();
}
std::shared_ptr<SessionWorker> SessionRuntime::createSession(const rfb::SecurityClient& security,
  const SessionWorkerOptions& options)
{
  return admit(std::make_shared<SessionWorker::State>(nullptr, nullptr, "", security, options, true));
}
std::shared_ptr<SessionWorker> SessionRuntime::start(std::unique_ptr<SessionTransport> transport,
  const std::string& serverName, const rfb::SecurityClient& security, const SessionWorkerOptions& options)
{
  return admit(std::make_shared<SessionWorker::State>(std::move(transport), nullptr, serverName, security, options));
}
std::shared_ptr<SessionWorker> SessionRuntime::connect(std::unique_ptr<ConnectionAttempt> connection,
  const rfb::SecurityClient& security, const SessionWorkerOptions& options)
{
  if (!connection) throw std::invalid_argument("Missing connection attempt");
  const auto serverName = connection->serverName();
  return admit(std::make_shared<SessionWorker::State>(nullptr, std::move(connection), serverName, security, options));
}
std::shared_ptr<SessionWorker> SessionRuntime::admit(std::shared_ptr<SessionWorker::State> state)
{
  auto handle = std::shared_ptr<SessionWorker>(new SessionWorker(state));
  std::list<Impl::Job> pending;
  pending.emplace_back();
  auto& job = pending.front(); job.state = state;
  {
    std::lock_guard<std::mutex> lock(impl->mutex);
    if (impl->stopping) throw std::logic_error("Session runtime is shut down");
    if (impl->admitted == impl->capacity) throw std::length_error("Session runtime is full");
    auto* runtime = impl.get(); auto* entry = &job;
    job.thread = std::thread([state, runtime, entry] {
      state->run();
      {
        std::lock_guard<std::mutex> done(runtime->mutex);
        entry->finished = true;
      }
      runtime->changed.notify_one();
    });
    impl->jobs.splice(impl->jobs.end(), pending);
    ++impl->admitted;
  }
  return handle;
}
void SessionRuntime::shutdown() noexcept
{
  std::array<std::shared_ptr<SessionWorker::State>, 64> active;
  size_t count = 0;
  {
    std::lock_guard<std::mutex> lock(impl->mutex);
    impl->stopping = true;
    for (auto& job : impl->jobs) active[count++] = job.state;
  }
  // Cancellation is outside the runtime mutex; injected controls may reenter.
  for (size_t i = 0; i < count; ++i) active[i]->cancel();
  impl->changed.notify_one();
}
std::shared_future<void> SessionRuntime::drained() const { return impl->done; }
size_t SessionRuntime::active() const
{
  std::lock_guard<std::mutex> lock(impl->mutex); return impl->admitted;
}
}
