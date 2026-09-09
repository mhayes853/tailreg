import Foundation
import TailregCore

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// A process that does nothing but stay alive, for tests about signalling and process identity.
///
/// Foundation's `Process` gives the child the spawning thread's signal mask, and Swift
/// concurrency threads block nearly everything. Applications launched by `up` get a clean slate
/// from `_exec`; these are launched directly, so the mask is cleared here.
public func launchSleeper(seconds: Int = 60) throws -> LaunchedProcess {
  var empty = sigset_t()
  sigemptyset(&empty)
  pthread_sigmask(SIG_SETMASK, &empty, nil)
  return try SystemProcessLauncher()
    .launch(ProcessCommand(executable: "/bin/sleep", arguments: [String(seconds)]))
}

/// A PID that is certainly free: the process is waited on before the number is handed back, so
/// it is neither alive nor a zombie that `kill(pid, 0)` would still find.
public func reapedPID() async throws -> Int {
  let process = try launchSleeper()
  process.terminate()
  _ = await process.waitForExit()
  return Int(process.pid)
}
