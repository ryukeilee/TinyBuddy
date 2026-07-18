import Darwin
import Foundation

@main
struct TinyBuddyReleaseInstallerCommand {
    private enum ExitCode: Int32 {
        case usage = 64
        case missingPath = 66
        case destinationExists = 73
        case exchangeFailure = 74
        case uncertainExchange = 75
    }

    private enum MarkerWriteOutcome {
        case success
        case writeFailed
        case synchronizationFailed
    }

    private enum Operation {
        case exchange(pathA: String, pathB: String)
        case install(source: String, destination: String)

        var successMarker: [UInt8] {
            switch self {
            case .exchange:
                return Array("TINYBUDDY_RELEASE_INSTALLER_EXCHANGED\n".utf8)
            case .install:
                return Array("TINYBUDDY_RELEASE_INSTALLER_INSTALLED\n".utf8)
            }
        }

        func perform() -> Bool {
            switch self {
            case let .exchange(pathA, pathB):
                return TinyBuddyReleaseInstallerCommand.exchange(
                    pathA: pathA,
                    pathB: pathB
                )
            case let .install(source, destination):
                return TinyBuddyReleaseInstallerCommand.moveExclusive(
                    source: source,
                    destination: destination
                )
            }
        }

        func rollback() -> Bool {
            switch self {
            case let .exchange(pathA, pathB):
                return TinyBuddyReleaseInstallerCommand.exchange(
                    pathA: pathA,
                    pathB: pathB
                )
            case let .install(source, destination):
                return TinyBuddyReleaseInstallerCommand.moveExclusive(
                    source: destination,
                    destination: source
                )
            }
        }
    }

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 5 else {
            fail(reason: "invalid_arguments", exitCode: .usage)
        }

        switch arguments[0] {
        case "exchange":
            guard arguments[1] == "--path-a",
                  arguments[3] == "--path-b" else {
                fail(reason: "invalid_arguments", exitCode: .usage)
            }
        case "install":
            guard arguments[1] == "--source",
                  arguments[3] == "--destination" else {
                fail(reason: "invalid_arguments", exitCode: .usage)
            }
        default:
            fail(reason: "invalid_arguments", exitCode: .usage)
        }

        let firstPath = arguments[2]
        let secondPath = arguments[4]
        guard NSString(string: firstPath).isAbsolutePath,
              NSString(string: secondPath).isAbsolutePath else {
            fail(reason: "path_not_absolute", exitCode: .usage)
        }

        let normalizedFirstPath = URL(fileURLWithPath: firstPath).standardizedFileURL.path
        let normalizedSecondPath = URL(fileURLWithPath: secondPath).standardizedFileURL.path
        guard normalizedFirstPath != normalizedSecondPath else {
            fail(reason: "paths_identical", exitCode: .usage)
        }

        let operation: Operation
        if arguments[0] == "exchange" {
            operation = .exchange(
                pathA: normalizedFirstPath,
                pathB: normalizedSecondPath
            )
        } else {
            operation = .install(
                source: normalizedFirstPath,
                destination: normalizedSecondPath
            )
        }

        guard blockTerminationSignals() else {
            fail(reason: "signal_mask_failed", exitCode: .exchangeFailure)
        }

        guard operation.perform() else {
            fail(operation: operation, error: errno)
        }

        switch writeSuccessMarker(operation.successMarker) {
        case .success:
            return
        case .synchronizationFailed:
            // The complete marker is already externally visible. Keep the
            // completed operation in place so the marker cannot describe a rollback.
            fail(reason: "marker_sync_failed", exitCode: .uncertainExchange)
        case .writeFailed:
            guard operation.rollback() else {
                fail(
                    reason: "marker_write_failed_rollback_failed",
                    exitCode: .uncertainExchange
                )
            }
            fail(reason: "marker_write_failed", exitCode: .exchangeFailure)
        }
    }

    private static func fail(operation: Operation, error: Int32) -> Never {
        switch operation {
        case .exchange:
            switch error {
            case ENOENT, ENOTDIR:
                fail(reason: "path_missing", exitCode: .missingPath)
            case EXDEV:
                fail(reason: "different_volumes", exitCode: .exchangeFailure)
            default:
                fail(reason: "exchange_failed", exitCode: .exchangeFailure)
            }
        case let .install(source, _):
            switch error {
            case EEXIST, ENOTEMPTY:
                fail(reason: "destination_exists", exitCode: .destinationExists)
            case ENOENT, ENOTDIR:
                if pathEntryExists(source) {
                    fail(reason: "destination_parent_missing", exitCode: .missingPath)
                } else {
                    fail(reason: "source_missing", exitCode: .missingPath)
                }
            case EXDEV:
                fail(reason: "different_volumes", exitCode: .exchangeFailure)
            default:
                fail(reason: "install_failed", exitCode: .exchangeFailure)
            }
        }
    }

    private static func blockTerminationSignals() -> Bool {
        var signalSet = sigset_t()
        guard sigemptyset(&signalSet) == 0 else {
            return false
        }
        for signalNumber in [SIGHUP, SIGINT, SIGTERM, SIGPIPE] {
            guard sigaddset(&signalSet, signalNumber) == 0 else {
                return false
            }
        }
        return sigprocmask(SIG_BLOCK, &signalSet, nil) == 0
    }

    private static func exchange(pathA: String, pathB: String) -> Bool {
        renameatx_np(
            AT_FDCWD,
            pathA,
            AT_FDCWD,
            pathB,
            UInt32(RENAME_SWAP)
        ) == 0
    }

    private static func moveExclusive(source: String, destination: String) -> Bool {
        renameatx_np(
            AT_FDCWD,
            source,
            AT_FDCWD,
            destination,
            UInt32(RENAME_EXCL)
        ) == 0
    }

    private static func pathEntryExists(_ path: String) -> Bool {
        var pathStatus = stat()
        return path.withCString { pointer in
            lstat(pointer, &pathStatus) == 0
        }
    }

    private static func writeSuccessMarker(_ successMarker: [UInt8]) -> MarkerWriteOutcome {
        guard writeAll(successMarker, to: STDOUT_FILENO) else {
            return .writeFailed
        }

        while fsync(STDOUT_FILENO) != 0 {
            switch errno {
            case EINTR:
                continue
            case EINVAL, ENOTSUP:
                // Pipes and terminals have no fsync operation. A completed write
                // is already committed to their kernel-managed output buffer.
                return .success
            default:
                return .synchronizationFailed
            }
        }
        return .success
    }

    @discardableResult
    private static func writeAll(_ bytes: [UInt8], to fileDescriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return true
            }

            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func fail(reason: String, exitCode: ExitCode) -> Never {
        writeAll(
            Array("TINYBUDDY_RELEASE_INSTALLER_ERROR reason=\(reason)\n".utf8),
            to: STDERR_FILENO
        )
        Darwin.exit(exitCode.rawValue)
    }
}
