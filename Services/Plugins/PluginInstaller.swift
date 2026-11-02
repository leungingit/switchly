import Foundation
import Darwin

protocol PluginInstalling {
    func install(directory: URL) throws -> PluginManifest
    func uninstall(id: String) throws
}

/// 第一阶段只接受用户选择的本地目录。校验失败、复制失败均保留当前版本。
final class PluginInstaller: PluginInstalling {
    private let destination: URL
    private let builtinIDs: () -> Set<String>
    private let fileManager: FileManager

    init(destination: URL = PluginRegistry.defaultDirectory,
         builtinIDs: @escaping () -> Set<String> = {
             guard let directory = PluginRegistry.builtinDirectory else { return [] }
             return Set(PluginRegistry(directory: directory, origin: .builtin).reload().plugins.map { $0.manifest.id })
         }, fileManager: FileManager = .default) {
        self.destination = destination
        self.builtinIDs = builtinIDs
        self.fileManager = fileManager
    }

    func install(directory: URL) throws -> PluginManifest {
        let package = try PluginPackageValidator.load(directory: directory, origin: .user, fileManager: fileManager)
        guard !builtinIDs().contains(package.manifest.id) else {
            throw PluginPackageValidator.Failure(reason: "a preinstalled plugin already uses this ID")
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let transaction = destination.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: transaction) }
        let candidate = transaction.appendingPathComponent("candidate", isDirectory: true)
        try fileManager.copyItem(at: directory, to: candidate)
        // 再检查副本，拒绝复制过程中变化或越界的包。
        let copied = try PluginPackageValidator.load(directory: candidate, origin: .user, fileManager: fileManager)
        guard copied.manifest == package.manifest, copied.source == package.source else {
            throw PluginPackageValidator.Failure(reason: "package changed while copying")
        }
        let target = destination.appendingPathComponent(package.manifest.id, isDirectory: true)
        if fileManager.fileExists(atPath: target.path) {
            // 两个目录在同一文件系统：交换名称是单次原子操作，失败不动健康版本。
            guard renamex_np(candidate.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // candidate 此时是旧版本，由事务目录清理。
        } else {
            try fileManager.moveItem(at: candidate, to: target)
        }
        return copied.manifest
    }

    func uninstall(id: String) throws {
        guard id.range(of: #"^[A-Za-z0-9]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil,
              !builtinIDs().contains(id) else {
            throw PluginPackageValidator.Failure(reason: "preinstalled or invalid plugin cannot be uninstalled")
        }
        let target = destination.appendingPathComponent(id)
        guard target.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
            throw PluginPackageValidator.Failure(reason: "invalid plugin location")
        }
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
    }
}
