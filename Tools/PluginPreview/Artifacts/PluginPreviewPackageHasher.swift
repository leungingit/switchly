import CryptoKit
import Darwin
import Foundation

/// 按相对路径和内容计算包哈希。路径遍历从已打开的目录描述符开始，
/// 不追随符号链接，也不在检查之后重新打开可被替换的路径。
enum PluginPreviewPackageHasher {
    private struct FileRecord {
        let path: String
        let data: Data
    }

    static func sha256(packageURL: URL) throws -> String {
        let (files, _) = try readPackage(packageURL)
        return digest(files)
    }

    /// 在任务专属目录创建不可混用的包快照；前后哈希不一致时拒绝并删除快照。
    static func snapshot(packageURL: URL, destination: URL) throws -> String {
        let (files, directories) = try readPackage(packageURL)
        let hash = digest(files)
        guard mkdir(destination.path, 0o700) == 0 else { throw PluginPreviewArtifactError.invalidPackage }
        do {
            for path in directories.sorted(by: { $0.count < $1.count }) {
                try FileManager.default.createDirectory(at: destination.appendingPathComponent(path, isDirectory: true),
                                                        withIntermediateDirectories: true)
            }
            for file in files {
                let target = destination.appendingPathComponent(file.path)
                try file.data.write(to: target, options: .withoutOverwriting)
            }
            _ = try PluginPackageValidator.load(directory: destination, origin: .user)
            guard try sha256(packageURL: packageURL) == hash, try sha256(packageURL: destination) == hash else {
                throw PluginPreviewArtifactError.invalidPackage
            }
            return hash
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw PluginPreviewArtifactError.invalidPackage
        }
    }

    private static func readPackage(_ packageURL: URL) throws -> ([FileRecord], [String]) {
        let root = open(packageURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw PluginPreviewArtifactError.invalidPackage }
        defer { close(root) }
        var files: [FileRecord] = []
        var directories: [String] = []
        var entries = 0
        var bytes = 0
        try collect(directory: root, prefix: "", entries: &entries, bytes: &bytes, files: &files, directories: &directories)
        guard !files.isEmpty else { throw PluginPreviewArtifactError.invalidPackage }
        return (files, directories)
    }

    private static func digest(_ files: [FileRecord]) -> String {
        var hash = SHA256()
        for file in files.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            let path = Data(file.path.utf8)
            hash.update(data: lengthPrefix(UInt64(path.count)))
            hash.update(data: path)
            hash.update(data: lengthPrefix(UInt64(file.data.count)))
            hash.update(data: file.data)
        }
        return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func collect(directory: Int32, prefix: String, entries: inout Int, bytes: inout Int,
                                files: inout [FileRecord], directories: inout [String]) throws {
        let copy = dup(directory)
        guard copy >= 0 else { throw PluginPreviewArtifactError.invalidPackage }
        guard let stream = fdopendir(copy) else { close(copy); throw PluginPreviewArtifactError.invalidPackage }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let pointer = readdir(stream) else {
                guard errno == 0 else { throw PluginPreviewArtifactError.invalidPackage }
                break
            }
            let name = withUnsafePointer(to: &pointer.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(validatingUTF8: $0) }
            }
            guard let name else { throw PluginPreviewArtifactError.invalidPackage }
            if name == "." || name == ".." { continue }
            entries += 1
            guard entries <= PluginPackageValidator.maxFiles else { throw PluginPreviewArtifactError.invalidPackage }
            let path = prefix.isEmpty ? name : prefix + "/" + name
            let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw PluginPreviewArtifactError.invalidPackage }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw PluginPreviewArtifactError.invalidPackage }
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR):
                directories.append(path)
                try collect(directory: fd, prefix: path, entries: &entries, bytes: &bytes, files: &files, directories: &directories)
            case mode_t(S_IFREG):
                guard info.st_size >= 0, info.st_size <= PluginPackageValidator.maxPackageBytes - bytes else {
                    throw PluginPreviewArtifactError.invalidPackage
                }
                let expected = Int(info.st_size)
                bytes += expected
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                let data = handle.readData(ofLength: expected + 1)
                var after = stat()
                guard data.count == expected, fstat(fd, &after) == 0,
                      after.st_size == info.st_size,
                      after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                      after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else {
                    throw PluginPreviewArtifactError.invalidPackage
                }
                files.append(FileRecord(path: path, data: data))
            default:
                throw PluginPreviewArtifactError.invalidPackage
            }
        }
    }

    private static func lengthPrefix(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}
