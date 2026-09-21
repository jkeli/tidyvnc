/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_LISTENER_SOURCE_H
#define TIDYVNC_LISTENER_SOURCE_H
#include <viewer/platform/SessionTransport.h>
#include <string>
#include <vector>
#include <stdexcept>
namespace viewer {
struct ListenerAddress { std::string host; uint16_t port = 0; };
enum class ListenerErrorCode { None, Cancelled, Bind, Accept, InvalidAddress, Unsupported, EventOverflow, Internal };
class ListenerError : public std::runtime_error {
public:
  ListenerError(ListenerErrorCode code_, int nativeError_ = 0)
    : std::runtime_error("Listener failed"), code(code_), nativeError(nativeError_) {}
  const ListenerErrorCode code;
  const int nativeError;
};
struct IncomingTransport {
  ListenerAddress peer;
  std::unique_ptr<SessionTransport> transport;
};
// Prepared single-use source. start()/wait() run only on the listener worker.
// Null wait results mean wake/deadline, not EOF. Control cancellation must wake
// either method directly; retained controls remain safe after source destruction.
// No protocol data is consumed until ownership transfers to a session worker.
class ListenerSource {
public:
  virtual ~ListenerSource() = default;
  virtual std::shared_ptr<TransportControl> control() const = 0;
  virtual std::vector<ListenerAddress> start() = 0;
  virtual std::unique_ptr<IncomingTransport> wait(SessionTransport::TimePoint deadline) = 0;
};
}
#endif
