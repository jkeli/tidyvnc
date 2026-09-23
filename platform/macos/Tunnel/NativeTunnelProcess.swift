// Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
import Darwin
import Dispatch
import Foundation

public enum NativeTunnelExit: Sendable, Equatable {
  case exited(Int32), signalled(Int32)
}

// Owns exactly one posix_spawn child/process group. waitid(WNOWAIT) pins the
// child's PID until group cleanup is issued; only this owner then reaps it.
// All mutable state and signals/reaping serialize under lock. No main-thread
// wait, inherited descriptors, raw stderr retention or shell interpretation.
final class NativeTunnelProcess: @unchecked Sendable {
  private let lock = NSLock()
  private var pid: pid_t = 0
  private var result: NativeTunnelExit?
  private var source: DispatchSourceProcess?
  private var waiters: [CheckedContinuation<NativeTunnelExit,Never>] = []
  private var cancelling = false
  private var exitNotified = false, reapRetryScheduled = false
  private let onExit: @Sendable () -> Void
  private let observeExit: @Sendable (pid_t, UnsafeMutablePointer<siginfo_t>) -> Int32
  private init(observeExit: @escaping @Sendable (pid_t, UnsafeMutablePointer<siginfo_t>) -> Int32,
               onExit: @escaping @Sendable () -> Void) {
    self.observeExit = observeExit; self.onExit = onExit
  }

