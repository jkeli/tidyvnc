/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "ProtocolSession.h"

#include <rfb/CConnection.h>
#include <rfb/Cursor.h>
#include <rfb/Exception.h>
#include <rfb/PixelBuffer.h>
#include <limits>
#include <stdexcept>
#include <utility>

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
  }
  bool ready = false;
  uint64_t bells = 0;

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
  }
  void framebufferUpdateStart() override {
    inUpdate = true;
    CConnection::framebufferUpdateStart();
  }
  void framebufferUpdateEnd() override {
    CConnection::framebufferUpdateEnd();
    inUpdate = false;
    publish();
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
  void bell() override { ++bells; }
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
};
ProtocolSession::ProtocolSession(const rfb::SecurityClient& security_,
  const rfb::ClientMessageLimits& messages_, const SessionBufferLimits& buffers_,
  std::shared_ptr<SessionAuthentication> authentication_)
  : security(security_), messages(messages_), buffers(buffers_),
    authentication(authentication_), publisher(buffers.publicationBytes, buffers.subscribers)
{
  messages.validate();
  if (!buffers.framebufferBytes)
    throw std::invalid_argument("Framebuffer limit must be positive");
}
ProtocolSession::~ProtocolSession()
{
  // Drain before publisher and authentication services go away. The host closes
  // on its worker; destruction must not be delegated to a UI rendering callback.
  close();
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
  connection = std::move(next);
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
    close();
    throw;
  }
}
void ProtocolSession::close()
{
  if (processing) throw std::logic_error("Reentrant protocol close");
  if (!connection) return;
  // No callbacks are made to views; their queued images are invalidated after
  // decoder work and protocol-owned resources have been drained.
  connection.reset();
  publisher.reset(publisher.generation() + 1);
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
}
