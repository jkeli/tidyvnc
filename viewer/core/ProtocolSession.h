/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_PROTOCOL_SESSION_H
#define TIDYVNC_PROTOCOL_SESSION_H

#include <viewer/core/FramePublisher.h>
#include <rfb/SecurityClient.h>
#include <rfb/ClientMessageLimits.h>
#include <memory>
#include <string>

namespace rdr { class InStream; class OutStream; }
namespace viewer {

// Synchronous protocol seam, owned by the host. Native hosts must implement
// their cancellable worker rendezvous here; no UI event loop belongs in core.
class SessionAuthentication {
public:
  virtual ~SessionAuthentication() = default;
  virtual void credentials(bool secure, std::string* username, std::string* password) = 0;
  virtual bool certificate(unsigned int, const uint8_t*, size_t) { return false; }
  virtual bool hostKey(const uint8_t*, size_t, const char*) { return false; }
};
struct SessionBufferLimits {
  size_t framebufferBytes = 64 * 1024 * 1024;
  size_t publicationBytes = 128 * 1024 * 1024;
  size_t subscribers = 16;
};
struct SessionDesktop {
  bool active = false, ready = false;
  uint32_t width = 0, height = 0;
  uint64_t generation = 1, bells = 0;
  std::string name;
};

// A window-independent RFB attempt owner, driven by the host's serialized
// executor. Transport readiness, command/event lifecycle and async drain are
// separate layers. Only subscription take/release may run on other threads.
// Authentication handlers must not reenter processMessage/close/publication.
class ProtocolSession {
public:
  ProtocolSession(const rfb::SecurityClient& security,
                  const rfb::ClientMessageLimits& messages = rfb::ClientMessageLimits(),
                  const SessionBufferLimits& buffers = SessionBufferLimits(),
                  std::shared_ptr<SessionAuthentication> authentication = nullptr);
  ~ProtocolSession();
  ProtocolSession(const ProtocolSession&) = delete;
  ProtocolSession& operator=(const ProtocolSession&) = delete;

  // Borrowed streams must outlive close(). No socket or native handle is exposed.
  // Start is allowed only without an active attempt; reconnect creates a fresh
  // CConnection, with the same immutable security/limits and newer generation.
  void start(const std::string& serverName, rdr::InStream& input, rdr::OutStream& output);
  bool processMessage();
  void close();
  SessionDesktop desktop() const;
  std::shared_ptr<FrameSubscription> attachView();
  // Dropping the last subscription reference detaches it. Retained leases live on.
  // Retry a backpressured frame/cursor only after a complete protocol update.
  // Returns false while an update is in progress or publication remains blocked.
  bool retryPublication();
  size_t publicationBytesInUse() const;

private:
  class Connection;
  rfb::SecurityClient security;
  const rfb::ClientMessageLimits messages;
  const SessionBufferLimits buffers;
  std::shared_ptr<SessionAuthentication> authentication;
  FramePublisher publisher;
  std::unique_ptr<Connection> connection;
  bool processing = false;
};
}
#endif
