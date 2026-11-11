import Darwin
import Foundation

enum MediaRemoteProcessOutput {
    case stdout(Data), stderr, stdoutClosed, readFailed, exited(Int32)
}

protocol MediaRemoteChildProcess: AnyObject {
    var isRunning: Bool { get }
    func launch(output: @escaping (MediaRemoteProcessOutput) -> Void) throws
    func terminate()
    func kill()
}

struct MediaRemoteLaunchConfiguration {
    let script: URL
    let framework: URL

    /// 由宿主装配层传入包内固定目录，进程封装不决定安装位置。
    init(directory: URL) {
        script = directory.appendingPathComponent("mediaremote-adapter.pl")
        framework = directory.appendingPathComponent("MediaRemoteAdapter.framework", isDirectory: true)
    }
}

/// 仅包装 Foundation 的管道和单个子进程；不使用 shell、不记录 stderr 正文。
final class FoundationMediaRemoteChildProcess: MediaRemoteChildProcess {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let configuration: MediaRemoteLaunchConfiguration

    init(configuration: MediaRemoteLaunchConfiguration) { self.configuration = configuration }
    var isRunning: Bool { process.isRunning }

    func launch(output: @escaping (MediaRemoteProcessOutput) -> Void) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [configuration.script.path, configuration.framework.path, "stream"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { handle in
            do {
                guard let data = try Self.readAvailable(handle) else { return }
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    output(.stdoutClosed)
                } else { output(.stdout(data)) }
            } catch { output(.readFailed) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            do {
                guard let data = try Self.readAvailable(handle) else { return }
                if data.isEmpty { handle.readabilityHandler = nil }
                else { output(.stderr) }
            } catch { output(.readFailed) }
        }
        process.terminationHandler = { [weak self] process in
            output(.exited(process.terminationStatus))
            self?.closePipes()
        }
        do { try process.run() }
        catch { closePipes(); throw MediaRemoteFailure.launchFailed }
        // 父进程不保留写端，否则子进程退出后读端收不到 EOF。
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
    }

    func terminate() { if process.isRunning { process.terminate() } }
    func kill() { if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) } }

    private static func readAvailable(_ handle: FileHandle) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: MediaRemoteBudget.readBytes)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        if count >= 0 { return Data(buffer.prefix(count)) }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return nil }
        throw MediaRemoteFailure.pipeFailed
    }

    private func closePipes() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdout.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForReading.close()
        try? stderr.fileHandleForWriting.close()
    }

    deinit {
        kill()
        closePipes()
    }
}
