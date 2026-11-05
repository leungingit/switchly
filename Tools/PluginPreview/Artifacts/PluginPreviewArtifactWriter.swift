import Darwin
import Foundation
import ImageIO

struct PluginPreviewArtifactWriter {
    static let maximumScreenshotBytes = PluginPackageValidator.maxPackageBytes
    private struct WrittenFile { let name: String; let device: dev_t; let inode: ino_t }

    func writeSuccess(
        identity: PluginPreviewArtifactIdentity,
        rawJSON: Data,
        screenshotURL: URL,
        outputDirectory: URL,
        steps: [PluginPreviewStepTrace]? = nil
    ) throws -> PluginPreviewArtifactReport {
        try validate(identity)
        let packageHash = try PluginPreviewPackageHasher.sha256(packageURL: identity.packageURL)
        let slots: [PluginSlotContent]
        do { slots = try PluginRenderOutput.decode(json: rawJSON) }
        catch { throw PluginPreviewArtifactError.invalidRenderOutput }
        let actions = PluginPreviewArtifactBuilder.actions(pluginID: identity.pluginID, slots: slots)
        let screenshot = try loadScreenshot(screenshotURL)
        let outputFD = try openEmptyDirectory(outputDirectory)
        defer { close(outputFD) }
        var written: [WrittenFile] = []
        do {
            // 直接保存通过宿主解码器验证的原始声明式树，避免遗漏控件或 Scene 字段。
            written.append(try write(rawJSON, name: "ui-tree.json", directory: outputFD))
            written.append(try writeJSON(actions, name: "actions.json", directory: outputFD))
            written.append(try write(screenshot, name: "preview.png", directory: outputFD))

            let report = PluginPreviewArtifactReport(
                schemaVersion: 1,
                status: .passed,
                scenarioID: identity.scenarioID,
                pluginID: identity.pluginID,
                pluginVersion: identity.pluginVersion,
                generation: identity.generation,
                packageHash: packageHash,
                artifacts: .complete,
                versions: identity.versions,
                environment: identity.environment,
                failure: nil,
                steps: steps,
                scenarioSource: identity.scenarioSource
            )
            written.append(try writeJSON(report, name: "report.json", directory: outputFD))
            return report
        } catch let error as PluginPreviewArtifactError {
            remove(written, directory: outputFD)
            throw error
        } catch {
            remove(written, directory: outputFD)
            throw PluginPreviewArtifactError.writeFailed
        }
    }

    func writeFailure(
        identity: PluginPreviewArtifactIdentity,
        status: PluginPreviewArtifactStatus,
        failure: PluginPreviewArtifactFailureCode,
        outputDirectory: URL,
        steps: [PluginPreviewStepTrace]? = nil
    ) throws -> PluginPreviewArtifactReport {
        guard status != .passed else { throw PluginPreviewArtifactError.invalidIdentity }
        try validate(identity)
        let packageHash = try PluginPreviewPackageHasher.sha256(packageURL: identity.packageURL)
        let outputFD = try openEmptyDirectory(outputDirectory)
        defer { close(outputFD) }
        let report = PluginPreviewArtifactReport(
            schemaVersion: 1,
            status: status,
            scenarioID: identity.scenarioID,
            pluginID: identity.pluginID,
            pluginVersion: identity.pluginVersion,
            generation: identity.generation,
            packageHash: packageHash,
            artifacts: .reportOnly,
            versions: identity.versions,
            environment: identity.environment,
            failure: PluginPreviewArtifactFailure(failure),
            steps: steps,
            scenarioSource: identity.scenarioSource
        )
        _ = try writeJSON(report, name: "report.json", directory: outputFD)
        return report
    }

    private func validate(_ identity: PluginPreviewArtifactIdentity) throws {
        let values = [identity.scenarioID, identity.pluginID, identity.pluginVersion]
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw PluginPreviewArtifactError.invalidIdentity
        }
    }

    private func loadScreenshot(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw PluginPreviewArtifactError.missingScreenshot }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, isRegular(info) else { throw PluginPreviewArtifactError.missingScreenshot }
        guard info.st_size > 0, info.st_size <= Int64(Self.maximumScreenshotBytes) else {
            throw PluginPreviewArtifactError.invalidScreenshot
        }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readData(ofLength: Self.maximumScreenshotBytes + 1)
        guard data.count == Int(info.st_size) else { throw PluginPreviewArtifactError.invalidScreenshot }
        guard PNGInspector.isValid(data) else { throw PluginPreviewArtifactError.invalidScreenshot }
        return data
    }

    private func openEmptyDirectory(_ directory: URL) throws -> Int32 {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw PluginPreviewArtifactError.writeFailed
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PluginPreviewArtifactError.outputNotEmpty }
        let duplicate = dup(fd)
        guard duplicate >= 0 else { close(fd); throw PluginPreviewArtifactError.writeFailed }
        guard let stream = fdopendir(duplicate) else { close(duplicate); close(fd); throw PluginPreviewArtifactError.writeFailed }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { close(fd); throw PluginPreviewArtifactError.writeFailed }
                return fd
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(validatingUTF8: $0) }
            }
            guard let name else { close(fd); throw PluginPreviewArtifactError.writeFailed }
            if name != "." && name != ".." { close(fd); throw PluginPreviewArtifactError.outputNotEmpty }
        }
    }

    private func writeJSON<T: Encodable>(_ value: T, name: String, directory: Int32) throws -> WrittenFile {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw PluginPreviewArtifactError.writeFailed
        }
        return try write(data, name: name, directory: directory)
    }

    private func write(_ data: Data, name: String, directory: Int32) throws -> WrittenFile {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PluginPreviewArtifactError.writeFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { try? handle.close(); throw PluginPreviewArtifactError.writeFailed }
        let created = WrittenFile(name: name, device: info.st_dev, inode: info.st_ino)
        do { try handle.write(contentsOf: data); try handle.close(); return created }
        catch { try? handle.close(); remove([created], directory: directory); throw PluginPreviewArtifactError.writeFailed }
    }

    private func remove(_ files: [WrittenFile], directory: Int32) {
        for file in files {
            var info = stat()
            if fstatat(directory, file.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
               info.st_dev == file.device, info.st_ino == file.inode {
                _ = unlinkat(directory, file.name, 0)
            }
        }
    }

    private func isRegular(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG
    }
}

private enum PNGInspector {
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    static func isValid(_ data: Data) -> Bool {
        guard data.starts(with: signature),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              width <= PluginPackageValidator.maxPackageBytes / 4 / height,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return false }
        return true
    }
}
