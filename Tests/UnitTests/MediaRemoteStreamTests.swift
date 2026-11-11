import XCTest
@testable import Switchly

private final class FakeMediaRemoteChild: MediaRemoteChildProcess {
    var isRunning = false
    var launches = 0
    var terminations = 0
    var kills = 0
    var launchFails = false
    var output: ((MediaRemoteProcessOutput) -> Void)?
    func launch(output: @escaping (MediaRemoteProcessOutput) -> Void) throws {
        launches += 1
        if launchFails { throw MediaRemoteFailure.launchFailed }
        isRunning = true
        self.output = output
    }
    func terminate() { terminations += 1 }
    func kill() { kills += 1; isRunning = false }
}

final class MediaRemoteStreamTests: XCTestCase {
    private let full = Data("{\"type\":\"data\",\"diff\":false,\"payload\":{}}\n".utf8)

    func testUTF8SplitAcrossReadsAndMultipleLines() throws {
        let data = Data("{\"type\":\"data\",\"diff\":false,\"payload\":{\"title\":\"音乐\"}}\n".utf8)
        var parser = MediaRemoteLineDecoder()
        var events: [MediaRemoteEvent] = []
        for byte in data + full { try parser.consume(Data([byte])) { events.append($0) } }
        try parser.finish()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].fields[.title], .string("音乐"))
    }

    func testLimitIsCheckedBeforeNewlineAndBufferIsReleased() throws {
        var parser = MediaRemoteLineDecoder(limit: 50)
        XCTAssertThrowsError(try parser.consume(Data(repeating: 65, count: 51)) { _ in }) {
            XCTAssertEqual($0 as? MediaRemoteFailure, .lineTooLong)
        }
        var count = 0
        try parser.consume(full) { _ in count += 1 }
        XCTAssertEqual(count, 1)
        XCTAssertNoThrow(try parser.consume(Data(repeating: 65, count: 49)) { _ in })
        XCTAssertThrowsError(try parser.finish())
    }

    func testPartialEOFAndMalformedTypesAreRejected() throws {
        var parser = MediaRemoteLineDecoder()
        try parser.consume(Data("{".utf8)) { _ in }
        XCTAssertThrowsError(try parser.finish()) { XCTAssertEqual($0 as? MediaRemoteFailure, .truncatedLine) }
        for json in ["{}", "{\"type\":\"data\",\"diff\":1,\"payload\":{}}",
                     "{\"type\":\"data\",\"diff\":false,\"payload\":{\"playing\":1}}",
                     "{\"type\":\"data\",\"diff\":false,\"payload\":{\"duration\":true}}"] {
            XCTAssertThrowsError(try MediaRemoteEvent.decode(Data(json.utf8)))
        }
    }

    func testEmptyFullSnapshotStartsStreamAndStderrIsOnlyADiagnostic() {
        let child = FakeMediaRemoteChild()
        let stream = MediaRemoteStream(startupSeconds: 0.05, terminationSeconds: 0.01, makeChild: { child })
        let diagnostic = expectation(description: "脱敏诊断仅一次")
        let noFailure = expectation(description: "合法空快照不触发静默重启")
        noFailure.isInverted = true
        stream.start {
            switch $0 {
            case .diagnostic: diagnostic.fulfill()
            case .failed: noFailure.fulfill()
            case .data: break
            }
        }
        child.output?(.stdout(full))
        child.output?(.stderr)
        child.output?(.stderr)
        wait(for: [diagnostic, noFailure], timeout: 0.12)
        XCTAssertEqual(child.launches, 1)
        stream.stop()
    }

    func testStartupTimeoutDoesNotRestartUntilStopped() {
        let child = FakeMediaRemoteChild()
        let stream = MediaRemoteStream(startupSeconds: 0.02, terminationSeconds: 0.01, makeChild: { child })
        let failed = expectation(description: "启动超时")
        let id = stream.start {
            if case .failed(_, .startupTimeout) = $0 { failed.fulfill() }
        }
        wait(for: [failed], timeout: 1)
        XCTAssertEqual(stream.start { _ in }, id)
        XCTAssertEqual(child.launches, 1)
        stream.stop()
        XCTAssertNotEqual(stream.start { _ in }, id)
        XCTAssertEqual(child.launches, 2)
        stream.stop()
    }

    func testDiffBeforeFullFailsAndStopsChild() {
        let child = FakeMediaRemoteChild()
        let stream = MediaRemoteStream(terminationSeconds: 0.01, makeChild: { child })
        var failure: MediaRemoteFailure?
        stream.start { if case .failed(_, let reason) = $0 { failure = reason } }
        child.output?(.stdout(Data("{\"type\":\"data\",\"diff\":true,\"payload\":{}}\n".utf8)))
        XCTAssertEqual(failure, .missingFullSnapshot)
        XCTAssertEqual(child.terminations, 1)
        stream.stop()
    }

    func testExitLaunchFailureAndOversizedLineAreFailures() {
        for (output, expected) in [(MediaRemoteProcessOutput.exited(17), MediaRemoteFailure.exited(17)),
                                   (.stdout(Data(repeating: 65, count: 65)), .lineTooLong),
                                   (.readFailed, .pipeFailed)] {
            let child = FakeMediaRemoteChild()
            let stream = MediaRemoteStream(terminationSeconds: 0.01, lineLimit: 64, makeChild: { child })
            var failure: MediaRemoteFailure?
            stream.start { if case .failed(_, let reason) = $0 { failure = reason } }
            child.output?(output)
            XCTAssertEqual(failure, expected)
            stream.stop()
        }
        let child = FakeMediaRemoteChild(); child.launchFails = true
        let stream = MediaRemoteStream(makeChild: { child })
        var failure: MediaRemoteFailure?
        stream.start { if case .failed(_, let reason) = $0 { failure = reason } }
        XCTAssertEqual(failure, .launchFailed)
        stream.stop()
    }

    func testLateOldProcessOutputCannotReachNewConnection() {
        let first = FakeMediaRemoteChild(), second = FakeMediaRemoteChild()
        var children = [first, second]
        let stream = MediaRemoteStream(terminationSeconds: 0.01, makeChild: { children.removeFirst() })
        stream.start { _ in }
        let old = first.output
        stream.stop()
        var count = 0
        stream.start { if case .data = $0 { count += 1 } }
        old?(.stdout(full))
        old?(.exited(0))
        XCTAssertEqual(count, 0)
        second.output?(.stdout(full))
        XCTAssertEqual(count, 1)
        stream.stop()
    }

    func testStopAndDeinitEscalateForOnlyTheirOwnChild() {
        let child = FakeMediaRemoteChild()
        var stream: MediaRemoteStream? = MediaRemoteStream(terminationSeconds: 0.01, makeChild: { child })
        stream?.start { _ in }
        stream?.stop()
        stream?.stop()
        stream = nil
        let done = expectation(description: "清理期限结束")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(child.terminations, 1)
        XCTAssertEqual(child.kills, 1)
    }

    func testRealPerlChildHandlesArgumentsWithSpacesAndStops() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mediaremote fixture \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("mediaremote-adapter.pl")
        try """
        use strict; use warnings;
        $|=1;
        die "wrong arguments" unless $ARGV[0] =~ /MediaRemoteAdapter.framework$/ && $ARGV[1] eq 'stream';
        print STDERR "private fixture data must never enter diagnostic callbacks\\n";
        print '{"type":"data","diff":false,"payload":{}}' . "\\n";
        sleep 30;
        """.write(to: script, atomically: true, encoding: .utf8)
        let child = FoundationMediaRemoteChildProcess(configuration: MediaRemoteLaunchConfiguration(directory: directory))
        let stream = MediaRemoteStream(terminationSeconds: 0.02, makeChild: { child })
        let received = expectation(description: "真实管道事件")
        stream.start { if case .data = $0 { received.fulfill() } }
        wait(for: [received], timeout: 3)
        stream.stop()
        let stopped = expectation(description: "真实子进程退出")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { stopped.fulfill() }
        wait(for: [stopped], timeout: 1)
        XCTAssertFalse(child.isRunning)
    }
}
