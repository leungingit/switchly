import AppKit
import SwiftUI
import Combine
import Foundation
import XCTest
@testable import Switchly

@MainActor
final class PluginLifecycleTests: XCTestCase {
    private let context = PluginRenderContext(
        bundleID: "com.example.host",
        pid: 42,
        appName: "Host",
        windowID: 7,
        titleSummary: "Window"
    )

    func testDuplicateActionIDsRouteToTheirOwnPlugin() async throws {
        let first = TestRuntime(id: "com.example.first", node: actionNode)
        let second = TestRuntime(id: "com.example.second", node: actionNode)
        let host = TestHost(runtimes: [first, second])
        let model = DockPluginOverlayModel(host: host)
        let rendered = expectation(description: "both plugins rendered")
        rendered.expectedFulfillmentCount = 2
        first.onRender = { rendered.fulfill() }
        second.onRender = { rendered.fulfill() }

        model.start(context: context)
        await fulfillment(of: [rendered], timeout: 1)
        first.onRender = nil
        second.onRender = nil
        let entries = try XCTUnwrap(model.slots[.center])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { $0.node.actionIDs }, [["toggle"], ["toggle"]])
        XCTAssertNotEqual(PluginActionNamespace(pluginID: first.manifest.id, actionID: "toggle").identifier,
                          PluginActionNamespace(pluginID: second.manifest.id, actionID: "toggle").identifier)

        let firstCalled = expectation(description: "first action")
        let secondCalled = expectation(description: "second action")
        first.onAction = { firstCalled.fulfill() }
        second.onAction = { secondCalled.fulfill() }
        model.perform(pluginID: first.manifest.id, actionID: "toggle")
        model.perform(pluginID: second.manifest.id, actionID: "toggle")
        await fulfillment(of: [firstCalled, secondCalled], timeout: 1)

