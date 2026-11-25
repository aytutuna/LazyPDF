import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WinSDK)
import WinSDK
#endif

// Whether a process is still there, for the recovery entries of a crash. Kept apart because WinSDK defines a UUID of its own.

enum ProcessCheck {
    /// When this process started, nil where the system does not say.
    static let launched: Date? = startTime(Int(ProcessInfo.processInfo.processIdentifier))

    /// `started` is when the entry's process started; a live process that started at another time is a later one with the
    /// same id.
    static func isRunning(_ processId: Int, started: Date? = nil) -> Bool {
        if processId <= 0 { return false }
        #if canImport(Darwin) || canImport(Glibc)
        guard let pid = pid_t(exactly: processId) else { return false }
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        if let started, let now = startTime(processId) { return abs(now.timeIntervalSince(started)) < 2 }
        return true
        #elseif canImport(WinSDK)
        guard let pid = DWORD(exactly: processId),
              let process = OpenProcess(DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, pid) else { return false }
        defer { CloseHandle(process) }
        var code: DWORD = 0
        return GetExitCodeProcess(process, &code) && code == DWORD(STILL_ACTIVE)
        #else
        return false
        #endif
    }

    private static func startTime(_ processId: Int) -> Date? {
        #if canImport(Darwin)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(processId)]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
        #else
        return nil
        #endif
    }
}
