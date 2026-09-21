/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include "ClipboardChannel.h"
#include <core/string.h>
#include <atomic>
#include <cstring>
#include <limits>
#include <mutex>
#include <stdexcept>
namespace viewer {
struct ClipboardBudget {
  explicit ClipboardBudget(size_t maximum_) : maximum(maximum_) {}
  const size_t maximum;
  std::atomic<size_t> used{0};
};
ClipboardText::ClipboardText(std::string value_, bool remote_, ClipboardRoute route_,
                             std::shared_ptr<ClipboardBudget> budget_)
  : value(std::move(value_)), remote(remote_), routing(route_), budget(std::move(budget_)) {}
ClipboardText::~ClipboardText() { budget->used.fetch_sub(value.size()); }
struct ClipboardChannel::Impl {
  Impl(std::shared_ptr<InputQueue> input_, size_t limit_, size_t retained, ClipboardPolicy policy_)
    : input(std::move(input_)), limit(limit_), budget(std::make_shared<ClipboardBudget>(retained)), policy(policy_) {}
  const std::shared_ptr<InputQueue> input;
  const size_t limit;
  const std::shared_ptr<ClipboardBudget> budget;
  mutable std::mutex mutex;
  ClipboardPolicy policy;
  uint64_t revision = 1, sequence = 0;
  bool changed = false;
  ClipboardUpdate latest;
  std::weak_ptr<MailboxWakeup> wakeup;
  void publish(ClipboardUpdateKind kind, ClipboardRoute routing, ClipboardResult result, ClipboardLease text = {}) {
    if (sequence == std::numeric_limits<uint64_t>::max()) throw std::overflow_error("Clipboard sequence exhausted");
    latest.sequence = ++sequence; latest.kind = kind; latest.route = routing;
    latest.result = result; latest.text = std::move(text); changed = true;
  }
};
ClipboardChannel::ClipboardChannel(std::shared_ptr<InputQueue> input, size_t limit, size_t retained, ClipboardPolicy policy)
  : impl(new Impl(std::move(input),limit,retained,policy))
{
  if (!impl->input || !limit || limit > 16*1024*1024 || retained < limit || retained > 64*1024*1024)
    throw std::invalid_argument("Invalid clipboard limits");
}
ClipboardChannel::~ClipboardChannel() = default;
ClipboardPolicy ClipboardChannel::policy() const { std::lock_guard<std::mutex> lock(impl->mutex); return impl->policy; }
void ClipboardChannel::setPolicy(ClipboardPolicy policy)
{
  MailboxNotification notify;
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (policy.send == impl->policy.send && policy.receive == impl->policy.receive) return;
  if (impl->revision == std::numeric_limits<uint64_t>::max()) throw std::overflow_error("Clipboard policy revision exhausted");
  impl->policy = policy; ++impl->revision;
  impl->publish(ClipboardUpdateKind::Invalidated,{},ClipboardResult::Stale);
  notify.target = impl->wakeup.lock();
}
ClipboardRoute ClipboardChannel::route() const
{
  const auto input = impl->input->status();
  std::lock_guard<std::mutex> lock(impl->mutex);
  ClipboardRoute route; route.generation = input.generation; route.focus = input.routingRevision; route.policy = impl->revision;
  return route;
}
ClipboardResult ClipboardChannel::check(ClipboardRoute route, bool sending) const
{
  const auto input = impl->input->status();
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (route.generation != input.generation || route.focus != input.routingRevision || route.policy != impl->revision)
    return ClipboardResult::Stale;
  if (!input.connected) return ClipboardResult::NotConnected;
  if (input.viewOnly) return ClipboardResult::ViewOnly;
  if (!input.focused) return ClipboardResult::Unfocused;
  if (!(sending ? impl->policy.send : impl->policy.receive)) return ClipboardResult::Disabled;
  return ClipboardResult::Accepted;
}
ClipboardPrepared ClipboardChannel::prepare(const std::string& text, bool remote, ClipboardRoute route)
{
  if (text.size() > impl->limit) return {ClipboardResult::TooLarge,{}};
  if (text.find('\0') != std::string::npos || !core::isValidUTF8(text.data(),text.size()))
    return {ClipboardResult::InvalidText,{}};
  auto normalized = core::convertLF(text.data(),text.size());
  auto budget = impl->budget;
  size_t used = budget->used.load();
  do { if (normalized.size() > budget->maximum - used) return {ClipboardResult::Backpressure,{}}; }
  while (!budget->used.compare_exchange_weak(used,used+normalized.size()));
  ClipboardText* owned;
  const auto bytes = normalized.size();
  try { owned = new ClipboardText(std::move(normalized),remote,route,budget); }
  catch (...) { budget->used.fetch_sub(bytes); throw; }
  // shared_ptr deletes owned (returning its budget) if control-block allocation fails.
  return {ClipboardResult::Accepted,ClipboardLease(owned)};
}
ClipboardResult ClipboardChannel::checkLocal(const ClipboardLease& text) const
{
  if (!text || text->budget != impl->budget) return ClipboardResult::Stale;
  if (text->fromRemote()) return ClipboardResult::Echo;
  return check(text->route(),true);
}
ClipboardPrepared ClipboardChannel::prepareLocal(uint64_t generation, const std::string& text, const ClipboardLease& origin)
{
  auto routing = route();
  if (generation != routing.generation) return {ClipboardResult::Stale,{}};
  const auto allowed = check(routing,true);
  if (allowed != ClipboardResult::Accepted) return {allowed,{}};
  if (origin && origin->fromRemote()) return {ClipboardResult::Echo,{}};
  return prepare(text,false,routing);
}
void ClipboardChannel::offerRemote(bool available)
{
  MailboxNotification notify;
  auto routing = route();
  if (check(routing,false) != ClipboardResult::Accepted) return;
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->publish(available ? ClipboardUpdateKind::Offered : ClipboardUpdateKind::Unavailable,routing,ClipboardResult::Accepted);
  notify.target = impl->wakeup.lock();
}
void ClipboardChannel::receive(const char* text, ClipboardRoute expected)
{
  MailboxNotification notify;
  const auto allowed = check(expected,false);
  if (allowed != ClipboardResult::Accepted) return;
  ClipboardPrepared prepared{ClipboardResult::TooLarge,{}};
  // Release a replaceable mailbox reference before budgeting the latest value.
  { std::lock_guard<std::mutex> lock(impl->mutex); impl->latest.text.reset(); }
  const auto length = ::strnlen(text,impl->limit+1);
  if (length <= impl->limit) prepared = prepare(std::string(text,length),true,expected);
  if (check(expected,false) != ClipboardResult::Accepted) return;
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->publish(prepared.result == ClipboardResult::Accepted ? ClipboardUpdateKind::Text : ClipboardUpdateKind::Rejected,
                expected,prepared.result,std::move(prepared.text));
  notify.target = impl->wakeup.lock();
}
void ClipboardChannel::invalidate()
{
  MailboxNotification notify;
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->publish(ClipboardUpdateKind::Invalidated,{},ClipboardResult::Stale);
  notify.target = impl->wakeup.lock();
}
void ClipboardChannel::setWakeup(std::weak_ptr<MailboxWakeup> wakeup)
{
  MailboxNotification notify;
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->wakeup = std::move(wakeup); notify.target = impl->wakeup.lock();
}
bool ClipboardChannel::take(ClipboardUpdate& update)
{
  const auto routing = route(); const auto allowed = check(routing,false);
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (!impl->changed) return false;
  impl->changed = false;
  if (allowed != ClipboardResult::Accepted || impl->latest.route.generation != routing.generation ||
      impl->latest.route.focus != routing.focus || impl->latest.route.policy != routing.policy) {
    impl->latest.kind = ClipboardUpdateKind::Invalidated; impl->latest.text.reset();
    impl->latest.result = ClipboardResult::Stale;
  }
  update = impl->latest;
  // The consumer owns the lease; taking must not pin an unnecessary second copy.
  impl->latest.text.reset();
  return true;
}
size_t ClipboardChannel::bytesInUse() const { return impl->budget->used.load(); }
}
