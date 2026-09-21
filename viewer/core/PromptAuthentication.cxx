/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "PromptAuthentication.h"
#include "CertificatePolicy.h"
#include <rfb/RSAAESKey.h>
#include <condition_variable>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <utility>

namespace viewer {
namespace {
const size_t maxIdentity = 64 * 1024;
const size_t maxText = 4096;
void wipe(std::vector<char>& value)
{
  volatile char* bytes = value.data();
  for (size_t i = 0; i < value.size(); ++i) bytes[i] = 0;
  value.clear();
}
void identity(AuthenticationPrompt& prompt, const uint8_t* bytes, size_t length)
{
  if (!bytes || !length || length > maxIdentity)
    throw std::invalid_argument("Invalid prompt identity size");
  prompt.identity.assign(bytes, bytes + length);
}
}
struct PromptAuthentication::Impl {
  enum class Status { Waiting, Replied, Interrupted };
  Impl(RequestReady notify_, std::chrono::milliseconds timeout_) : notify(notify_), timeout(timeout_) {}
  ~Impl() { wipe(username); wipe(password); }
  const RequestReady notify;
  const std::chrono::milliseconds timeout;
  std::mutex mutex;
  std::condition_variable changed;
  bool accepting = false, outstanding = false, delivered = false, allowed = false;
  uint64_t generation = 0, lastId = 0;
  std::string serverName;
  AuthenticationPrompt prompt;
  std::chrono::steady_clock::time_point deadline;
  Status status = Status::Waiting;
  PromptCancelReason reason = PromptCancelReason::Cancelled;
  std::vector<char> username, password;

