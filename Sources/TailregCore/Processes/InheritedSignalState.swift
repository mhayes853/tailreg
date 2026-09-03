#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Gives the current process the signal state of a freshly launched program.
///
/// `exec` resets handled signals to their default disposition, but it preserves both the blocked
/// signal mask and any disposition left at `SIG_IGN`. Neither Foundation's `Process` nor a plain
/// `execvp` clears them: a child inherits the mask of whichever thread spawned it, and Swift
/// concurrency worker threads block nearly every signal. A process that inherits that mask never
/// observes SIGTERM or SIGINT at all, so a graceful stop silently degrades into the escalated
/// SIGKILL — the one signal that cannot be blocked.
///
/// Call this early in any process Tailreg expects to stop gracefully, and in the helper that
/// execs an application on its behalf.
public func resetInheritedSignalState() {
  var empty = sigset_t()
  sigemptyset(&empty)
  sigprocmask(SIG_SETMASK, &empty, nil)

  // `signal` rather than a `sigaction` query: restoring a default that is already in place is a
  // no-op, which avoids depending on the platform spelling of the `sigaction` handler union.
  for number in 1..<signalUpperBound where number != SIGKILL && number != SIGSTOP {
    _ = signal(number, SIG_DFL)
  }
}

private var signalUpperBound: Int32 {
  #if canImport(Darwin)
    Int32(NSIG)
  #else
    Int32(_NSIG)
  #endif
}
