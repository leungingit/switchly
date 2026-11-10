import AppKit
import Foundation

/// 独立进程观察正式二进制；只保留目标进程是否上屏／激活及前台是否变化，不读键盘或其他窗口内容。
@main
enum BackgroundInputProbe {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--images-differ", arguments.count == 3 {
            let a = try pixels(at: URL(fileURLWithPath: arguments[1]))
            let b = try pixels(at: URL(fileURLWithPath: arguments[2]))
            guard a != b else { exit(1) }
            print("PASS decoded-pixels-differ")
            return
        }
        guard arguments.count >= 3 else { exit(2) }
        let log = URL(fileURLWithPath: arguments[0])
        let stdout = URL(fileURLWithPath: arguments[1])
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        let output = try FileHandle(forWritingTo: stdout)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[2])
        process.arguments = Array(arguments.dropFirst(3))
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let initialForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var samples = 0
        var visible = 0
        var active = 0
        var foregroundChanges = 0
        var activations = 0
        var maxInterval: Double = 0
        var last = Date()
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.processIdentifier == process.processIdentifier { activations += 1 }
            }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        try process.run()
        let deadline = Date().addingTimeInterval(30)
        var timedOut = false
        repeat {
            let now = Date()
            maxInterval = max(maxInterval, now.timeIntervalSince(last) * 1000)
            last = now
            samples += 1
            let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
            visible += windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.processIdentifier }.count
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if foreground == process.processIdentifier { active += 1 }
            if foreground != initialForeground { foregroundChanges += 1 }
            if now > deadline {
                timedOut = true
                kill(process.processIdentifier, SIGKILL)
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } while process.isRunning
        process.waitUntilExit()
        let result: [String: Any] = ["samples": samples, "onScreenSamples": visible, "activeSamples": active,
            "activationEvents": activations, "foregroundChangedSamples": foregroundChanges,
            "maxIntervalMs": maxInterval, "exitCode": process.terminationStatus, "timedOut": timedOut]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: log)
        // 外部用户切换应用只记录；目标自行上屏／激活是隔离失败。
        guard visible == 0, active == 0, activations == 0, !timedOut else { exit(90) }
        if process.terminationStatus == 0,
           let report = try JSONSerialization.jsonObject(with: Data(contentsOf: stdout)) as? [String: Any],
           report["status"] as? String == "passed", let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count {
            let data = try pixels(at: URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("preview.png"))
            var colors = Set<UInt32>()
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for offset in stride(from: 8, to: bytes.count, by: 4) where bytes[offset + 3] > 0 {
                    colors.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
                }
            }
            guard colors.count > 1 else { exit(91) }
        }
        exit(process.terminationStatus)
    }

    /// 独立解码为 sRGB RGBA，比较像素而不是 PNG 压缩流／元数据；前 8 字节携带尺寸。
    private static func pixels(at url: URL) throws -> Data {
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)), let image = bitmap.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data else { throw NSError(domain: "invalid-image", code: 1) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var size = [UInt32(image.width).bigEndian, UInt32(image.height).bigEndian]
        var data = size.withUnsafeMutableBytes { Data($0) }
        data.append(bytes.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4)
        return data
    }
}
