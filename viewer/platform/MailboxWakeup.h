/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#ifndef TIDYVNC_MAILBOX_WAKEUP_H
#define TIDYVNC_MAILBOX_WAKEUP_H
#include <memory>
namespace viewer {
// Internal coalescing readiness signal, NOT a host callback. May run on any
// producer/coordinator thread, after the mailbox lock is released but while
// other producer locks are held. Only signal an independent dispatcher: never
// call back into the session, run user code, wait for delivery, or throw.
class MailboxWakeup {
public:
  virtual ~MailboxWakeup() = default;
  virtual void wake() noexcept = 0;
};
// Declare before the mailbox lock; arm under that lock, signal after unlocking.
struct MailboxNotification {
  std::shared_ptr<MailboxWakeup> target;
  ~MailboxNotification() { if (target) target->wake(); }
};
}
#endif
