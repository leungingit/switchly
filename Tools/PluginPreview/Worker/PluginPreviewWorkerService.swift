import Darwin
import Foundation

final class PluginPreviewWorkerDiagnostics: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func log(_ message: String) {
        let line = "[PluginPreviewWorker] \(String(message.prefix(500)))\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: data)
    }
}

struct PluginPreviewWorkerService {
    static let toolVersion = PluginPreviewContract.toolVersion

    let input: FileHandle
    let output: FileHandle
    let error: FileHandle

    init(input: FileHandle, output: FileHandle, error: FileHandle) {
        self.input = input
        self.output = output
        self.error = error
    }

    /// Entry point for Build/PreviewWorkerMain.swift. The original stdout is
    /// duplicated for frames, then fd 1 is sent to `/dev/null` before any plugin
    /// runs. AppLogger and plugin console output may contain fixture data, so
    /// neither raw stream is retained; only worker-owned diagnostic codes go to
    /// stderr.
    static func runStandardStreams() -> Int32 {
        let frameFD = dup(STDOUT_FILENO)
        guard frameFD >= 0 else {
            fputs("preview worker could not isolate stdout\n", stderr)
            return 74
        }
        let nullFD = open("/dev/null", O_WRONLY)
        guard nullFD >= 0 else {
            close(frameFD)
            fputs("preview worker could not open log sink\n", stderr)
            return 74
        }
        guard dup2(nullFD, STDOUT_FILENO) >= 0 else {
            close(nullFD)
            close(frameFD)
            fputs("preview worker could not suppress logs\n", stderr)
            return 74
        }
        close(nullFD)
        let frameHandle = FileHandle(fileDescriptor: frameFD, closeOnDealloc: true)
        let service = PluginPreviewWorkerService(
            input: .standardInput,
            output: frameHandle,
            error: .standardError
        )
        let code = service.run()
        try? frameHandle.close()
        return code
    }

    func run() -> Int32 {
        let diagnostics = PluginPreviewWorkerDiagnostics(handle: error)
        let writer = PluginPreviewWorkerFrameWriter(handle: output)
        let session = PluginPreviewWorkerSession(output: writer, diagnostics: diagnostics)
        var decoder = PluginPreviewFrameStreamDecoder<PluginPreviewWorkerPayload>()

        while true {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(input.fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 {
                diagnostics.log("input_read_failed")
                return 74
            }
            if count == 0 { break }
            let chunk = Data(bytes.prefix(count))

            let frames: [PluginPreviewWorkerFrame]
            do {
                frames = try decoder.append(chunk)
            } catch let frameError as PluginPreviewFrameError {
                diagnostics.log("protocol_error code=\(String(describing: frameError))")
                writeProtocolError(writer: writer, generation: session.generation, message: frameError.localizedDescription)
                return 65
            } catch {
                diagnostics.log("protocol_error code=unknown")
                writeProtocolError(writer: writer, generation: session.generation, message: "preview protocol error")
                return 65
            }

            for frame in frames {
                let result = waitForAsync { await session.handle(frame) }
                do {
                    try writer.write(result.response)
                } catch {
                    diagnostics.log("output_write_failed")
                    return 74
                }
                if !result.keepRunning { return 0 }
            }
        }

        do {
            try decoder.finish()
        } catch let frameError as PluginPreviewFrameError {
            diagnostics.log("protocol_error code=\(String(describing: frameError))")
            writeProtocolError(writer: writer, generation: session.generation, message: frameError.localizedDescription)
            return 65
        } catch {
            return 65
        }
        return 0
    }

    private func writeProtocolError(writer: PluginPreviewWorkerFrameWriter, generation: UInt64, message: String) {
        let frame = PluginPreviewWorkerFrame(
            type: PluginPreviewWorkerMessageType.error,
            generation: generation,
            requestID: 0,
            payload: PluginPreviewWorkerPayload(ok: false, errorCode: "protocolError", message: String(message.prefix(500)))
        )
        try? writer.write(frame)
    }

    private func waitForAsync<T>(_ operation: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var value: T?
        Task {
            value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return value!
    }
}
