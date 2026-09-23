/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "ProtocolSession.h"
#include <type_traits>
#include <climits>

#include <rfb/CConnection.h>
#include <rfb/CSecurity.h>
#include <rfb/encodings.h>
#include <rfb/Cursor.h>
#include <rfb/CMsgWriter.h>
#include <rfb/Exception.h>
#include <rfb/PixelBuffer.h>
#include <rfb/screenTypes.h>
#include <rfb/ScreenSet.h>
#include <limits>
#include <stdexcept>
#include <utility>
#include <algorithm>
#include <vector>
#include <chrono>
#include <cstring>
#include <rdr/InStream.h>

namespace viewer {
namespace {
rfb::PixelFormat framebufferFormat()
{
  // Byte order is BGRA on every host, independent of native integer endianness.
  return rfb::PixelFormat(32, 24, false, true, 255, 255, 255, 16, 8, 0);
}
}
class ProtocolSession::Connection : public rfb::CConnection {
public:
  explicit Connection(ProtocolSession& owner_)
    : CConnection(owner_.security, owner_.messages), owner(owner_) {
    setShared(owner.shared);
    supportsLocalCursor = true;
    supportsDesktopResize = true;
    configureEncoding();
    held.reserve(owner.buffers.heldKeys);
  }
  bool ready = false;
  uint64_t bells = 0;
  std::shared_ptr<const SessionInformation> information() {
    auto result = std::make_shared<SessionInformation>();
    size_t length = 0;
    while (length < result->desktopName.size() && server.name()[length]) ++length;
    const auto copied = std::min(length, result->desktopName.size()-1);
    std::memcpy(result->desktopName.data(), server.name(), copied);
    result->nameTruncated = copied != length;
    result->protocolMajor = server.majorVersion; result->protocolMinor = server.minorVersion;
    result->securityType = csecurity->getType(); result->secure = csecurity->isSecure();
    result->pixelFormat = server.pf(); result->requestedEncoding = getPreferredEncoding();
    result->lastEncoding = lastEncoding; result->bitsPerSecond = bandwidth.bitsPerSecond();
    return result;
  }
  void syncClipboard() {
    if (localClipboard && owner.clipboardMailbox->check(localClipboard->route(),true) != ClipboardResult::Accepted) {
      localClipboard.reset(); announceClipboard(false);
    }
  }
  void offerClipboard(ClipboardLease text) {
    localClipboard = std::move(text);
    announceClipboard(bool(localClipboard));
  }

  void configureEncoding() {
    setPreferredEncoding(owner.encoding.selectedEncoding());
    setCompressLevel(owner.encoding.selectedCompression());
    setQualityLevel(owner.encoding.selectedQuality(bandwidth.bitsPerSecond()));
    setJpegAllowed(owner.encoding.jpegAllowed());
    if (ready && !server.beforeVersion(3, 8))
      setPF(owner.encoding.selectedFormat(bandwidth.bitsPerSecond(), framebufferFormat()));
  }

  bool sendInput(const InputQueue::Command& command) {
    if (command.kind == InputQueue::Command::ReleaseAll) {
      releaseInput(); return true;
    }
    if (command.kind == InputQueue::Command::Pointer) {
      pointerPosition = core::Point(command.x, command.y);
      buttons = command.buttons;
      writer()->writePointerEvent(pointerPosition, buttons);
      return true;
    }
    auto key = std::find_if(held.begin(), held.end(), [&](const HeldKey& value) {
      return value.id == command.keyId;
    });
    if (command.down) {
      if (key == held.end()) {
        if (held.size() == owner.buffers.heldKeys) return false;
        held.push_back({command.keyId, command.keySym, command.keyCode});
        key = held.end() - 1;
      }
      writer()->writeKeyEvent(key->symbol, key->code, true);
    } else if (key != held.end()) {
      writer()->writeKeyEvent(key->symbol, key->code, false);
      held.erase(key);
    }
    return true;
  }
  void releaseInput() {
    // Unwind chords in reverse press order.
    while (!held.empty()) {
      const auto key = held.back();
      writer()->writeKeyEvent(key.symbol, key.code, false);
      held.pop_back();
    }
    if (buttons) {
      writer()->writePointerEvent(pointerPosition, 0);
      buttons = 0;
    }
  }