  void interrupt(PromptCancelReason why) {
    accepting = false;
    reason = why;
    status = Status::Interrupted;
    wipe(username); wipe(password);
    changed.notify_all();
  }
  void finish() {
    wipe(username); wipe(password);
    prompt = AuthenticationPrompt();
    outstanding = delivered = false;
  }
  PromptReply check(uint64_t id, uint64_t gen, bool credentials) {
    if (!outstanding || status != Status::Waiting) return PromptReply::NoPendingRequest;
    if (id != prompt.id || gen != prompt.generation) return PromptReply::StaleRequest;
    if (std::chrono::steady_clock::now() >= deadline) {
      interrupt(PromptCancelReason::TimedOut);
      return PromptReply::Expired;
    }
    if ((prompt.kind == PromptKind::Credentials) != credentials) return PromptReply::WrongKind;
    return PromptReply::Accepted;
  }
};
PromptAuthentication::PromptAuthentication(RequestReady notify, std::chrono::milliseconds timeout)
  : impl(new Impl(notify, timeout))
{
  if (timeout.count() <= 0 || timeout > std::chrono::hours(24))
    throw std::invalid_argument("Prompt timeout must be positive and at most 24 hours");
}
PromptAuthentication::~PromptAuthentication() = default;
void PromptAuthentication::beginAttempt(uint64_t generation, const std::string& serverName)
{
  if (serverName.size() > maxText || serverName.find('\0') != std::string::npos)
    throw std::invalid_argument("Invalid prompt server name");
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (impl->outstanding) throw std::logic_error("Prompt worker has not drained");
  if (!generation || generation <= impl->generation)
    throw std::invalid_argument("Prompt generation must advance");
  impl->serverName = serverName;
  impl->generation = generation;
  impl->accepting = true;
}
void PromptAuthentication::cancelPending() noexcept { cancel(); }
void PromptAuthentication::cancel(PromptCancelReason reason)
{
  std::lock_guard<std::mutex> lock(impl->mutex);
  // Cancellation wins if an accepted reply has not yet been consumed.
  impl->interrupt(reason);
}
bool PromptAuthentication::takeRequest(AuthenticationPrompt& output)
{
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (!impl->outstanding || impl->delivered || impl->status != Impl::Status::Waiting)
    return false;
  if (std::chrono::steady_clock::now() >= impl->deadline) {
    impl->interrupt(PromptCancelReason::TimedOut);
    return false;
  }
  output = impl->prompt;
  impl->delivered = true;
  return true;
}
void PromptAuthentication::cancelAttempt(uint64_t generation, PromptCancelReason reason)
{
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (generation == impl->generation) impl->interrupt(reason);
}
PromptReply PromptAuthentication::replyCredentials(uint64_t id, uint64_t generation,
  const std::string& username, const std::string& password, bool passwordOnly)
{
  std::lock_guard<std::mutex> lock(impl->mutex);
  const auto result = impl->check(id, generation, true);
  if (result != PromptReply::Accepted) return result;
  if (passwordOnly && impl->prompt.usernameRequired) return PromptReply::WrongKind;
  if (username.size() > maxText || password.size() > maxText) return PromptReply::TooLarge;
  try {
    if (impl->prompt.usernameRequired)
      impl->username.assign(username.begin(), username.end());
    impl->password.assign(password.begin(), password.end());
  } catch (...) { wipe(impl->username); wipe(impl->password); throw; }
  impl->status = Impl::Status::Replied;
  impl->changed.notify_all();
  return PromptReply::Accepted;
}
PromptReply PromptAuthentication::replyTrust(uint64_t id, uint64_t generation, bool allowed)
{
  std::lock_guard<std::mutex> lock(impl->mutex);
  const auto result = impl->check(id, generation, false);
  if (result != PromptReply::Accepted) return result;
  if (allowed && impl->prompt.kind == PromptKind::Certificate &&
      !certificatePolicy(impl->prompt.certificateStatus).mayOverride)
    return PromptReply::PolicyRejected;
  if (allowed && impl->prompt.kind == PromptKind::HostKey &&
      !rfb::validRSAKeyEncoding(impl->prompt.identity.data(),impl->prompt.identity.size()))
    return PromptReply::PolicyRejected;
  impl->allowed = allowed;
  impl->status = Impl::Status::Replied;
  impl->changed.notify_all();
  return PromptReply::Accepted;
}
bool PromptAuthentication::request(AuthenticationPrompt prompt, std::string* username,
                                   std::string* password)
{
  std::unique_lock<std::mutex> lock(impl->mutex);
  if (!impl->accepting) throw PromptInterrupted(impl->reason);
  if (impl->outstanding) throw std::logic_error("Only one prompt worker is permitted");
  if (impl->lastId == std::numeric_limits<uint64_t>::max())
    throw std::overflow_error("Prompt IDs exhausted");
  prompt.id = ++impl->lastId;
  prompt.generation = impl->generation;
  prompt.serverName = impl->serverName;
  impl->prompt = std::move(prompt);
  impl->deadline = std::chrono::steady_clock::now() + impl->timeout;
  impl->status = Impl::Status::Waiting;
  impl->outstanding = true;
  impl->delivered = false;
  lock.unlock();
  try {
    if (impl->notify) impl->notify();
  } catch (...) {
    lock.lock(); impl->finish(); impl->accepting = false; throw;
  }
  lock.lock();
  try {
    while (impl->status == Impl::Status::Waiting) {
      if (impl->changed.wait_until(lock, impl->deadline) == std::cv_status::timeout &&
          impl->status == Impl::Status::Waiting)
        impl->interrupt(PromptCancelReason::TimedOut);
    }
    if (impl->status == Impl::Status::Interrupted) throw PromptInterrupted(impl->reason);
    if (username) username->assign(impl->username.begin(), impl->username.end());
    if (password) password->assign(impl->password.begin(), impl->password.end());
    const bool allowed = impl->allowed;
    impl->finish();
    return allowed;
  } catch (...) { impl->finish(); throw; }
}
void PromptAuthentication::credentials(bool secure, std::string* username, std::string* password)
{
  credentialsForSecurity(0, secure, username, password);
}
void PromptAuthentication::credentialsForSecurity(uint32_t securityType, bool secure, std::string* username, std::string* password)
{
  if (!password) throw std::invalid_argument("Missing password output");
  AuthenticationPrompt prompt;
  prompt.kind = PromptKind::Credentials;
  prompt.secure = secure;
  prompt.securityType = securityType;
  prompt.usernameRequired = username != nullptr;
  request(std::move(prompt), username, password);
}
bool PromptAuthentication::certificate(unsigned int status, const uint8_t* bytes, size_t length)
{
  AuthenticationPrompt prompt;
  prompt.kind = PromptKind::Certificate;
  prompt.certificateStatus = status;
  identity(prompt, bytes, length);
  return request(std::move(prompt));
}
bool PromptAuthentication::hostKey(const uint8_t* bytes, size_t length, const char* fingerprint)
{
  AuthenticationPrompt prompt;
  prompt.kind = PromptKind::HostKey;
  identity(prompt, bytes, length);
  if (!fingerprint) throw std::invalid_argument("Missing host fingerprint");
  size_t count = 0;
  while (count <= maxText && fingerprint[count]) ++count;
  if (count > maxText) throw std::invalid_argument("Host fingerprint too long");
  prompt.fingerprint.assign(fingerprint, count);
  return request(std::move(prompt));
}
}
