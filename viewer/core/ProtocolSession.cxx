/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "ProtocolSession.h"

#include <rfb/CConnection.h>
#include <rfb/Cursor.h>
#include <rfb/CMsgWriter.h>
#include <rfb/Exception.h>
#include <rfb/PixelBuffer.h>
#include <limits>
#include <stdexcept>
#include <utility>
#include <algorithm>
#include <vector>

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
    supportsLocalCursor = true;
    supportsDesktopResize = true;
    held.reserve(owner.buffers.heldKeys);
  }
  bool ready = false;
  uint64_t bells = 0;

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
    if (inUpdate) return false;
    if (!ready) return true;
    // End-of-update normally joined these already. Retrying must not race any
    // decoder work, even when no views are currently attached.
    syncFramebuffer();
    bool published = true;
    if (!damage.is_empty()) {
      auto* framebuffer = getFramebuffer();
      int stride;
      const auto* data = framebuffer->getBuffer(framebuffer->getRect(), &stride);
      PixelView input{data, size_t(stride)*framebuffer->height()*4,
        uint32_t(framebuffer->width()), uint32_t(framebuffer->height()), size_t(stride)*4,
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
    return published;
  }
protected:
  void initDone() override {
    resizeFramebuffer();
    setPF(framebufferFormat());
    ready = true;
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
    damage = {0, 0, width, height};
    if (ready && !owner.emit(SessionEventKind::Desktop))
      throw std::runtime_error("Session event queue overflow");
  }
  void framebufferUpdateStart() override {
    inUpdate = true;
    CConnection::framebufferUpdateStart();
  }
  void framebufferUpdateEnd() override {
    CConnection::framebufferUpdateEnd();
    inUpdate = false;
    publish();
    ++owner.eventState.frames;
    if (!owner.emit(SessionEventKind::Statistics)) throw std::runtime_error("Session event queue overflow");
  }
  bool dataRect(const core::Rect& rectangle, int encoding) override {
    if (!CConnection::dataRect(rectangle, encoding)) return false;
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
  void getUserPasswd(bool secure, std::string* user, std::string* password) override {
    if (!owner.authentication) throw rfb::auth_cancelled();
    owner.authentication->credentials(secure, user, password);
  }
  bool verifyCertificate(unsigned int status, const uint8_t* certificate, size_t length) override {
    return owner.authentication && owner.authentication->certificate(status, certificate, length);
  }
  bool verifyHostKey(const uint8_t* key, size_t length, const char* fingerprint) override {
    return owner.authentication && owner.authentication->hostKey(key, length, fingerprint);
  }
private:
  ProtocolSession& owner;
  core::Rect damage;
  bool inUpdate = false, cursorChanged = false;
  struct HeldKey { uint32_t id, symbol, code; };
  std::vector<HeldKey> held;
  core::Point pointerPosition;
  uint16_t buttons = 0;
};
ProtocolSession::ProtocolSession(const rfb::SecurityClient& security_,
  const rfb::ClientMessageLimits& messages_, const SessionBufferLimits& buffers_,
  std::shared_ptr<SessionAuthentication> authentication_)
  : security(security_), messages(messages_), buffers(buffers_),
    authentication(authentication_), publisher(buffers.publicationBytes, buffers.subscribers),
    inputMailbox(new InputQueue(buffers.inputCommands))
{
  messages.validate();
  if (!buffers.framebufferBytes)
    throw std::invalid_argument("Framebuffer limit must be positive");
  if (!buffers.heldKeys || buffers.heldKeys > 1024)
    throw std::invalid_argument("Invalid held key limit");
}
ProtocolSession::~ProtocolSession()
{
  // Drain before publisher and authentication services go away. The host closes
  // on its worker; destruction must not be delegated to a UI rendering callback.
  close();
  if (auto events = eventObserver.lock()) events->seal(OperationResult::Cancelled);
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
void ProtocolSession::close()
{
  finish(false);
}
void ProtocolSession::finish(bool failed)
{
  if (processing) throw std::logic_error("Reentrant protocol close");
  if (!connection) return;
  inputMailbox->end(publisher.generation() + 1);
  if (authentication) authentication->cancelPending();
  // A dead transport may reject release writes. Still drain and invalidate;
  // never replace the original protocol/IO error with a teardown write error.
  if (connection->ready) {
    try { connection->releaseInput(); } catch (...) {}
  }
  eventState.state = failed ? SessionState::Failed : SessionState::Closed;
  if (auto events = eventObserver.lock())
    events->cancelPending(failed ? OperationResult::Failed : OperationResult::Cancelled);
  emit(SessionEventKind::State);
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
  return !connection || connection->publish();
}
size_t ProtocolSession::publicationBytesInUse() const { return publisher.bytesInUse(); }
std::shared_ptr<InputQueue> ProtocolSession::inputQueue() const { return inputMailbox; }
bool ProtocolSession::drainInput()
{
  if (processing) throw std::logic_error("Reentrant input processing");
  if (!connection || !connection->ready) return true;
  processing = true;
  try {
    InputQueue::Command command;
    bool okay = true;
    for (size_t count = 0; count <= buffers.inputCommands && inputMailbox->take(command); ++count) {
      if (!connection->sendInput(command)) {
        inputMailbox->overflow();
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
uint64_t ProtocolSession::requestRefresh()
{
  if (processing) throw std::logic_error("Reentrant refresh");
  auto events = eventObserver.lock();
  if (!connection || !connection->ready || !events || events->sealed()) return 0;
  const auto operation = events->reserve(publisher.generation());
  if (!operation) {
    if (events->sealed()) finish(true);
    return 0;
  }
  processing = true;
  try {
    connection->refreshFramebuffer();
    events->complete(operation,OperationResult::Succeeded);
    processing = false;
  } catch (...) {
    processing = false;
    events->complete(operation,OperationResult::Failed);
    finish(true);
    throw;
  }
  return operation;
}
}
