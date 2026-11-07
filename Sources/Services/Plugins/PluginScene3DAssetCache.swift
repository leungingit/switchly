//
//  PluginScene3DAssetCache.swift
//  Switchly
//
//  Process-wide LRU cache for decoded scene3d template assets. The cache only
//  shares immutable templates keyed by plugin ID plus asset hash; every view
//  clones the template and keeps its own camera, surfaces and materials.
//  Decoding happens outside the lock; a concurrent winner replaces the
//  double-checked miss with its equivalent immutable result.
//

import CryptoKit
import Foundation

final class PluginScene3DAssetCache {
    static let shared = PluginScene3DAssetCache()

    private let lock = NSLock()
    private let capacity: Int
    private var assets: [String: PluginScene3DAsset] = [:]
    /// Least-recently-used order, oldest first.
    private var order: [String] = []

    init(capacity: Int = 6) {
        self.capacity = max(0, capacity)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func asset(for identity: PluginScene3DIdentity,
               load: () throws -> PluginScene3DAsset) throws -> PluginScene3DAsset {
        let key = identity.cacheKey
        lock.lock()
        if let cached = assets[key] {
            touch(key, whileLocked: true)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let loaded = try load()

        lock.lock()
        defer { lock.unlock() }
        if let existing = assets[key] {
            touch(key, whileLocked: true)
            return existing
        }
        store(loaded, for: key)
        return loaded
    }

    func cachedAsset(for identity: PluginScene3DIdentity) -> PluginScene3DAsset? {
        lock.lock()
        defer { lock.unlock() }
        guard let asset = assets[identity.cacheKey] else { return nil }
        touch(identity.cacheKey, whileLocked: true)
        return asset
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        assets.removeAll()
        order.removeAll()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return assets.count
    }

    // MARK: - Locked helpers

    private func store(_ asset: PluginScene3DAsset, for key: String) {
        guard capacity > 0 else { return }
        assets[key] = asset
        touch(key, whileLocked: true)
        while order.count > capacity {
            let evicted = order.removeFirst()
            assets.removeValue(forKey: evicted)
        }
    }

    private func touch(_ key: String, whileLocked: Bool) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