        XCTAssertEqual(first.actions, ["toggle"])
        XCTAssertEqual(second.actions, ["toggle"])
        model.stop()
    }

    func testLegacyPerformStillAcceptsUniqueRawActionID() async throws {
        let runtime = TestRuntime(id: "com.example.legacy", node: actionNode)
        let host = TestHost(runtimes: [runtime])
        let model = DockPluginOverlayModel(host: host)
        let rendered = expectation(description: "plugin rendered")
        runtime.onRender = { rendered.fulfill() }

        model.start(context: context)
        await fulfillment(of: [rendered], timeout: 1)
        runtime.onRender = nil
        let called = expectation(description: "legacy action")
        runtime.onAction = { called.fulfill() }
        model.perform(actionID: "toggle")
        await fulfillment(of: [called], timeout: 1)
        XCTAssertEqual(runtime.actions, ["toggle"])
        model.stop()
    }

    func testActionWaitsForMediaResultBeforePublishingNextRender() async throws {
        let runtime = TestRuntime(id: "com.example.media", node: actionNode)
        let model = DockPluginOverlayModel(host: TestHost(runtimes: [runtime]))
        let initial = expectation(description: "initial render")
        runtime.onRender = { initial.fulfill() }
        model.start(context: context)
        await fulfillment(of: [initial], timeout: 1)
        runtime.onRender = nil

        let actionStarted = expectation(description: "action started")
        var finishAction: (() -> Void)?
        runtime.onActionAsync = {
            await withCheckedContinuation { continuation in
                finishAction = { continuation.resume() }
                actionStarted.fulfill()
            }
        }
        model.perform(actionID: "toggle")
        await fulfillment(of: [actionStarted], timeout: 1)
        runtime.node = .text(value: "paused", style: .body, lines: nil)
        runtime.onInvalidate?()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(model.slots[.center]?.first?.node, actionNode)

        let updated = expectation(description: "render after action")
        runtime.onRender = { updated.fulfill() }
        finishAction?()
        await fulfillment(of: [updated], timeout: 1)
        XCTAssertEqual(model.slots[.center]?.first?.node, .text(value: "paused", style: .body, lines: nil))
        model.stop()
    }

    func testActionReconcilesLaggingExternalStateBeforeNextRefreshTick() async throws {
        let runtime = TestRuntime(id: "com.example.media", node: actionNode)
        let model = DockPluginOverlayModel(host: TestHost(runtimes: [runtime]))
        let initial = expectation(description: "initial render")
        let initialObservation = model.slotsPublisher
            .filter { $0[.center]?.first?.node == self.actionNode }.prefix(1)
            .sink { _ in initial.fulfill() }
        defer { initialObservation.cancel() }
        model.start(context: context)
        await fulfillment(of: [initial], timeout: 1)
        runtime.onRender = nil

        // The first read after the command still sees the old external state;
        // it settles before the bounded follow-up render (well under the 1s loop).
        var reads = 0
        let staleNode = actionNode
        runtime.renderNode = {
            reads += 1
            return reads == 1 ? staleNode : .text(value: "paused", style: .body, lines: nil)
        }
        let reconciled = expectation(description: "bounded reconciliation")
        reconciled.expectedFulfillmentCount = 2
        runtime.onRender = { reconciled.fulfill() }
        let published = expectation(description: "reconciled state published")
        let publication = model.slotsPublisher
            .filter { $0[.center]?.first?.node == .text(value: "paused", style: .body, lines: nil) }.prefix(1)
            .sink { _ in published.fulfill() }
        defer { publication.cancel() }
        model.perform(actionID: "toggle")
        await fulfillment(of: [reconciled, published], timeout: 0.8)
        XCTAssertEqual(model.slots[.center]?.first?.node, .text(value: "paused", style: .body, lines: nil))
        model.stop()
    }

    /// scene3d keys its cover texture by `artworkToken`. A token derived from the
    /// NSImage address could repeat after the old image is freed, so the iPod
    /// kept showing the previous track's cover. Every cover change must mint a
    /// new token, and no cover must clear it.
    func testArtworkTokenChangesWithEveryCover() async throws {
        let runtime = TestRuntime(id: "com.example.media",
                                  node: .image(source: .artwork, size: .l, corner: nil))
        let host = TestHost(runtimes: [runtime])
        let model = DockPluginOverlayModel(host: host)
        var tokens: [String?] = []
        for data in [Self.png(gray: 0.2), nil, Self.png(gray: 0.8)] {
            host.artworkData = data
            let rendered = expectation(description: "render")
            runtime.onRender = { rendered.fulfill() }
            if tokens.isEmpty { model.start(context: context) } else { runtime.onInvalidate?() }
            await fulfillment(of: [rendered], timeout: 1)
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(model.artwork == nil, data == nil)
            tokens.append(model.artworkToken)
        }
        XCTAssertNotNil(tokens[0])
        XCTAssertNil(tokens[1])
        XCTAssertNotNil(tokens[2])
        XCTAssertNotEqual(tokens[0], tokens[2])
        model.stop()
    }

    func testStaleMediaBatchCannotPublishAndNewBatchIsAtomic() async throws {
        let runtime = TestRuntime(id: "com.example.atomic", node: .hstack(children: [
            .text(value: "Old", style: .body, lines: nil), .image(source: .artwork, size: .l, corner: nil)
        ], spacing: nil, align: nil))
        let host = TestHost(runtimes: [runtime])
        let oldImage = NSImage(data: Self.png(gray: 0.2))!
        var oldValid = true
        host.read = MediaReadContext(nowPlaying: nil, artwork: oldImage, artworkToken: "old", validate: { oldValid })
        let model = DockPluginOverlayModel(host: host)
        let began = expectation(description: "old render blocked")
        var finish: (() -> Void)?
        runtime.onRenderAsync = {
            await withCheckedContinuation { continuation in
                finish = { continuation.resume() }
                began.fulfill()
            }
        }
        var publishedTokens: [String?] = []
        let committed = expectation(description: "new batch committed")
        let observation = model.slotsPublisher.dropFirst().sink { slots in
            guard !slots.isEmpty else { return }
            // Published emits before assignment; observe after the main-actor commit.
            DispatchQueue.main.async {
                publishedTokens.append(model.artworkToken)
                committed.fulfill()
            }
        }
        model.start(context: context)
        await fulfillment(of: [began], timeout: 1)
        XCTAssertTrue(model.slots.isEmpty)
        oldValid = false
        host.read = MediaReadContext(nowPlaying: nil, artwork: NSImage(data: Self.png(gray: 0.8)),
                                    artworkToken: "new", validate: { true })
        runtime.node = .hstack(children: [
            .text(value: "New", style: .body, lines: nil), .image(source: .artwork, size: .l, corner: nil)
        ], spacing: nil, align: nil)
        runtime.onRenderAsync = nil
        finish?()
        await fulfillment(of: [committed], timeout: 1)
        XCTAssertEqual(publishedTokens, ["new"])
        XCTAssertEqual(model.slots[.center]?.first?.node, runtime.node)
        model.stop()
        observation.cancel()
    }

    func testMediaNotificationDuringReadCanPublishTheCurrentFirstBatch() async throws {
        let runtime = TestRuntime(id: "com.example.current", node: actionNode)
        let host = TestHost(runtimes: [runtime])
        host.read = MediaReadContext(nowPlaying: nil, artwork: nil, artworkToken: nil,
                                     validateFreshness: { true }, validate: { true })
        let model = DockPluginOverlayModel(host: host)
        let began = expectation(description: "first read began")
        let committed = expectation(description: "current first batch committed")
        var finishFirst: (() -> Void)?
        var finishFollowup: (() -> Void)?
        var reads = 0
        host.onMediaRead = {
            reads += 1
            await withCheckedContinuation { continuation in
                if reads == 1 {
                    finishFirst = { continuation.resume() }
                    began.fulfill()
                } else {
                    finishFollowup = { continuation.resume() }
                }
            }
        }
        let observation = model.slotsPublisher.dropFirst().sink { slots in
            if !slots.isEmpty { committed.fulfill() }
        }
        defer {
            model.stop()
            finishFirst?()
            finishFollowup?()
            observation.cancel()
        }
        model.start(context: context)
        await fulfillment(of: [began], timeout: 1)
        host.mediaInvalidation?()
        let notified = expectation(description: "notification processed")
        DispatchQueue.main.async { notified.fulfill() }
        await fulfillment(of: [notified], timeout: 1)
        finishFirst?()
        finishFirst = nil
        // 后续读取保持挂起；首批必须能独立提交，不能靠重读通过。
        await fulfillment(of: [committed], timeout: 1)
        XCTAssertEqual(model.slots[.center]?.first?.node, actionNode)
    }

    func testNotificationDuringRejectedRetrySchedulesLatestRead() async throws {
        let runtime = TestRuntime(id: "com.example.retry-notification", node: actionNode, refreshInterval: 60)
        let host = TestHost(runtimes: [runtime])
        host.read = MediaReadContext(nowPlaying: nil, artwork: nil, artworkToken: nil, validate: { false })
        let model = DockPluginOverlayModel(host: host)
        let retryBegan = expectation(description: "automatic retry started")
        let committed = expectation(description: "notified latest batch committed without periodic refresh")
        var releaseRetry: (() -> Void)?
        var reads = 0
        host.onMediaRead = {
            reads += 1
            if reads == 2 {
                await withCheckedContinuation { continuation in
                    releaseRetry = { continuation.resume() }
                    retryBegan.fulfill()
                }
            } else if reads == 3 {
                host.read = MediaReadContext(nowPlaying: nil, artwork: nil, artworkToken: nil, validate: { true })
            }
        }
        let observation = model.slotsPublisher.dropFirst().sink { slots in
            if !slots.isEmpty { committed.fulfill() }
        }
        defer { model.stop(); releaseRetry?(); observation.cancel() }
        model.start(context: context)
        await fulfillment(of: [retryBegan], timeout: 1)
        host.mediaInvalidation?()
        let notified = expectation(description: "notification queued while retry is suspended")
        DispatchQueue.main.async { DispatchQueue.main.async { notified.fulfill() } }
        await fulfillment(of: [notified], timeout: 1)
        releaseRetry?(); releaseRetry = nil
        await fulfillment(of: [committed], timeout: 1)
        XCTAssertEqual(reads, 3)
    }

    func testPreparePublishesBeforeMediaAndDoesNotRegisterActions() async throws {
        let runtime = TestRuntime(id: "com.example.prepare-first", node: actionNode)
        let preparedNode = PluginUINode.button(
            id: "toggle", symbol: "play.fill", label: "Play", size: .m,
            variant: .plain, enabled: true, selected: false)
        runtime.prepareContents = { _ in
            [PluginSlotContent(slot: .center, node: preparedNode)]
        }
        let host = TestHost(runtimes: [runtime])
        let model = DockPluginOverlayModel(host: host)
        let mediaStarted = expectation(description: "media read suspended")
        let prepared = expectation(description: "prepare committed before media")
        var finishMedia: (() -> Void)?
        host.onMediaRead = {
            await withCheckedContinuation { continuation in
                finishMedia = { continuation.resume() }
                mediaStarted.fulfill()
            }
        }
        let observation = model.slotsPublisher.dropFirst().sink { slots in
            guard let node = slots[.center]?.first?.node,
                  node.actionIDs == ["toggle"] else { return }
            prepared.fulfill()
        }
        defer {
            finishMedia?()
            model.stop()
            observation.cancel()
        }

        model.start(context: context)
        await fulfillment(of: [mediaStarted, prepared], timeout: 1)

        let actionUnexpected = expectation(description: "prepared action stays unregistered")
        actionUnexpected.isInverted = true
        runtime.onAction = { actionUnexpected.fulfill() }
        model.perform(pluginID: runtime.manifest.id, actionID: "toggle")
        await fulfillment(of: [actionUnexpected], timeout: 0.1)

        XCTAssertEqual(runtime.prepareCallCount, 1)
        XCTAssertTrue(runtime.actions.isEmpty)
        XCTAssertEqual(model.slots[.center]?.first?.node, preparedNode)
    }

    func testLatePrepareCannotOverwriteCommittedFormalRender() async throws {
        let formalNode = PluginUINode.text(value: "Formal", style: .body, lines: nil)
        let preparedNode = PluginUINode.text(value: "Late prepare", style: .body, lines: nil)
        let runtime = TestRuntime(id: "com.example.prepare-late", node: formalNode)
        runtime.prepareContents = { _ in
            [PluginSlotContent(slot: .center, node: preparedNode)]
        }
        let model = DockPluginOverlayModel(host: TestHost(runtimes: [runtime]))
        let prepareStarted = expectation(description: "prepare started")
        let prepareReturned = expectation(description: "prepare returned")
        let formalCommitted = expectation(description: "formal render committed")
        let stalePreparationPublished = expectation(description: "late prepare must not publish")
        stalePreparationPublished.isInverted = true
        var finishPrepare: (() -> Void)?
        runtime.onPrepare = { _ in prepareStarted.fulfill() }
        runtime.onPrepareAsync = {
            await withCheckedContinuation { continuation in
                finishPrepare = { continuation.resume() }
            }
        }
        runtime.onPrepareReturned = { _ in prepareReturned.fulfill() }
        let observation = model.slotsPublisher.dropFirst().sink { slots in
            guard let node = slots[.center]?.first?.node else { return }
            if node == formalNode { formalCommitted.fulfill() }
            if node == preparedNode { stalePreparationPublished.fulfill() }
        }
        defer {
            finishPrepare?()
            model.stop()
            observation.cancel()
        }

        model.start(context: context)
        await fulfillment(of: [prepareStarted, formalCommitted], timeout: 1)
        XCTAssertEqual(model.slots[.center]?.first?.node, formalNode)

        finishPrepare?()
        finishPrepare = nil
        await fulfillment(of: [prepareReturned, stalePreparationPublished], timeout: 0.1)
        XCTAssertEqual(model.slots[.center]?.first?.node, formalNode)
    }

    func testTargetSwitchPreventsLatePreparationFromOverwritingNewGeneration() async throws {
        let firstContext = context
        let secondContext = PluginRenderContext(
            bundleID: "com.example.host",
            pid: 43,
            appName: "Host",
            windowID: 8,
            titleSummary: "Other window"
        )
        let staleNode = PluginUINode.text(value: "Stale", style: .body, lines: nil)
        let freshNode = PluginUINode.text(value: "Fresh", style: .body, lines: nil)
        let runtime = TestRuntime(id: "com.example.prepare-switch", node: freshNode)
        runtime.prepareContents = { call in
            [PluginSlotContent(slot: .center, node: call == 1 ? staleNode : freshNode)]
        }
        let host = TestHost(runtimes: [runtime])
        let model = DockPluginOverlayModel(host: host)
        let firstStarted = expectation(description: "old preparation started")
        let secondStarted = expectation(description: "new preparation started")
        let secondReturned = expectation(description: "new prepare returned")
        let firstReturned = expectation(description: "old prepare returned")
        let freshCommitted = expectation(description: "new initial content committed")
        let stalePublished = expectation(description: "old prepare must not publish")
        stalePublished.isInverted = true
        var finishFirst: (() -> Void)?
        var finishSecond: (() -> Void)?
        var finishMediaReads: [() -> Void] = []
        host.onMediaRead = {
            await withCheckedContinuation { continuation in
                finishMediaReads.append { continuation.resume() }
            }
        }
        runtime.onPrepare = { call in
            if call == 1 { firstStarted.fulfill() } else { secondStarted.fulfill() }
        }
        runtime.onPrepareAsync = {
            await withCheckedContinuation { continuation in
                if runtime.prepareCallCount == 1 {
                    finishFirst = { continuation.resume() }
                } else {
                    finishSecond = { continuation.resume() }
                }
            }
        }
        runtime.onPrepareReturned = { call in
            if call == 1 { firstReturned.fulfill() } else { secondReturned.fulfill() }
        }
        let observation = model.slotsPublisher.dropFirst().sink { slots in
            guard let node = slots[.center]?.first?.node else { return }
            if node == freshNode { freshCommitted.fulfill() }
            if node == staleNode { stalePublished.fulfill() }
        }
        defer {
            finishFirst?()
            finishSecond?()
            finishMediaReads.forEach { $0() }
            model.stop()
            observation.cancel()
        }

        model.start(context: firstContext)
        await fulfillment(of: [firstStarted], timeout: 1)
        model.start(context: secondContext)
        await fulfillment(of: [secondStarted], timeout: 1)

        finishSecond?()
        finishSecond = nil
        await fulfillment(of: [secondReturned, freshCommitted], timeout: 1)
        XCTAssertEqual(model.slots[.center]?.first?.node, freshNode)

        finishFirst?()
        finishFirst = nil
        await fulfillment(of: [firstReturned, stalePublished], timeout: 0.1)
        XCTAssertEqual(model.slots[.center]?.first?.node, freshNode)
    }

    func testProtocolDefaultPrepareReturnsNoInitialSlots() async throws {
        let runtime = TestRuntime(id: "com.example.default-prepare", node: actionNode)
        let prepared = try await runtime.prepare(context: context).get()
        XCTAssertEqual(prepared, [])
    }

    func testRenderWithoutArtworkNodeClearsPreviousImage() async throws {
        let runtime = TestRuntime(id: "com.example.image", node: .image(source: .artwork, size: .l, corner: nil))
        let host = TestHost(runtimes: [runtime])
        host.read = MediaReadContext(nowPlaying: nil, artwork: NSImage(data: Self.png(gray: 0.2)),
                                    artworkToken: "cover", validate: { true })
        let model = DockPluginOverlayModel(host: host)
        model.start(context: context)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNotNil(model.artwork)
        runtime.node = .text(value: "No image", style: .body, lines: nil)
        runtime.onInvalidate?()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertNil(model.artwork)
        XCTAssertNil(model.artworkToken)
        model.stop()
    }

    /// 保存实际共享视图的浅/深色 fixture 渲染，供本轮眼见核验；不触达真实播放器。
    func testAtomicDisplayFixtureRendersInBothAppearances() throws {
        let data = Self.png(gray: 0.5)
        let image = try XCTUnwrap(MediaArtworkDecoder.decode(data))
        let node = PluginUINode.hstack(children: [
            .image(source: .artwork, size: .l, corner: nil),
            .vstack(children: [.text(value: "Media snapshot", style: .title, lines: nil),
                               .text(value: "Atomic artwork fixture", style: .caption, lines: nil)], spacing: nil, align: nil)
        ], spacing: .m, align: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("switchly-mr-t03-t04")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let view = NSHostingView(rootView: PluginOverlayView(node: node, material: .legacyDefault,
                isGlassActive: false, artwork: image, artworkToken: "fixture", onAction: { _, _ in })
                .padding(20).frame(width: 360, height: 120)
                .background(scheme == .dark ? Color.black : Color.white).environment(\.colorScheme, scheme))
            view.frame = CGRect(x: 0, y: 0, width: 360, height: 120)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("atomic-\(name).png"))
        }
    }

    private static func png(gray: CGFloat) -> Data {
        let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }

    func testDestroyingOneOverlayDoesNotUnmountSharedHost() {
        let runtime = TestRuntime(id: "com.example.shared", node: actionNode)
        let host = TestHost(runtimes: [runtime])
        do { let overlay = DockPluginOverlayModel(host: host); _ = overlay }
        XCTAssertEqual(runtime.unmountCount, 0)
    }

    func testStopRejectsRuntimeDiscoveryThatFinishesLate() async {
        let runtime = TestRuntime(id: "com.example.late-load", node: actionNode)
        let host = TestHost(runtimes: [runtime])
        let began = expectation(description: "runtime discovery began")
        let returned = expectation(description: "runtime discovery returned")
        var finish: (() -> Void)?
        host.onLoad = {
            await withCheckedContinuation { continuation in
                finish = { continuation.resume() }
                began.fulfill()
            }
            returned.fulfill()
        }
        let model = DockPluginOverlayModel(host: host)
        defer { model.stop(); finish?() }
        model.start(context: context)
        await fulfillment(of: [began], timeout: 1)
        model.stop()
        finish?()
        finish = nil
        await fulfillment(of: [returned], timeout: 1)
        let drained = expectation(description: "late result drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertEqual(runtime.resumeCount, 0)
        XCTAssertTrue(model.slots.isEmpty)
    }

    func testStartResumesAndStopSuspendsWithoutUnmounting() async {
        let runtime = TestRuntime(id: "com.example.lifecycle", node: actionNode)
        let host = TestHost(runtimes: [runtime])
        let model = DockPluginOverlayModel(host: host)

        let first = expectation(description: "first runtime resumed")
        runtime.onResume = { first.fulfill() }
        model.start(context: context)
        await fulfillment(of: [first], timeout: 1)
        XCTAssertEqual(runtime.resumeCount, 1)
        XCTAssertEqual(runtime.suspendCount, 0)
        XCTAssertEqual(runtime.unmountCount, 0)

        model.stop()
        XCTAssertEqual(runtime.suspendCount, 1)
        XCTAssertEqual(runtime.unmountCount, 0)

        let second = expectation(description: "second runtime resumed")
        runtime.onResume = { second.fulfill() }
        model.start(context: context)
        await fulfillment(of: [second], timeout: 1)
        XCTAssertEqual(runtime.resumeCount, 2)
        model.stop()
    }

    func testAuthorizationRefreshDetachesPreviouslyVisibleRuntime() async {
        let runtime = TestRuntime(id: "com.example.revoked", node: actionNode)
        let host = TestHost(runtimes: [runtime])
        let model = DockPluginOverlayModel(host: host)
        let resumed = expectation(description: "runtime resumed before revocation")
        runtime.onResume = { resumed.fulfill() }
        model.start(context: context)
        await fulfillment(of: [resumed], timeout: 1)
        host.runtimes = []
        model.reloadCurrentContext()
        XCTAssertEqual(runtime.suspendCount, 1)
        XCTAssertTrue(model.slots.isEmpty)
        XCTAssertNil(runtime.onInvalidate)
    }

    func testSuspendReleasesPendingCallAndPausesTimers() async throws {
        let source = """
        let fired = 0;
        let latestCtx = null;
        globalThis.__switchlyPlugin = {
          render() {
            return [{ slot: "center", node: { type: "badge", value: String(fired), tone: "neutral" } }];
          },
          onAction(ctx) {
            latestCtx = ctx;
            return new Promise(function (resolve) {
              setTimeout(function () {
                fired += 1;
                latestCtx.invalidate();
                resolve();
              }, 40);
            });
          }
        };
        """
        let (runtime, root) = try makeRuntime(source: source, timeout: 1)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await runtime.render(context: context).get()

        let invalidated = expectation(description: "timer resumed")
        let invalidations = LockedCounter()
        runtime.onInvalidate = {
            invalidations.increment()
            invalidated.fulfill()
        }
        let pendingAction = Task {
            await runtime.performAction(id: "start", value: nil, context: self.context)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        runtime.suspend()

        let result = await pendingAction.value
        XCTAssertEqual(result.map { _ in 0 }, .failure(.suspended))
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertEqual(invalidations.value, 0)

        runtime.resume()
        await fulfillment(of: [invalidated], timeout: 1)
        let rendered = try await runtime.render(context: context).get()
        XCTAssertEqual(rendered.first?.node, .badge(value: "1", tone: .neutral))
    }

    func testStorageIsInjectedIntoPluginContext() async throws {
        let source = """
        globalThis.__switchlyPlugin = {
          async render(ctx) {
            await ctx.storage.set("count", 7);
            const value = await ctx.storage.get("count");
            return [{ slot: "center", node: { type: "text", value: String(value) } }];
          }
        };
        """
        let storage = TestStorage()
        let (runtime, root) = try makeRuntime(source: source, timeout: 1, storage: storage)
        defer { try? FileManager.default.removeItem(at: root) }

        let rendered = try await runtime.render(context: context).get()
        XCTAssertEqual(rendered.first?.node, .text(value: "7", style: .body, lines: nil))
        XCTAssertEqual((storage.values["count"] as? NSNumber)?.intValue, 7)
    }

    func testUnmountDoesNotWaitForBusyPluginQueue() async throws {
        let source = """
        globalThis.__switchlyPlugin = {
          render() {
            const until = Date.now() + 120;
            while (Date.now() < until) {}
            return [];
          }
        };
        """
        let (runtime, root) = try makeRuntime(source: source, timeout: 0.02)
        defer { try? FileManager.default.removeItem(at: root) }
        let rendering = Task { await runtime.render(context: self.context) }
        try await Task.sleep(nanoseconds: 10_000_000)

        let started = DispatchTime.now().uptimeNanoseconds
        runtime.unmount()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        XCTAssertLessThan(elapsed, 50)
        _ = await rendering.value
    }

    private var actionNode: PluginUINode {
        .button(id: "toggle", symbol: "play.fill", label: "Play", size: .m,
                variant: .plain, enabled: true, selected: false)
    }

    private func makeRuntime(source: String,
                             timeout: TimeInterval,
                             storage: PluginStorageProviding? = nil) throws -> (PluginRuntime, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginLifecycleTests-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("plugin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
        {"id":"com.example.lifecycle","name":{"en":"Lifecycle"},"version":"1","apiVersion":1,
         "matches":["com.example.host"],"permissions":[],"entry":"main.js"}
        """
        try manifest.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try source.write(to: directory.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        let package = try XCTUnwrap(PluginRegistry(directory: root).reload().plugins.first)
        return (PluginRuntime(package: package, timeout: timeout, storage: storage), root)
    }
}

private final class TestRuntime: PluginRuntimeProtocol {
    let manifest: PluginManifest
    var node: PluginUINode
    var onInvalidate: (() -> Void)?
    var assetDirectory: URL? { nil }
    var onPrepare: ((Int) -> Void)?
    var prepareContents: ((Int) -> [PluginSlotContent])?
    var onPrepareAsync: (() async -> Void)?
    var onPrepareReturned: ((Int) -> Void)?
    private let prepareLock = NSLock()
    private var prepareCalls = 0
    var prepareCallCount: Int {
        prepareLock.lock()
        defer { prepareLock.unlock() }
        return prepareCalls
    }
    var onRender: (() -> Void)?
    var renderNode: (() -> PluginUINode)?
    var onRenderAsync: (() async -> Void)?
    var onAction: (() -> Void)?
    var onActionAsync: (() async -> Void)?
    var onResume: (() -> Void)?
    private(set) var actions: [String] = []
    private(set) var suspendCount = 0
    private(set) var resumeCount = 0
    private(set) var unmountCount = 0

    init(id: String, node: PluginUINode, refreshInterval: TimeInterval? = nil) {
        self.manifest = PluginManifest(
            id: id,
            name: ["en": id],
            version: "1",
            apiVersion: 1,
            matches: ["com.example.host"],
            permissions: [],
            entry: "main.js",
            refreshInterval: refreshInterval
        )
        self.node = node
    }

    func render(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError> {
        let resolved = renderNode?() ?? node
        onRender?()
        await onRenderAsync?()
        return .success([PluginSlotContent(slot: .center, node: resolved)])
    }

    func prepare(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError> {
        prepareLock.lock()
        prepareCalls += 1
        let call = prepareCalls
        prepareLock.unlock()
        onPrepare?(call)
        await onPrepareAsync?()
        let contents = prepareContents?(call) ?? []
        onPrepareReturned?(call)
        return .success(contents)
    }

    func performAction(id: String, value: Double?,
                       context: PluginRenderContext) async -> Result<Void, PluginRuntimeError> {
        actions.append(id)
        onAction?()
        await onActionAsync?()
        return .success(())
    }

    func suspend() { suspendCount += 1 }
    func resume() { resumeCount += 1; onResume?() }
    func unmount() { unmountCount += 1 }
}

private final class TestHost: PluginHosting {
    var runtimes: [PluginRuntimeProtocol]
    var onLoad: (() async -> Void)?

    init(runtimes: [PluginRuntimeProtocol]) {
        self.runtimes = runtimes
    }

    func runtimes(for bundleID: String) -> [PluginRuntimeProtocol] { runtimes }
    func loadRuntimes(for bundleID: String) async -> [PluginRuntimeProtocol] {
        await onLoad?()
        return runtimes
    }
    func installedPlugins() -> [InstalledPlugin] { [] }
    var read: MediaReadContext?
    var onMediaRead: (() async -> Void)?
    var mediaInvalidation: (() -> Void)?
    func mediaRead(for bundleID: String) async -> MediaReadContext? {
        await onMediaRead?()
        return read
    }
    func acquireMediaRead(for bundleID: String, invalidate: @escaping () -> Void) -> MediaReadInterest? {
        mediaInvalidation = invalidate
        return MediaReadInterest {}
    }
    var artworkData: Data?
    func artwork(for bundleID: String) async -> Data? { artworkData }
    func unmountAll() { runtimes.forEach { $0.unmount() } }
    func reload() {}
}

private final class TestStorage: PluginStorageProviding {
    var values: [String: Any] = [:]

    func get(_ key: String) throws -> Any? { values[key] }
    func set(_ key: String, value: Any) throws { values[key] = value }
    func remove(_ key: String) throws { values.removeValue(forKey: key) }
    func clear() throws { values.removeAll() }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
