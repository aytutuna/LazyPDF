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
    static func isRunning(_ processId: Int) -> Bool {
        if processId == 0 { return false }
        #if canImport(Darwin) || canImport(Glibc)
        guard let pid = pid_t(exactly: processId) else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
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
}