  static func launch(executable: String, arguments: [String], environment: [String:String],
                     output: NativeTunnelOutput? = nil, standardError: Bool = false,
                     observeExit: @escaping @Sendable (pid_t, UnsafeMutablePointer<siginfo_t>) -> Int32 = {
                       waitid(P_PID,id_t($0),$1,WEXITED | WNOHANG | WNOWAIT)
                     },
                     onExit: @escaping @Sendable () -> Void) throws -> NativeTunnelProcess {
    let writer = try output?.claimWriter()
    var spawned = false
    defer { if !spawned { output?.launchFailed() } }
    guard executable.hasPrefix("/"), !executable.utf8.contains(0), arguments.count <= 128,
          arguments.allSatisfy({ $0.utf8.count <= 8192 && !$0.utf8.contains(0) }),
          environment.count <= 16, environment.allSatisfy({ $0.key.utf8.count <= 4096 && !$0.key.contains("=") &&
            !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) && $0.value.utf8.count <= 4096 }) else {
      throw NativeTunnelError.invalidRequest
    }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw NativeTunnelError.launchFailed }
    defer { posix_spawn_file_actions_destroy(&actions) }
    guard posix_spawnattr_init(&attributes) == 0 else { throw NativeTunnelError.launchFailed }
    defer { posix_spawnattr_destroy(&attributes) }
    for fd in [STDIN_FILENO,STDOUT_FILENO,STDERR_FILENO] {
      if fd == (standardError ? STDERR_FILENO : STDOUT_FILENO), let writer {
        guard posix_spawn_file_actions_adddup2(&actions,writer,fd) == 0,
              posix_spawn_file_actions_addclose(&actions,writer) == 0 else { throw NativeTunnelError.launchFailed }
        continue
      }
      guard posix_spawn_file_actions_addopen(&actions,fd,"/dev/null",fd == STDIN_FILENO ? O_RDONLY : O_WRONLY,0) == 0 else {
        throw NativeTunnelError.launchFailed
      }
    }
    var mask = sigset_t(), defaults = sigset_t()
    sigemptyset(&mask); sigemptyset(&defaults)
    for signal in [SIGTERM,SIGINT,SIGHUP,SIGQUIT,SIGPIPE,SIGCHLD] { sigaddset(&defaults,signal) }
    let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
    guard posix_spawnattr_setflags(&attributes,flags) == 0,
          posix_spawnattr_setpgroup(&attributes,0) == 0,
          posix_spawnattr_setsigmask(&attributes,&mask) == 0,
          posix_spawnattr_setsigdefault(&attributes,&defaults) == 0 else { throw NativeTunnelError.launchFailed }
    let argv = ([executable] + arguments).map { strdup($0) }
    let env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
    defer { for pointer in argv + env { free(pointer) } }
    guard argv.allSatisfy({ $0 != nil }), env.allSatisfy({ $0 != nil }) else { throw NativeTunnelError.launchFailed }
    let owner = NativeTunnelProcess(observeExit:observeExit,onExit:onExit)
    var child: pid_t = 0
    let status = (argv + [nil]).withUnsafeBufferPointer { argv in
      (env + [nil]).withUnsafeBufferPointer { env in
        posix_spawn(&child,executable,&actions,&attributes,argv.baseAddress!,env.baseAddress!)
      }
    }
    guard status == 0 else { throw NativeTunnelError.launchFailed }
    owner.pid = child; spawned = true
    let source = DispatchSource.makeProcessSource(identifier:child,eventMask:.exit,queue:.global(qos:.utility))
    // Retain the owner until exit, even if a cancelled caller drops its handle.
    source.setEventHandler { owner.reap(exitNotification:true) }
    owner.source = source; source.activate()
    output?.didSpawn { [weak owner] in owner?.cancel() }
    owner.reap()
    return owner
  }

  var exit: NativeTunnelExit? { lock.withLock { result } }
  var processIdentifier: pid_t { lock.withLock { pid } }
  func wait() async -> NativeTunnelExit {
    await withCheckedContinuation { continuation in
      let completed = lock.withLock { () -> NativeTunnelExit? in
        if let result { return result }
        waiters.append(continuation); return nil
      }
      if let completed { continuation.resume(returning:completed) }
    }
  }
  func cancel() {
    let schedule = lock.withLock { () -> Bool in
      guard result == nil, !cancelling else { return false }
      cancelling = true; _ = kill(-pid,SIGTERM); return true
    }
    guard schedule else { return }
    DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now() + .milliseconds(250)) { [self] in
      lock.withLock { if result == nil { _ = kill(-pid,SIGKILL) } }
      reap()
    }
  }
  private func reap(exitNotification: Bool = false, retry: Bool = false) {
    var completed: NativeTunnelExit?
    var continuations: [CheckedContinuation<NativeTunnelExit,Never>] = []
    var scheduleRetry = false
    lock.withLock {
      if retry { reapRetryScheduled = false }
      guard result == nil else { return }
      exitNotified = exitNotified || exitNotification
      var information = siginfo_t()
      var observed: Int32
      repeat { observed = observeExit(pid,&information) } while observed == -1 && errno == EINTR
      guard observed == 0, information.si_pid == pid else {
        // Darwin posts NOTE_EXIT before making the child waitable. The process
        // source need not deliver another event after a WNOHANG miss. Retry only
        // after that exit notification, with one pending callback per owner.
        // Keep WNOWAIT and the lock so PID/group identity stays pinned until reap.
        if observed == 0, exitNotified, !reapRetryScheduled {
          reapRetryScheduled = true; scheduleRetry = true
        }
        return
      }
      // The unreaped leader pins this process-group identity while descendants
      // are terminated. Never signal a PID after releasing it with waitpid.
      _ = kill(-pid,SIGKILL)
      var status: Int32 = 0
      var waited: pid_t
      repeat { waited = waitpid(pid,&status,0) } while waited == -1 && errno == EINTR
      guard waited == pid else { return }
      let value: NativeTunnelExit = status & 0x7f == 0 ? .exited((status >> 8) & 0xff) : .signalled(status & 0x7f)
      result = value; completed = value; continuations = waiters; waiters.removeAll()
      source?.cancel(); source = nil
    }
    if scheduleRetry {
      DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now() + .milliseconds(10)) { [self] in
        reap(retry:true)
      }
    }
    if let completed {
      onExit()
      for continuation in continuations { continuation.resume(returning:completed) }
    }
  }
}
