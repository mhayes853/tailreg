import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// A process as it was recorded: the PID, and the start time that proves the PID still names it.
///
/// Tailreg persists PIDs and process-group IDs, and those records can outlive the machine's
/// uptime, so a stored PID alone is not evidence: the kernel recycles PID numbers, and signalling
/// a recycled one would reach an unrelated process. Pairing the number with the start time turns
/// "is this still our process?" into a question that can actually be answered.
public struct RecordedProcess: Hashable, Sendable {
  public let pid: pid_t
  /// Nil when the start time could not be read when the process was recorded.
  public let startedAt: Int64?

  public init?(pid: some BinaryInteger, startedAt: Int64?) {
    guard let pid = pid_t(exactly: pid), pid > 0 else { return nil }
    self.pid = pid
    self.startedAt = startedAt
  }

  /// Takes a PID whose positivity a database CHECK constraint has already established.
  ///
  /// A record that was never stored can still carry a nonsensical PID. That resolves to `.gone`
  /// rather than trapping, which is what a number no process can hold amounts to.
  init(recorded pid: some BinaryInteger, startedAt: Int64?) {
    self.pid = pid_t(truncatingIfNeeded: pid)
    self.startedAt = startedAt
  }

  /// Reads the start time now, for a process that was just launched.
  public init?(observing pid: some BinaryInteger) {
    guard let pid = pid_t(exactly: pid) else { return nil }
    self.init(pid: pid, startedAt: processStartTime(of: pid))
  }

  public var liveness: ProcessLiveness {
    guard let startedAt else { return .unverifiable }
    return processStartTime(of: pid) == startedAt ? .running : .gone
  }
}

/// Whether a recorded process is still the one that was recorded.
public enum ProcessLiveness: Hashable, Sendable {
  /// The PID names a process whose start time matches the record.
  case running
  /// A start time was recorded and no longer matches: the process is provably gone.
  case gone
  /// No start time was recorded, so the identity can neither be confirmed nor disproved.
  case unverifiable
}

/// When a process began, as whole seconds since the epoch.
///
/// Whole seconds are deliberate. The two platforms report start times at different resolutions
/// and in different domains, and both are reduced here to the same absolute second so that a
/// value read now compares equal to one read earlier for the same process.
public func processStartTime(of pid: Int32) -> Int64? {
  guard pid > 0 else { return nil }
  #if canImport(Darwin)
    return darwinProcessStartTime(of: pid)
  #else
    return linuxProcessStartTime(of: pid)
  #endif
}

/// Whether a PID currently names a process at all.
///
/// This says nothing about *which* process: the number may have been recycled since it was
/// recorded. Prefer ``RecordedProcess/liveness`` wherever a start time was recorded with the PID.
public func processIsAlive(_ value: some BinaryInteger) -> Bool {
  let pid = pid_t(truncatingIfNeeded: value)
  guard pid > 0 else { return false }
  return signalReaches(pid)
}

/// Whether `kill` would deliver to this target. `EPERM` counts: the target exists but belongs to
/// another user.
func signalReaches(_ target: pid_t) -> Bool {
  if kill(target, 0) == 0 { return true }
  return errno == EPERM
}

#if canImport(Darwin)

  private func darwinProcessStartTime(of pid: Int32) -> Int64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Int64(info.pbi_start_tvsec)
  }

#else

  /// `/proc/PID/stat` reports a start time in clock ticks since boot, so it is only meaningful
  /// alongside the boot instant. Combining them gives an absolute value that does not repeat
  /// across reboots, which a ticks-since-boot value on its own would.
  private func linuxProcessStartTime(of pid: Int32) -> Int64? {
    guard
      let line = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
      let close = line.lastIndex(of: ")")
    else { return nil }

    // The second field is the executable name in parentheses and may itself contain spaces and
    // parentheses, so the remaining fields are read from the *last* `)`.
    let fields = line[line.index(after: close)...]
      .split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count > 19, let ticks = Int64(fields[19]) else { return nil }

    let ticksPerSecond = sysconf(Int32(_SC_CLK_TCK))
    guard ticksPerSecond > 0, let bootTime = linuxBootTime() else { return nil }
    return bootTime + ticks / Int64(ticksPerSecond)
  }

  private func linuxBootTime() -> Int64? {
    guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else { return nil }
    for line in stat.split(separator: "\n") where line.hasPrefix("btime ") {
      return Int64(line.dropFirst("btime ".count).trimmingCharacters(in: .whitespaces))
    }
    return nil
  }

#endif
