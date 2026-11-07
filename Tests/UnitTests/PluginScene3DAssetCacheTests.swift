//
//  PluginScene3DAssetCacheTests.swift
//  SwitchlyTests
//
//  T06: the cache may only share immutable template assets. These tests keep
//  identity separation, LRU eviction and failure propagation deterministic.
//

import SceneKit
import XCTest
@testable import Switchly

final class PluginScene3DAssetCacheTests: XCTestCase {
    func testIdentityCacheKeyCombinesPluginAndHash() {
        let a = PluginScene3DIdentity(pluginID: "a", assetHash: "hash")
        let b = PluginScene3DIdentity(pluginID: "b", assetHash: "hash")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a.cacheKey, b.cacheKey)
        XCTAssertEqual(a.cacheKey, "a#hash")
    }

    func testSecondRequestForSameIdentityHitsTheCache() throws {
        let cache = PluginScene3DAssetCache(capacity: 4)
        let identity = PluginScene3DIdentity(pluginID: "p", assetHash: "h")
        var loadCount = 0
        let load: () throws -> PluginScene3DAsset = {
            loadCount += 1
            return Self.makeAsset(identity: identity)
        }

        let first = try cache.asset(for: identity, load: load)
        let second = try cache.asset(for: identity, load: load)

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(first.identity, second.identity)
        XCTAssertTrue(first.templateScene === second.templateScene)
        XCTAssertEqual(cache.count, 1)
        XCTAssertNotNil(cache.cachedAsset(for: identity))
    }

    func testDifferentPluginIDsDoNotShareEvenWithSameHash() throws {
        let cache = PluginScene3DAssetCache(capacity: 4)
        var loadCount = 0
        func next(_ id: PluginScene3DIdentity) throws -> PluginScene3DAsset {
            loadCount += 1
            return Self.makeAsset(identity: id)
        }

        let a = PluginScene3DIdentity(pluginID: "a", assetHash: "same")
        let b = PluginScene3DIdentity(pluginID: "b", assetHash: "same")
        let first = try cache.asset(for: a) { try next(a) }
        let second = try cache.asset(for: b) { try next(b) }

        XCTAssertEqual(loadCount, 2)
        XCTAssertFalse(first.templateScene === second.templateScene)
        XCTAssertEqual(cache.count, 2)
    }

    func testLRUEvictsLeastRecentlyUsed() throws {
        let cache = PluginScene3DAssetCache(capacity: 2)
        let a = PluginScene3DIdentity(pluginID: "a", assetHash: "1")
        let b = PluginScene3DIdentity(pluginID: "b", assetHash: "2")
        let c = PluginScene3DIdentity(pluginID: "c", assetHash: "3")

        _ = try cache.asset(for: a) { Self.makeAsset(identity: a) }
        _ = try cache.asset(for: b) { Self.makeAsset(identity: b) }
        // Touch a so b becomes the least recently used entry.
        XCTAssertNotNil(cache.cachedAsset(for: a))
        _ = try cache.asset(for: c) { Self.makeAsset(identity: c) }

        XCTAssertEqual(cache.count, 2)
        XCTAssertNotNil(cache.cachedAsset(for: a))
        XCTAssertNil(cache.cachedAsset(for: b))
        XCTAssertNotNil(cache.cachedAsset(for: c))
    }

    func testZeroCapacityNeverStoresButStillLoads() throws {
        let cache = PluginScene3DAssetCache(capacity: 0)
        let identity = PluginScene3DIdentity(pluginID: "p", assetHash: "h")
        var loadCount = 0
        let load: () throws -> PluginScene3DAsset = {
            loadCount += 1
            return Self.makeAsset(identity: identity)
        }

        XCTAssertNoThrow(try cache.asset(for: identity, load: load))
        XCTAssertNoThrow(try cache.asset(for: identity, load: load))
        XCTAssertEqual(loadCount, 2)
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.cachedAsset(for: identity))
    }

    func testLoaderFailurePropagatesAndIsNotCached() {
        let cache = PluginScene3DAssetCache(capacity: 4)
        let identity = PluginScene3DIdentity(pluginID: "p", assetHash: "h")

        XCTAssertThrowsError(try cache.asset(for: identity) {
            throw PluginScene3DFailure.preflightRejected("too big")
        }) { error in
            XCTAssertEqual(error as? PluginScene3DFailure, .preflightRejected("too big"))
        }
        XCTAssertNil(cache.cachedAsset(for: identity))
        XCTAssertEqual(cache.count, 0)
    }

    func testRemoveAllDropsEverything() throws {
        let cache = PluginScene3DAssetCache(capacity: 4)
        let a = PluginScene3DIdentity(pluginID: "a", assetHash: "1")
        let b = PluginScene3DIdentity(pluginID: "b", assetHash: "2")
        _ = try cache.asset(for: a) { Self.makeAsset(identity: a) }
        _ = try cache.asset(for: b) { Self.makeAsset(identity: b) }
        XCTAssertEqual(cache.count, 2)

        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.cachedAsset(for: a))
        XCTAssertNil(cache.cachedAsset(for: b))
    }

    func testHashIsStableAndContentSensitive() {
        let data = Data("glb".utf8)
        XCTAssertEqual(PluginScene3DAssetCache.hash(data), PluginScene3DAssetCache.hash(data))
        XCTAssertNotEqual(PluginScene3DAssetCache.hash(data), PluginScene3DAssetCache.hash(Data("GLB".utf8)))
    }

    // MARK: - Helpers

    /// The cache only ever reads `identity`; a bare SCNScene is enough.
    private static func makeAsset(identity: PluginScene3DIdentity) -> PluginScene3DAsset {
        PluginScene3DAsset(
            identity: identity,
            templateScene: SCNScene(),
            nodeNames: [],
            fileBytes: 0,
            report: GLBPreflight.Report(
                nodeNames: [],
                meshCount: 0,
                nodeCount: 0,
                triangleCount: 0,
                decodedTextureBytes: 0
            )
        )
    }
}
