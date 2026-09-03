import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// When a process began, as whole seconds since the epoch.
///
/// This exists to tell one process from another that happens to hold the same PID. Tailreg
/// persists PIDs and process-group IDs, and those records can outlive the machine's uptime, so a
/// stored PID alone is not evidence: the kernel recycles PID numbers, and signalling a recycled
/// one would reach an unrelated process. Recording the start time alongside the PID turns "is
/// this still our process?" into a question that can actually be answered.
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

/// Whether a PID still identifies the process that was recorded with this start time.
///
/// A `nil` witness means the start time could not be read when the process was recorded, so the
/// identity cannot be confirmed. Callers decide what to do with that; this deliberately reports
/// `false` rather than assuming the process is still ours.
public func processMatches(pid: Int32, startedAt witness: Int64?) -> Bool {
  guard let witness, let current = processStartTime(of: pid) else { return false }
  return current == witness
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
