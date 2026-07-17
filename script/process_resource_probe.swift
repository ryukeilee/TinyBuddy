import Darwin
import Foundation

private struct ProcessResourceSample {
    let cpuTimeNanoseconds: UInt64
    let diskReadBytes: UInt64
    let interruptWakeups: UInt64
    let idleWakeups: UInt64

    init(pid: pid_t) throws {
        var usage = rusage_info_v4()
        var usagePointer: rusage_info_t? = withUnsafeMutablePointer(to: &usage) { pointer in
            UnsafeMutableRawPointer(pointer)
        }
        let result = withUnsafeMutablePointer(to: &usagePointer) { pointer in
            proc_pid_rusage(pid, RUSAGE_INFO_V4, pointer)
        }
        guard result == 0 else {
            throw ProbeError.rusageFailed(pid: pid, code: errno)
        }

        cpuTimeNanoseconds = usage.ri_user_time
            &+ usage.ri_system_time
            &+ usage.ri_child_user_time
            &+ usage.ri_child_system_time
        diskReadBytes = usage.ri_diskio_bytesread
        interruptWakeups = usage.ri_interrupt_wkups &+ usage.ri_child_interrupt_wkups
        idleWakeups = usage.ri_pkg_idle_wkups &+ usage.ri_child_pkg_idle_wkups
    }

    var csvRow: String {
        "\(cpuTimeNanoseconds),\(diskReadBytes),\(interruptWakeups),\(idleWakeups)"
    }
}

private enum ProbeError: LocalizedError {
    case usage
    case invalidPID(String)
    case rusageFailed(pid: pid_t, code: Int32)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: process_resource_probe <pid>"
        case let .invalidPID(value):
            return "invalid PID: \(value)"
        case let .rusageFailed(pid, code):
            return "proc_pid_rusage(RUSAGE_INFO_V4) failed for PID \(pid): \(String(cString: strerror(code))) (errno \(code))"
        }
    }
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw ProbeError.usage
    }
    guard let pid = pid_t(CommandLine.arguments[1]), pid > 0 else {
        throw ProbeError.invalidPID(CommandLine.arguments[1])
    }

    print(try ProcessResourceSample(pid: pid).csvRow)
} catch {
    fputs("process_resource_probe: \(error.localizedDescription)\n", stderr)
    exit(1)
}
