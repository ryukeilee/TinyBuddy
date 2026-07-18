import Darwin
import Foundation
import XCTest

final class TinyBuddyReleaseInstallerCommandTests: XCTestCase {
    private let successMarker = "TINYBUDDY_RELEASE_INSTALLER_EXCHANGED\n"
    private let installedMarker = "TINYBUDDY_RELEASE_INSTALLER_INSTALLED\n"

    func testExchangeSwapsTwoExistingDirectories() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pathA = temporaryDirectory.appendingPathComponent("a", isDirectory: true)
        let pathB = temporaryDirectory.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: pathA, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: pathB, withIntermediateDirectories: false)
        try Data("from-a".utf8).write(to: pathA.appendingPathComponent("marker"))
        try Data("from-b".utf8).write(to: pathB.appendingPathComponent("marker"))

        let result = try runCommand(arguments: exchangeArguments(pathA: pathA, pathB: pathB))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, successMarker)
        XCTAssertEqual(result.standardError, "")
        XCTAssertEqual(
            try String(contentsOf: pathA.appendingPathComponent("marker"), encoding: .utf8),
            "from-b"
        )
        XCTAssertEqual(
            try String(contentsOf: pathB.appendingPathComponent("marker"), encoding: .utf8),
            "from-a"
        )
    }

    func testCommandRejectsInvalidArgumentsWithStableReason() throws {
        let result = try runCommand(arguments: ["not-exchange"])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(
            result.standardError,
            "TINYBUDDY_RELEASE_INSTALLER_ERROR reason=invalid_arguments\n"
        )
    }

    func testCommandRejectsNonAbsolutePathsWithStableReason() throws {
        let result = try runCommand(arguments: [
            "exchange",
            "--path-a", "relative-a",
            "--path-b", "relative-b"
        ])

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(
            result.standardError,
            "TINYBUDDY_RELEASE_INSTALLER_ERROR reason=path_not_absolute\n"
        )
    }

    func testCommandRejectsIdenticalPathsWithStableReason() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let path = temporaryDirectory.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)

        let result = try runCommand(arguments: exchangeArguments(pathA: path, pathB: path))

        XCTAssertEqual(result.exitCode, 64)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(
            result.standardError,
            "TINYBUDDY_RELEASE_INSTALLER_ERROR reason=paths_identical\n"
        )
        XCTAssertFalse(result.standardError.contains(path.path))
    }

    func testCommandRejectsMissingPathWithStableReason() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let existingPath = temporaryDirectory.appendingPathComponent("existing", isDirectory: true)
        let missingPath = temporaryDirectory.appendingPathComponent("private-missing", isDirectory: true)
        try FileManager.default.createDirectory(
            at: existingPath,
            withIntermediateDirectories: false
        )

        let result = try runCommand(arguments: exchangeArguments(
            pathA: existingPath,
            pathB: missingPath
        ))

        XCTAssertEqual(result.exitCode, 66)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(
            result.standardError,
            "TINYBUDDY_RELEASE_INSTALLER_ERROR reason=path_missing\n"
        )
        XCTAssertFalse(result.standardError.contains(temporaryDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: existingPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingPath.path))
    }

    func testBlockedSuccessMarkerSurvivesTerminationSignalAndKeepsExchange() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let pathA = temporaryDirectory.appendingPathComponent("a", isDirectory: true)
        let pathB = temporaryDirectory.appendingPathComponent("b", isDirectory: true)
        try makeExchangeDirectories(pathA: pathA, pathB: pathB)

        let standardOutput = Pipe()
        let filledByteCount = try fillPipe(standardOutput.fileHandleForWriting)
        XCTAssertGreaterThan(filledByteCount, 0)
        let standardError = Pipe()
        let process = Process()
        let terminationExpectation = expectation(description: "installer exits")
        process.executableURL = try releaseInstallerURL()
        process.arguments = exchangeArguments(pathA: pathA, pathB: pathB)
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { _ in
            terminationExpectation.fulfill()
        }
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        XCTAssertTrue(waitForContents("from-b", at: pathA.appendingPathComponent("marker")))
        guard process.isRunning else {
            XCTFail("installer exited before its success marker could be drained")
            return
        }
        XCTAssertEqual(kill(process.processIdentifier, SIGTERM), 0)

        let prefilledData = try readExactly(
            filledByteCount,
            from: standardOutput.fileHandleForReading
        )
        XCTAssertEqual(prefilledData.count, filledByteCount)
        wait(for: [terminationExpectation], timeout: 5)
        guard !process.isRunning else {
            XCTFail("installer did not exit after its stdout pipe was drained")
            return
        }

        let markerData = try readExactly(
            successMarker.utf8.count,
            from: standardOutput.fileHandleForReading
        )
        XCTAssertEqual(String(data: markerData, encoding: .utf8), successMarker)
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(
            String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ),
            ""
        )
        XCTAssertEqual(
            try String(contentsOf: pathA.appendingPathComponent("marker"), encoding: .utf8),
            "from-b"
        )
        XCTAssertEqual(
            try String(contentsOf: pathB.appendingPathComponent("marker"), encoding: .utf8),
            "from-a"
        )
    }

    func testBrokenSuccessMarkerPipeRollsBackExchange() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let pathA = temporaryDirectory.appendingPathComponent("a", isDirectory: true)
        let pathB = temporaryDirectory.appendingPathComponent("b", isDirectory: true)
        try makeExchangeDirectories(pathA: pathA, pathB: pathB)

        let standardOutput = Pipe()
        standardOutput.fileHandleForReading.closeFile()
        let standardError = Pipe()
        let process = Process()
        process.executableURL = try releaseInstallerURL()
        process.arguments = exchangeArguments(pathA: pathA, pathB: pathB)
        process.standardOutput = standardOutput.fileHandleForWriting
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 74)
        XCTAssertEqual(
            String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ),
            "TINYBUDDY_RELEASE_INSTALLER_ERROR reason=marker_write_failed\n"
        )
        XCTAssertEqual(
            try String(contentsOf: pathA.appendingPathComponent("marker"), encoding: .utf8),
            "from-a"
        )
        XCTAssertEqual(
            try String(contentsOf: pathB.appendingPathComponent("marker"), encoding: .utf8),
            "from-b"
        )
    }

    func testBrokenSuccessMarkerWithRollbackFailureUsesDistinctExit() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let pathA = temporaryDirectory.appendingPathComponent("a", isDirectory: true)
        let pathB = temporaryDirectory.appendingPathComponent("b", isDirectory: true)
        try makeExchangeDirectories(pathA: pathA, pathB: pathB)

        let standardOutput = Pipe()
        XCTAssertGreaterThan(try fillPipe(standardOutput.fileHandleForWriting), 0)
        let standardError = Pipe()
        let process = Process()
        let terminationExpectation = expectation(description: "installer exits")
        process.executableURL = try releaseInstallerURL()
        process.arguments = exchangeArguments(pathA: pathA, pathB: pathB)
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { _ in
            terminationExpectation.fulfill()
        }
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        guard waitForContents("from-b", at: pathA.appendingPathComponent("marker")) else {
            XCTFail("installer did not exchange paths before blocking on its success marker")
            return
        }
        try FileManager.default.removeItem(at: pathB)
        standardOutput.fileHandleForReading.closeFile()

        wait(for: [terminationExpectation], timeout: 5)
        guard !process.isRunning else {
            XCTFail("installer did not exit after its success marker pipe broke")
            return
        }

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 75)
        XCTAssertEqual(
            String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ),
            "TINYBUDDY_RELEASE_INSTALLER_ERROR "
                + "reason=marker_write_failed_rollback_failed\n"
        )
        XCTAssertEqual(
            try String(contentsOf: pathA.appendingPathComponent("marker"), encoding: .utf8),
            "from-b"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: pathB.path))
    }

    func testInstallMovesSourceExclusivelyToMissingDestination() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let source = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        let destination = temporaryDirectory.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        try makeInstallSource(at: source)

        let result = try runCommand(arguments: installArguments(
            source: source,
            destination: destination
        ))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, installedMarker)
        XCTAssertEqual(result.standardError, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("marker"), encoding: .utf8),
            "candidate"
        )
    }

    func testInstallRejectsExistingDirectoryWithoutMovingEitherPath() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let source = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        let destination = temporaryDirectory.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        try makeInstallSource(at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("existing-directory".utf8).write(
            to: destination.appendingPathComponent("marker")
        )

        let result = try runCommand(arguments: installArguments(
            source: source,
            destination: destination
        ))

        assertDestinationExists(result, privatePath: destination.path)
        XCTAssertEqual(
            try String(contentsOf: source.appendingPathComponent("marker"), encoding: .utf8),
            "candidate"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("marker"), encoding: .utf8),
            "existing-directory"
        )
    }

    func testInstallRejectsExistingFileWithoutMovingEitherPath() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let source = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        let destination = temporaryDirectory.appendingPathComponent("destination")
        try makeInstallSource(at: source)
        try Data("existing-file".utf8).write(to: destination)

        let result = try runCommand(arguments: installArguments(
            source: source,
            destination: destination
        ))

        assertDestinationExists(result, privatePath: destination.path)
        XCTAssertEqual(
            try String(contentsOf: source.appendingPathComponent("marker"), encoding: .utf8),
            "candidate"
        )
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing-file")
    }

    func testInstallRejectsExistingSymbolicLinkWithoutMovingEitherPath() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let source = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        let destination = temporaryDirectory.appendingPathComponent("destination")
        let linkTarget = temporaryDirectory.appendingPathComponent("link-target")
        try makeInstallSource(at: source)
        try Data("existing-target".utf8).write(to: linkTarget)
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: linkTarget
        )

        let result = try runCommand(arguments: installArguments(
            source: source,
            destination: destination
        ))

        assertDestinationExists(result, privatePath: destination.path)
        XCTAssertEqual(
            try String(contentsOf: source.appendingPathComponent("marker"), encoding: .utf8),
            "candidate"
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
            linkTarget.path
        )
        XCTAssertEqual(try String(contentsOf: linkTarget, encoding: .utf8), "existing-target")
    }

    func testInstallRejectsMissingSourceWithStableReason() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let source = temporaryDirectory.appendingPathComponent("private-missing")
        let destination = temporaryDirectory.appendingPathComponent("destination")

        let result = try runCommand(arguments: installArguments(
            source: source,
            destination: destination
        ))

        XCTAssertEqual(result.exitCode, 66)
        XCTAssertEqual(result.standardOutput, "")
        XCTAssertEqual(
            result.standardError,
            "TINYBUDDY_RELEASE_INSTALLER_ERROR reason=source_missing\n"
        )
        XCTAssertFalse(result.standardError.contains(temporaryDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testInstallBrokenMarkerPipeRestoresSource() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let source = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        let destination = temporaryDirectory.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        try makeInstallSource(at: source)

        let standardOutput = Pipe()
        standardOutput.fileHandleForReading.closeFile()
        let standardError = Pipe()
        let process = Process()
        process.executableURL = try releaseInstallerURL()
        process.arguments = installArguments(source: source, destination: destination)
        process.standardOutput = standardOutput.fileHandleForWriting
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 74)
        XCTAssertEqual(
            String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ),
            "TINYBUDDY_RELEASE_INSTALLER_ERROR reason=marker_write_failed\n"
        )
        XCTAssertEqual(
            try String(contentsOf: source.appendingPathComponent("marker"), encoding: .utf8),
            "candidate"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testInstallRollbackFailureUsesDistinctExit() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let source = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        let destination = temporaryDirectory.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        try makeInstallSource(at: source)

        let standardOutput = Pipe()
        XCTAssertGreaterThan(try fillPipe(standardOutput.fileHandleForWriting), 0)
        let standardError = Pipe()
        let process = Process()
        let terminationExpectation = expectation(description: "installer exits")
        process.executableURL = try releaseInstallerURL()
        process.arguments = installArguments(source: source, destination: destination)
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { _ in
            terminationExpectation.fulfill()
        }
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        guard waitForContents("candidate", at: destination.appendingPathComponent("marker")) else {
            XCTFail("installer did not move source before blocking on its success marker")
            return
        }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("intruder".utf8).write(to: source.appendingPathComponent("marker"))
        standardOutput.fileHandleForReading.closeFile()

        wait(for: [terminationExpectation], timeout: 5)
        guard !process.isRunning else {
            XCTFail("installer did not exit after its success marker pipe broke")
            return
        }
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 75)
        XCTAssertEqual(
            String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ),
            "TINYBUDDY_RELEASE_INSTALLER_ERROR "
                + "reason=marker_write_failed_rollback_failed\n"
        )
        XCTAssertEqual(
            try String(contentsOf: source.appendingPathComponent("marker"), encoding: .utf8),
            "intruder"
        )
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("marker"), encoding: .utf8),
            "candidate"
        )
    }

    func testInstallBlockedMarkerSurvivesTerminationSignalAndKeepsInstall() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let source = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        let destination = temporaryDirectory.appendingPathComponent(
            "destination",
            isDirectory: true
        )
        try makeInstallSource(at: source)

        let standardOutput = Pipe()
        let filledByteCount = try fillPipe(standardOutput.fileHandleForWriting)
        XCTAssertGreaterThan(filledByteCount, 0)
        let standardError = Pipe()
        let process = Process()
        let terminationExpectation = expectation(description: "installer exits")
        process.executableURL = try releaseInstallerURL()
        process.arguments = installArguments(source: source, destination: destination)
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { _ in
            terminationExpectation.fulfill()
        }
        try process.run()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        guard waitForContents("candidate", at: destination.appendingPathComponent("marker")) else {
            XCTFail("installer did not move source before blocking on its success marker")
            return
        }
        XCTAssertEqual(kill(process.processIdentifier, SIGTERM), 0)

        _ = try readExactly(filledByteCount, from: standardOutput.fileHandleForReading)
        wait(for: [terminationExpectation], timeout: 5)
        guard !process.isRunning else {
            XCTFail("installer did not exit after its stdout pipe was drained")
            return
        }
        let markerData = try readExactly(
            installedMarker.utf8.count,
            from: standardOutput.fileHandleForReading
        )

        XCTAssertEqual(String(data: markerData, encoding: .utf8), installedMarker)
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("marker"), encoding: .utf8),
            "candidate"
        )
    }

    private func exchangeArguments(pathA: URL, pathB: URL) -> [String] {
        [
            "exchange",
            "--path-a", pathA.path,
            "--path-b", pathB.path
        ]
    }

    private func installArguments(source: URL, destination: URL) -> [String] {
        [
            "install",
            "--source", source.path,
            "--destination", destination.path
        ]
    }

    private func assertDestinationExists(
        _ result: InstallerCommandResult,
        privatePath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.exitCode, 73, file: file, line: line)
        XCTAssertEqual(result.standardOutput, "", file: file, line: line)
        XCTAssertEqual(
            result.standardError,
            "TINYBUDDY_RELEASE_INSTALLER_ERROR reason=destination_exists\n",
            file: file,
            line: line
        )
        XCTAssertFalse(result.standardError.contains(privatePath), file: file, line: line)
    }

    private func runCommand(arguments: [String]) throws -> InstallerCommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = try releaseInstallerURL()
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        return InstallerCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(
                data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "",
            standardError: String(
                data: standardError.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }

    private func makeExchangeDirectories(pathA: URL, pathB: URL) throws {
        try FileManager.default.createDirectory(at: pathA, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: pathB, withIntermediateDirectories: false)
        try Data("from-a".utf8).write(to: pathA.appendingPathComponent("marker"))
        try Data("from-b".utf8).write(to: pathB.appendingPathComponent("marker"))
    }

    private func makeInstallSource(at source: URL) throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("candidate".utf8).write(to: source.appendingPathComponent("marker"))
    }

    private func fillPipe(_ fileHandle: FileHandle) throws -> Int {
        let fileDescriptor = fileHandle.fileDescriptor
        let originalFlags = fcntl(fileDescriptor, F_GETFL)
        guard originalFlags != -1 else {
            throw posixError()
        }
        guard fcntl(fileDescriptor, F_SETFL, originalFlags | O_NONBLOCK) != -1 else {
            throw posixError()
        }

        var totalByteCount = 0
        var fillError: Error?
        let chunk = [UInt8](repeating: 0x78, count: 16_384)
        chunk.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            while true {
                let written = Darwin.write(fileDescriptor, baseAddress, buffer.count)
                if written > 0 {
                    totalByteCount += written
                } else if written == -1, errno == EINTR {
                    continue
                } else if written == -1, errno == EAGAIN {
                    break
                } else {
                    fillError = posixError()
                    break
                }
            }
        }

        if fillError == nil {
            var byte: UInt8 = 0x78
            while true {
                let written = Darwin.write(fileDescriptor, &byte, 1)
                if written == 1 {
                    totalByteCount += 1
                } else if written == -1, errno == EINTR {
                    continue
                } else if written == -1, errno == EAGAIN {
                    break
                } else {
                    fillError = posixError()
                    break
                }
            }
        }

        let restoreResult = fcntl(fileDescriptor, F_SETFL, originalFlags)
        if let fillError {
            throw fillError
        }
        guard restoreResult != -1 else {
            throw posixError()
        }
        return totalByteCount
    }

    private func readExactly(_ byteCount: Int, from fileHandle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < byteCount {
            guard let next = try fileHandle.read(upToCount: byteCount - data.count),
                  !next.isEmpty else {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.fileReadUnknown.rawValue
                )
            }
            data.append(next)
        }
        return data
    }

    private func waitForContents(_ expectedContents: String, at url: URL) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if (try? String(contentsOf: url, encoding: .utf8)) == expectedContents {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    private func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func releaseInstallerURL() throws -> URL {
        let fileManager = FileManager.default
        let testBundleURL = Bundle(for: Self.self).bundleURL
        let candidates = [
            testBundleURL.deletingLastPathComponent()
                .appendingPathComponent("TinyBuddyReleaseInstaller"),
            testBundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("TinyBuddyReleaseInstaller")
        ]
        return try XCTUnwrap(
            candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }),
            "TinyBuddyReleaseInstaller must be built beside the XCTest bundle"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TinyBuddyReleaseInstallerCommandTests.\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }
}

private struct InstallerCommandResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}
