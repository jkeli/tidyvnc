/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_PROMPT_AUTHENTICATION_H
#define TIDYVNC_PROMPT_AUTHENTICATION_H

#include <viewer/core/ProtocolSession.h>
#include <rfb/Exception.h>
#include <chrono>
#include <functional>
#include <vector>

namespace viewer {
enum class PromptKind { Credentials, Certificate, HostKey };
enum class PromptCancelReason { Cancelled, TimedOut, PeerClosed };
enum class PromptReply { Accepted, NoPendingRequest, StaleRequest, WrongKind, TooLarge, Expired };
class PromptInterrupted : public rfb::auth_cancelled {
public:
  explicit PromptInterrupted(PromptCancelReason reason_) : reason(reason_) {}
  const PromptCancelReason reason;
};
struct AuthenticationPrompt {
  uint64_t id = 0, generation = 0;
  PromptKind kind = PromptKind::Credentials;
  std::string serverName;
  bool secure = false, usernameRequired = false;
  unsigned int certificateStatus = 0;
  std::vector<uint8_t> identity;
  std::string fingerprint;
};

// One bridge per logical session. Only protocol callbacks wait, on the worker.
// takeRequest/reply/cancel are thread-safe and never wait for worker commands.
// RequestReady runs on the requesting worker OUTSIDE the bridge lock; it must
// enqueue a UI/service notification and return promptly, never enter a GUI loop.
// No user callback is invoked while a bridge mutex is held.
// The host must cancel and drain the requesting worker before destruction or
// beginAttempt(). A notifier must not capture a strong reference to its bridge.
class PromptAuthentication : public SessionAuthentication {
public:
  using RequestReady = std::function<void()>;
  explicit PromptAuthentication(RequestReady notify = RequestReady(),
    std::chrono::milliseconds timeout = std::chrono::seconds(60));
  ~PromptAuthentication() override;
  PromptAuthentication(const PromptAuthentication&) = delete;
  PromptAuthentication& operator=(const PromptAuthentication&) = delete;

  void beginAttempt(uint64_t generation, const std::string& serverName) override;
  void cancelPending() noexcept override;
  void cancel(PromptCancelReason reason = PromptCancelReason::Cancelled);
  bool takeRequest(AuthenticationPrompt& output);
  PromptReply replyCredentials(uint64_t id, uint64_t generation,
                              const std::string& username, const std::string& password);
  PromptReply replyTrust(uint64_t id, uint64_t generation, bool allowed);

  void credentials(bool secure, std::string* username, std::string* password) override;
  bool certificate(unsigned int status, const uint8_t* bytes, size_t length) override;
  bool hostKey(const uint8_t* bytes, size_t length, const char* fingerprint) override;
private:
  struct Impl;
  std::unique_ptr<Impl> impl;
  bool request(AuthenticationPrompt prompt, std::string* username = nullptr,
                std::string* password = nullptr);
};
}
#endif