  bool publish() {
    if (inUpdate) { owner.publicationResult(false); return false; }
    if (!ready) return true;
    // End-of-update normally joined these already. Retrying must not race any
    // decoder work, even when no views are currently attached.
    syncFramebuffer();
    bool published = true;
    if (!damage.is_empty()) {
      auto* buffer = getFramebuffer();
      int stride;
      const auto* data = buffer->getBuffer(buffer->getRect(), &stride);
      PixelView input{data, size_t(stride)*buffer->height()*4,
        uint32_t(buffer->width()), uint32_t(buffer->height()), size_t(stride)*4,
        PixelFormat::BGRA8, AlphaMode::Opaque, PixelOrigin::TopLeft};
      const auto result = owner.publisher.publishFrame(owner.publisher.generation(), input,
        {uint32_t(damage.tl.x), uint32_t(damage.tl.y), uint32_t(damage.width()), uint32_t(damage.height())});
      if (result == PublishResult::Published) damage.clear();
      else published = false;
    }
    if (cursorChanged) {
      const auto& cursor = server.cursor();
      PublishResult result;
      if (!cursor.width() || !cursor.height()) {
        result = owner.publisher.hideCursor(owner.publisher.generation());
      } else {
        PixelView input{cursor.getBuffer(), size_t(cursor.width())*cursor.height()*4,
          uint32_t(cursor.width()), uint32_t(cursor.height()), size_t(cursor.width())*4,
          PixelFormat::RGBA8, AlphaMode::Straight, PixelOrigin::TopLeft};
        result = owner.publisher.publishCursor(owner.publisher.generation(), input,
          cursor.hotspot().x, cursor.hotspot().y);
      }
      if (result == PublishResult::Published) cursorChanged = false;
      else published = false;
    }
    owner.publicationResult(published);
    return published;
  }
protected:
  void initDone() override {
    resizeFramebuffer();
    ready = true;
    configureEncoding();
    publish();
    owner.inputMailbox->connected();
    owner.eventState.state = SessionState::Connected;
    if (!owner.emit(SessionEventKind::State)) throw std::runtime_error("Session event queue overflow");
  }
  void resizeFramebuffer() override {
    const int width = server.width(), height = server.height();
    if (width <= 0 || height <= 0 || width > 65535 || height > 65535 ||
        size_t(width) > size_t(std::numeric_limits<int>::max()) / 4 / size_t(height) ||
        size_t(width)*4 > owner.buffers.framebufferBytes / size_t(height))
      throw std::length_error("Framebuffer exceeds session limit");
    std::unique_ptr<rfb::ManagedPixelBuffer> replacement(
      new rfb::ManagedPixelBuffer(framebufferFormat(), width, height));
    const uint8_t black[4] = {};
    replacement->fillRect(replacement->getRect(), black);
    // Base owns/deletes the buffer and preserves the old overlapping pixels.
    setFramebuffer(replacement.get());
    replacement.release();
    std::vector<RemoteScreen> screens;
    screens.reserve(server.screenLayout().num_screens());
    for (const auto& screen : server.screenLayout())
      screens.push_back({screen.id, uint32_t(screen.dimensions.tl.x), uint32_t(screen.dimensions.tl.y),
        uint32_t(screen.dimensions.width()), uint32_t(screen.dimensions.height()), screen.flags});
    owner.eventState.layout = std::make_shared<const RemoteDesktopLayout>(width, height, std::move(screens));
    owner.eventState.supportsDesktopResize = server.supportsSetDesktopSize;
    damage = {0, 0, width, height};
    if (ready && !extendedResize && !owner.emit(SessionEventKind::Desktop))
      throw std::runtime_error("Session event queue overflow");
  }
  void setExtendedDesktopSize(unsigned reason, unsigned result, int width, int height,
                              const rfb::ScreenSet& layout) override {
    extendedResize = true;
    try { CConnection::setExtendedDesktopSize(reason, result, width, height, layout); }
    catch (...) { extendedResize = false; throw; }
    extendedResize = false;
    owner.eventState.supportsDesktopResize = server.supportsSetDesktopSize;
    uint64_t completed = 0;
    if (reason == rfb::reasonClient && owner.eventState.resizePending) {
      owner.desktopResizeTimer.cancel(); owner.desktopResizeTimer = {};
      owner.eventState.resizePending = false;
      completed = owner.desktopResizeOperation;
      owner.desktopResizeOperation = 0;
    }
    // Publish the actual server layout, including topology-only changes or a
    // rejected request, before its completion. Other-client changes cannot settle
    // this client's request. A late timed-out reply only clears the wire slot.
    if (!owner.emit(SessionEventKind::Desktop)) throw std::runtime_error("Session event queue overflow");
    if (completed) if (auto events = owner.eventObserver.lock())
      events->complete(completed, result == rfb::resultSuccess ? OperationResult::Succeeded : OperationResult::Failed,
                       result == rfb::resultSuccess ? OperationFailure::None : OperationFailure::ServerRejected, result);
  }
  void framebufferUpdateStart() override {
    inUpdate = true;
    CConnection::framebufferUpdateStart();
    updateStart = std::chrono::steady_clock::now();
    updatePosition = getInStream()->pos();
  }
  void framebufferUpdateEnd() override {
    CConnection::framebufferUpdateEnd();
    inUpdate = false;
    const auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(
      std::chrono::steady_clock::now() - updateStart).count();
    const auto position = getInStream()->pos();
    bandwidth.observe(position >= updatePosition ? position - updatePosition : 0,
                      elapsed > 0 ? elapsed : 1);
    if (owner.encoding.autoSelect()) configureEncoding();
    publish();
    ++owner.eventState.frames;
    owner.scheduleStatistics();
  }
  bool dataRect(const core::Rect& rectangle, int wireEncoding) override {
    if (!CConnection::dataRect(rectangle, wireEncoding)) return false;
    if (wireEncoding != rfb::encodingCopyRect) lastEncoding = wireEncoding;
    damage = damage.union_boundary(rectangle);
    return true;
  }
  void setCursor(int width, int height, const core::Point& hotspot,
                 const uint8_t* data) override {
    CConnection::setCursor(width, height, hotspot, data);
    cursorChanged = true;
  }
  void bell() override {
    ++bells;
    if (!owner.emit(SessionEventKind::Bell)) throw std::runtime_error("Session event queue overflow");
  }
  void handleClipboardRequest() override {
    syncClipboard();
    if (localClipboard) sendClipboardData(localClipboard->text().c_str());
  }
  void handleClipboardAnnounce(bool available) override {
    localClipboard.reset();
    owner.clipboardMailbox->offerRemote(available);
    if (!available) { remoteRequestPending = false; return; }
    const auto routing = owner.clipboardMailbox->route();
    if (owner.clipboardMailbox->check(routing,false) != ClipboardResult::Accepted) return;
    remoteRequestPending = true; remoteRequestRoute = routing;
    requestClipboard(); // Legacy cached text may synchronously call handleClipboardData.
  }
  void handleClipboardData(const char* data) override {
    const auto routing = remoteRequestPending ? remoteRequestRoute : owner.clipboardMailbox->route();
    remoteRequestPending = false;
    if (localClipboard) { localClipboard.reset(); announceClipboard(false); }
    owner.clipboardMailbox->receive(data,routing);
  }
  void getUserPasswd(bool secure, std::string* user, std::string* password) override {
    if (!owner.authentication) throw rfb::auth_cancelled();
    owner.authenticating();
    owner.authentication->credentialsForSecurity(csecurity->getType(), secure, user, password);
  }
  bool verifyCertificate(unsigned int status, const uint8_t* certificate, size_t length) override {
    if (owner.authentication) owner.authenticating();
    return owner.authentication && owner.authentication->certificate(status, certificate, length);
  }
  bool verifyHostKey(const uint8_t* key, size_t length, const char* fingerprint) override {
    if (owner.authentication) owner.authenticating();
    return owner.authentication && owner.authentication->hostKey(key, length, fingerprint);
  }
private:
  ProtocolSession& owner;
  core::Rect damage;
  bool inUpdate = false, cursorChanged = false, extendedResize = false;
  struct HeldKey { uint32_t id, symbol, code; };
  std::vector<HeldKey> held;
  core::Point pointerPosition;
  uint16_t buttons = 0;
  BandwidthEstimate bandwidth;
  int lastEncoding = -1;
  ClipboardLease localClipboard;
  bool remoteRequestPending = false;
  ClipboardRoute remoteRequestRoute;
  std::chrono::steady_clock::time_point updateStart;
  size_t updatePosition = 0;
};
ProtocolSession::ProtocolSession(const rfb::SecurityClient& security_,
  const rfb::ClientMessageLimits& messages_, const SessionBufferLimits& buffers_,
  std::shared_ptr<SessionAuthentication> authentication_, const EncodingOptions& encoding_,
  const SessionTiming& timing_, SessionTerminalOwnership terminalOwnership_, ClipboardPolicy clipboardPolicy, bool shared_)
  : security(security_), shared(shared_), messages(messages_), buffers(buffers_), encoding(encoding_),
    timing(timing_), terminalOwnership(terminalOwnership_), scheduler(5, timing.wakeup),
    authentication(authentication_), publisher(buffers.publicationBytes, buffers.subscribers),
    inputMailbox(new InputQueue(buffers.inputCommands)),
    clipboardMailbox(new ClipboardChannel(inputMailbox,buffers.clipboardTextBytes,buffers.clipboardRetainedBytes,clipboardPolicy))
{
  messages.validate();
  if (!buffers.framebufferBytes)
    throw std::invalid_argument("Framebuffer limit must be positive");
  if (!buffers.heldKeys || buffers.heldKeys > 1024)
    throw std::invalid_argument("Invalid held key limit");
  if (!timing.now || timing.statisticsInterval.count() < 1 ||
      timing.statisticsInterval > std::chrono::seconds(60) ||
      timing.publicationRetryInterval.count() < 1 ||
      timing.publicationRetryInterval > std::chrono::seconds(60) ||
      timing.desktopResizeTimeout.count() < 1 || timing.desktopResizeTimeout > std::chrono::seconds(60) ||
      timing.pointerEventInterval.count() < 0 || timing.pointerEventInterval.count() > INT_MAX)
    throw std::invalid_argument("Invalid session timing policy");
}
ProtocolSession::~ProtocolSession()
{
  // Drain before publisher and authentication services go away. The host closes
  // on its worker; destruction must not be delegated to a UI rendering callback.
  close();
  if (terminalOwnership == SessionTerminalOwnership::Protocol)
    if (auto events = eventObserver.lock()) events->seal(OperationResult::Cancelled);
}
void ProtocolSession::setShared(bool value)
{
  if (processing || connection) throw std::logic_error("Active shared policy configuration");
  shared = value;
}
void ProtocolSession::setSecurity(const rfb::SecurityClient& options)
{
  if (processing || connection) throw std::logic_error("Active security configuration");
  rfb::SecurityClient next(options);
  static_assert(std::is_nothrow_move_assignable<rfb::SecurityClient>::value,
                "Security replacement must commit without throwing");
  security = std::move(next);
}
void ProtocolSession::prepareAttempt(uint64_t generation)
{
  if (processing || connection || generation < publisher.generation() ||
      generation == std::numeric_limits<uint64_t>::max())
    throw std::logic_error("Invalid prepared session generation");
  if (auto events = eventObserver.lock()) {
    if (generation <= events->snapshot().generation)
      throw std::logic_error("Session attempt generation must advance");
  }
  if (generation > publisher.generation()) publisher.reset(generation);
  inputMailbox->end(generation);
  clipboardMailbox->invalidate();
  eventState = SessionSnapshot();
  if (!emit(SessionEventKind::State)) throw std::runtime_error("Session event queue overflow");
}
void ProtocolSession::start(const std::string& serverName, rdr::InStream& input, rdr::OutStream& output)
{
  if (connection) throw std::logic_error("Session attempt already active");
  if (publisher.generation() == std::numeric_limits<uint64_t>::max())
    throw std::overflow_error("Session generation exhausted");
  if (serverName.find('\0') != std::string::npos)
    throw std::invalid_argument("Server name contains NUL");
  std::unique_ptr<Connection> next(new Connection(*this));
  next->setServerName(serverName.c_str());
  next->setStreams(&input, &output);
  next->initialiseProtocol();
  if (authentication)
    authentication->beginAttempt(publisher.generation(), serverName);
  inputMailbox->begin(publisher.generation());
  clipboardMailbox->invalidate();
  connection = std::move(next);
  eventState = SessionSnapshot();
  eventState.state = SessionState::Negotiating;
  try {
    if (!emit(SessionEventKind::State)) throw std::runtime_error("Session event queue overflow");
  } catch (...) {
    finish(true);
    throw;
  }
}
bool ProtocolSession::processMessage()
{
  if (!connection) throw std::logic_error("No active session attempt");
  if (processing) throw std::logic_error("Reentrant protocol processing");
  processing = true;
  try {
    const bool result = connection->processMsg();
    processing = false;
    return result;
  } catch (...) {
    processing = false;
    finish(true);
    throw;
  }
}
void ProtocolSession::close(bool failed)
{
  finish(failed);
}
void ProtocolSession::finish(bool failed)
{
  if (processing) throw std::logic_error("Reentrant protocol close");
  resetPointer(); resetMiddle(); scheduler.cancelAll();
  statisticsTimer = {}; publicationTimer = {}; desktopResizeTimer = {};
  if (desktopResizeOperation) if (auto events = eventObserver.lock())
    events->complete(desktopResizeOperation, failed ? OperationResult::Failed : OperationResult::Cancelled);
  desktopResizeOperation = 0;
  eventState.resizePending = eventState.supportsDesktopResize = false;
  eventState.layout.reset();
  eventState.information.reset();
  clipboardMailbox->invalidate();
  if (!connection) return;
  inputMailbox->end(publisher.generation() + 1);
  if (authentication) authentication->cancelPending();
  // A dead transport may reject release writes. Still drain and invalidate;
  // never replace the original protocol/IO error with a teardown write error.
  if (connection->ready) {
    try { connection->releaseInput(); } catch (...) {}
  }
  eventState.state = failed ? SessionState::Failed : SessionState::Closed;
  eventState.width = eventState.height = 0;
  if (terminalOwnership == SessionTerminalOwnership::Protocol) {
    if (auto events = eventObserver.lock())
      events->cancelPending(failed ? OperationResult::Failed : OperationResult::Cancelled);
    emit(SessionEventKind::State);
  }
  // No callbacks are made to views; their queued images are invalidated after
  // decoder work and protocol-owned resources have been drained.
  connection.reset();
  publisher.reset(publisher.generation() + 1);
  eventState.generation = publisher.generation();
}
SessionDesktop ProtocolSession::desktop() const
{
  SessionDesktop result;
  result.generation = publisher.generation();
  result.active = bool(connection);
  if (connection) {
    result.ready = connection->ready;
    result.bells = connection->bells;
    if (result.ready) {
      result.width = connection->server.width();
      result.height = connection->server.height();
      result.name = connection->server.name();
    }
  }
  return result;
}
std::shared_ptr<FrameSubscription> ProtocolSession::attachView() { return publisher.subscribe(); }
bool ProtocolSession::retryPublication()
{
  if (processing) throw std::logic_error("Reentrant publication");
  processing = true;
  try {
    const bool result = !connection || connection->publish();
    processing = false;
    return result;
  } catch (...) {
    processing = false;
    finish(true);
    throw;
  }
}
size_t ProtocolSession::publicationBytesInUse() const { return publisher.bytesInUse(); }
std::shared_ptr<InputQueue> ProtocolSession::inputQueue() const { return inputMailbox; }
void ProtocolSession::resetMiddle()
{
  middleTimer.cancel(); middleTimer = {}; middle.reset(); middleRevision = 0;
}
void ProtocolSession::resetPointer()
{
  pointerTimer.cancel(); pointerTimer = {}; pendingPointer = {}; lastPointerButtons = 0;
}
void ProtocolSession::flushPointer()
{
  if (!pointerTimer) return;
  pointerTimer.cancel(); pointerTimer = {};
  // A producer can change focus/policy after the key was dequeued. Delayed
  // motion needs its own current-route check at this alternate send boundary.
  const auto status = inputMailbox->status();
  if (!connection || !connection->ready || status.generation != publisher.generation() ||
      status.routingRevision != middleRevision || !status.connected || !status.focused || status.viewOnly) {
    resetPointer(); return;
  }
  connection->sendInput(pendingPointer);
}
void ProtocolSession::sendPointer(const InputQueue::Command& command)
{
  // Match the retained viewer: transitions bypass throttling; an existing
  // one-shot timer keeps its original deadline and sends the latest position
  // and button mask. Continuous motion cannot postpone delivery indefinitely.
  pendingPointer = command;
  if (!timing.pointerEventInterval.count() || command.buttons != lastPointerButtons) {
    connection->sendInput(command);
  } else if (!pointerTimer) {
    const auto generation = publisher.generation(), revision = middleRevision;
    pointerTimer = scheduler.scheduleAt(deadlineAfter(timing.pointerEventInterval), [this,generation,revision] {
      pointerTimer = {};
      const auto status = inputMailbox->status();
      if (!connection || !connection->ready || publisher.generation() != generation ||
          status.generation != generation || status.routingRevision != revision ||
          !status.connected || !status.focused || status.viewOnly) {
        resetPointer(); return;
      }
      connection->sendInput(pendingPointer);
    });
    if (!pointerTimer) throw std::runtime_error("Session timer queue full");
  }
  lastPointerButtons = command.buttons;
}
void ProtocolSession::sendMiddleBatch(const MiddleButtonEmulator::Batch& batch)
{
  for (size_t i = 0; i < batch.count; ++i) {
    InputQueue::Command command;
    command.kind = InputQueue::Command::Pointer;
    command.x = batch.events[i].position.x; command.y = batch.events[i].position.y;
    command.buttons = batch.events[i].buttons;
    sendPointer(command);
  }
}
bool ProtocolSession::sendInput(const InputQueue::Command& command)
{
  if (command.routingRevision != middleRevision || command.kind == InputQueue::Command::ReleaseAll) {
    resetPointer(); resetMiddle(); middleRevision = command.routingRevision;
  }
  if (command.kind != InputQueue::Command::Pointer) {
    // Preserve the mailbox's motion-before-key ordering. Release barriers above
    // discard pending motion instead of flushing it into a different focus.
    if (command.kind == InputQueue::Command::Key) flushPointer();
    return connection->sendInput(command);
  }
  if (!command.emulateMiddle) { sendPointer(command); return true; }
  const auto batch = middle.pointer({command.x, command.y}, command.buttons);
  sendMiddleBatch(batch);
  if (batch.timerChanged) {
    middleTimer.cancel(); middleTimer = {};
    if (middle.pending()) {
      const auto generation = publisher.generation(), revision = middleRevision;
      middleTimer = scheduler.scheduleAt(deadlineAfter(std::chrono::milliseconds(50)), [this, generation, revision] {
        middleTimer = {};
        const auto status = inputMailbox->status();
        if (!connection || !connection->ready || publisher.generation() != generation ||
            status.generation != generation || status.routingRevision != revision ||
            !status.connected || !status.focused || status.viewOnly || !status.emulateMiddle) {
          resetMiddle(); return;
        }
        sendMiddleBatch(middle.expire());
      });
      if (!middleTimer) throw std::runtime_error("Session timer queue full");
    }
  }
  return true;
}
bool ProtocolSession::drainInput()
{
  if (processing) throw std::logic_error("Reentrant input processing");
  if (!connection || !connection->ready) return true;
  processing = true;
  try {
    connection->syncClipboard();
    InputQueue::Command command;
    bool okay = true;
    for (size_t count = 0; count <= buffers.inputCommands && inputMailbox->take(command); ++count) {
      if (!sendInput(command)) {
        inputMailbox->overflow();
        resetPointer(); resetMiddle();
        connection->releaseInput();
        okay = false;
        break;
      }
    }
    processing = false;
    return okay;
  } catch (...) {
    processing = false;
    finish(true);
    throw;
  }
}
bool ProtocolSession::emit(SessionEventKind kind)
{
  eventState.generation = publisher.generation();
  eventState.width = eventState.height = 0;
  if (connection) {
    eventState.bells = connection->bells;
    if (connection->ready && eventState.state == SessionState::Connected) {
      eventState.width = connection->server.width();
      eventState.height = connection->server.height();
      eventState.information = connection->information();
    }
  }
  auto events = eventObserver.lock();
  return !events || events->sealed() || events->publish(kind,eventState);
}
std::shared_ptr<SessionEvents> ProtocolSession::subscribeEvents(size_t capacity)
{
  if (processing) throw std::logic_error("Reentrant event subscription");
  if (auto events = eventObserver.lock()) {
    if (!events->sealed()) throw std::logic_error("Session already has an event coordinator");
  }
  auto events = std::make_shared<SessionEvents>(eventState,capacity);
  eventObserver = events;
  return events;
}
void ProtocolSession::authenticating()
{
  if (eventState.state == SessionState::Authenticating) return;
  eventState.state = SessionState::Authenticating;
  if (!emit(SessionEventKind::State)) throw std::runtime_error("Session event queue overflow");
}
uint64_t ProtocolSession::requestRefresh(uint64_t operation)
{
  const bool ownCompletion = operation == 0;
  if (processing) throw std::logic_error("Reentrant refresh");
  auto events = eventObserver.lock();
  if (!connection || !connection->ready || !events || events->sealed()) return 0;
  if (operation && !events->pending(operation, publisher.generation())) return 0;
  if (!operation) operation = events->reserve(publisher.generation());
  if (!operation) {
    if (events->sealed()) finish(true);
    return 0;
  }
  processing = true;
  try {
    connection->refreshFramebuffer();
    if (ownCompletion) events->complete(operation,OperationResult::Succeeded);
    processing = false;
  } catch (...) {
    processing = false;
    if (ownCompletion) events->complete(operation,OperationResult::Failed);
    finish(true);
    throw;
  }
  return operation;
}
uint64_t ProtocolSession::applyEncodingOptions(const EncodingOptions& options, uint64_t operation)
{
  const bool ownCompletion = operation == 0;
  if (processing) throw std::logic_error("Reentrant option application");
  auto events = eventObserver.lock();
  if (!connection || !connection->ready || !events || events->sealed()) return 0;
  if (operation && !events->pending(operation, publisher.generation())) return 0;
  if (!operation) operation = events->reserve(publisher.generation());
  if (!operation) {
    if (events->sealed()) finish(true);
    return 0;
  }
  // The validated snapshot and setters contain only fixed-size value state.
  encoding = options;
  connection->configureEncoding();
  scheduleStatistics(); // Publish the new requested policy even on an idle desktop.
  if (ownCompletion) events->complete(operation, OperationResult::Succeeded);
  return operation;
}
uint64_t ProtocolSession::offerClipboard(ClipboardLease text, uint64_t operation)
{
  const bool ownCompletion = operation == 0;
  if (processing) throw std::logic_error("Reentrant clipboard offer");
  auto events = eventObserver.lock();
  if (!text || text->fromRemote() || !connection || !connection->ready || !events || events->sealed() ||
      clipboardMailbox->checkLocal(text) != ClipboardResult::Accepted) return 0;
  if (operation && !events->pending(operation,publisher.generation())) return 0;
  if (!operation) operation = events->reserve(publisher.generation());
  if (!operation) {
    if (events->sealed()) finish(true);
    return 0;
  }
  processing = true;
  try {
    clipboardMailbox->invalidate();
    connection->offerClipboard(std::move(text));
    if (ownCompletion) events->complete(operation,OperationResult::Succeeded);
    processing = false;
  } catch (...) {
    processing = false;
    if (ownCompletion) events->complete(operation,OperationResult::Failed);
    finish(true); throw;
  }
  return operation;
}
uint64_t ProtocolSession::clearClipboard(uint64_t operation)
{
  const bool ownCompletion = operation == 0;
  if (processing) throw std::logic_error("Reentrant clipboard withdrawal");
  auto events = eventObserver.lock();
  if (!connection || !connection->ready || !events || events->sealed()) return 0;
  if (operation && !events->pending(operation,publisher.generation())) return 0;
  if (!operation) operation = events->reserve(publisher.generation());
  if (!operation) {
    if (events->sealed()) finish(true);
    return 0;
  }
  processing = true;
  try {
    connection->offerClipboard({});
    if (ownCompletion) events->complete(operation,OperationResult::Succeeded);
    processing = false;
  } catch (...) {
    processing = false;
    if (ownCompletion) events->complete(operation,OperationResult::Failed);
    finish(true); throw;
  }
  return operation;
}
uint64_t ProtocolSession::requestDesktopLayout(const RemoteDesktopLayout& layout,
                                              uint64_t operation, uint64_t origin)
{
  if (processing) throw std::logic_error("Reentrant desktop layout request");
  auto events = eventObserver.lock();
  if (!connection || !connection->ready || !events || events->sealed() ||
      !connection->server.supportsSetDesktopSize || eventState.resizePending || inputMailbox->status().viewOnly ||
      size_t(layout.width()) > size_t(std::numeric_limits<int>::max()) / 4 / layout.height() ||
      size_t(layout.width()) * 4 > buffers.framebufferBytes / layout.height()) return 0;
  if (operation && !events->pending(operation, publisher.generation())) return 0;
  rfb::ScreenSet screens;
  for (const auto& screen : layout.screens())
    screens.add_screen(rfb::Screen(screen.id, screen.x, screen.y, screen.width, screen.height, screen.flags));
  if (!operation) operation = events->reserve(publisher.generation(), origin);
  if (!operation) {
    if (events->sealed()) finish(true);
    return 0;
  }
  processing = true;
  desktopResizeOperation = operation;
  try {
    const auto generation = publisher.generation();
    desktopResizeTimer = scheduler.scheduleAt(deadlineAfter(timing.desktopResizeTimeout), [this, generation] {
      desktopResizeTimer = {};
      if (!connection || publisher.generation() != generation || !desktopResizeOperation) return;
      if (auto observer = eventObserver.lock())
        observer->complete(desktopResizeOperation, OperationResult::Failed, OperationFailure::TimedOut);
      desktopResizeOperation = 0;
      // RFB replies have no transaction ID. Keep resizePending until a reply or
      // reconnect, so a late reply can never be mistaken for a subsequent request.
    });
    if (!desktopResizeTimer) throw std::runtime_error("Session timer queue full");
    eventState.resizePending = true;
    connection->writer()->writeSetDesktopSize(layout.width(), layout.height(), screens);
    if (!emit(SessionEventKind::Desktop)) throw std::runtime_error("Session event queue overflow");
    processing = false;
  } catch (...) {
    processing = false;
    finish(true);
    throw;
  }
  return operation;
}
SessionScheduler::TimePoint ProtocolSession::deadlineAfter(std::chrono::milliseconds interval) const
{
  const auto now = timing.now();
  if (now > SessionScheduler::TimePoint::max() - interval)
    throw std::overflow_error("Session timer deadline overflow");
  return now + interval;
}
void ProtocolSession::scheduleStatistics()
{
  auto events = eventObserver.lock();
  if (!events || events->sealed() || statisticsTimer.pending()) return;
  const auto generation = publisher.generation();
  statisticsTimer = scheduler.scheduleAt(deadlineAfter(timing.statisticsInterval), [this, generation] {
    statisticsTimer = {};
    if (!connection || publisher.generation() != generation) return;
    if (!emit(SessionEventKind::Statistics)) throw std::runtime_error("Session event queue overflow");
  });
  if (!statisticsTimer) throw std::runtime_error("Session timer queue full");
}
void ProtocolSession::publicationResult(bool published)
{
  if (published) {
    publicationTimer.cancel(); publicationTimer = {};
    return;
  }
  if (publicationTimer.pending()) return;
  const auto generation = publisher.generation();
  publicationTimer = scheduler.scheduleAt(deadlineAfter(timing.publicationRetryInterval), [this, generation] {
    publicationTimer = {};
    if (connection && publisher.generation() == generation) connection->publish();
  });
  if (!publicationTimer) throw std::runtime_error("Session timer queue full");
}
bool ProtocolSession::nextDeadline(SessionScheduler::TimePoint& deadline) const
{
  return scheduler.nextDeadline(deadline);
}
size_t ProtocolSession::dispatchScheduled(size_t budget)
{
  if (processing) throw std::logic_error("Reentrant timer processing");
  if (!budget) throw std::invalid_argument("Zero timer dispatch budget");
  processing = true;
  try {
    const auto count = scheduler.dispatchDue(timing.now(), budget);
    processing = false;
    return count;
  } catch (...) {
    processing = false;
    finish(true);
    throw;
  }
}
}
