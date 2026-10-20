//
//  PreviewPanelTests.swift
//  SwitchlyTests
//
//  Unit tests for the preview panel's merged enlarged mode: panel geometry, the
//  dismissal zoom anchor, the window replica's rectangle, the interaction-mode
//  preference and the native cache tier's resolution cap.
//
//  All of these are pure functions or plain model round-trips, so they run
//  headless: no window server, no screen-recording grant, no second display.
//  The parts that genuinely need a running app (the replica being sharp on a 2x
//  screen, the panel really staying on top) are recorded as manual checks in
//  docs/plan/2026-09-28-preview-panel-live-switch.md.
//

import XCTest
import SwiftUI
@testable import Switchly

final class PreviewPanelMetricsTests: XCTestCase {

    /// The two panels the plan measured on (1352x878 and 1920x1080 pt).
    private let measuredScreens: [CGSize] = [
        CGSize(width: 1352, height: 878),
        CGSize(width: 1920, height: 1080)
    ]

    // MARK: - One size for every mode

    /// The merged enlarged mode adds a window *behind* the panel; it must not
    /// resize the panel itself, because the thumbnail grid is what the panel
    /// keeps showing (docs/plan §15). Every mode therefore resolves the same
    /// historical 800x500 on a screen that fits it.
    func testThePanelKeepsTheHistoricalFixedSizeInEveryMode() {
        for mode in PreviewInteractionMode.allCases {
            for screen in measuredScreens {
                let size = PreviewPanelMetrics.contentSize(visibleFrame: screen)
                XCTAssertEqual(
                    size, PreviewPanelMetrics.fallbackSize,
                    "mode \(mode) changed the panel size on \(screen)"
                )
            }
        }
    }

    // MARK: - The panel never overflows the visible frame

    func testPanelNeverExceedsAnyVisibleFrame() {
        let frames = measuredScreens + [
            CGSize(width: 6016, height: 3384),   // 6K XDR
            CGSize(width: 1152, height: 720),    // small laptop
            CGSize(width: 640, height: 400),     // below the minimum size
            CGSize(width: 300, height: 200)      // pathological
        ]

        for frame in frames {
            let size = PreviewPanelMetrics.contentSize(visibleFrame: frame)
            let available = CGSize(
                width: frame.width - PreviewPanelMetrics.screenMargin * 2,
                height: frame.height - PreviewPanelMetrics.screenMargin * 2
            )
            XCTAssertLessThanOrEqual(size.width, max(1, available.width), "overflows width on \(frame)")
            XCTAssertLessThanOrEqual(size.height, max(1, available.height), "overflows height on \(frame)")
            XCTAssertGreaterThan(size.width, 0, "collapsed on \(frame)")
            XCTAssertGreaterThan(size.height, 0, "collapsed on \(frame)")
        }
    }

    func testPanelIsNotSmallerThanTheMinimumWhenTheScreenAllowsIt() {
        let size = PreviewPanelMetrics.contentSize(visibleFrame: CGSize(width: 2560, height: 1440))
        // The legacy 800x500 request wins on a screen large enough for it.
        XCTAssertEqual(size, PreviewPanelMetrics.fallbackSize)
        XCTAssertGreaterThanOrEqual(size.width, PreviewPanelMetrics.minimumSize.width)
        XCTAssertGreaterThanOrEqual(size.height, PreviewPanelMetrics.minimumSize.height)
    }

    /// Below the minimum the available area wins: a panel clamped *up* to a
    /// minimum it cannot fit would hang off the screen edge.
    func testTinyScreenGetsTheAvailableAreaInsteadOfTheMinimum() {
        let frame = CGSize(width: 480, height: 320)
        let size = PreviewPanelMetrics.contentSize(visibleFrame: frame)

        XCTAssertEqual(size.width, frame.width - PreviewPanelMetrics.screenMargin * 2)
        XCTAssertEqual(size.height, frame.height - PreviewPanelMetrics.screenMargin * 2)
        XCTAssertLessThan(size.width, PreviewPanelMetrics.minimumSize.width)
    }

    func testCenteredOriginCentersThePanelInsideTheVisibleFrame() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 1920, height: 1080)
        let size = PreviewPanelMetrics.fallbackSize
        let origin = PreviewPanelMetrics.centeredOrigin(size: size, in: visibleFrame)

        XCTAssertEqual(origin.x, visibleFrame.midX - size.width / 2)
        XCTAssertEqual(origin.y, visibleFrame.midY - size.height / 2)
        // Centering means equal margins on both sides.
        let left = origin.x - visibleFrame.minX
        let right = visibleFrame.maxX - (origin.x + size.width)
        XCTAssertEqual(left, right, accuracy: 0.001)
        let bottom = origin.y - visibleFrame.minY
        let top = visibleFrame.maxY - (origin.y + size.height)
        XCTAssertEqual(bottom, top, accuracy: 0.001)
    }

    // MARK: - Dismissal zoom anchor

    func testZoomAnchorIsTheCardCenterNormalizedByThePanelSize() {
        let panelSize = CGSize(width: 1632, height: 918)
        let card = CGRect(x: 200, y: 100, width: 400, height: 250)

        let anchor = PreviewPanelMetrics.zoomAnchor(cardFrame: card, panelSize: panelSize)

        XCTAssertEqual(anchor.x, card.midX / panelSize.width)
        XCTAssertEqual(anchor.y, card.midY / panelSize.height)
    }

    /// The regression this normalization exists for: a hard-coded denominator
    /// (the old 800x500) puts the anchor in the wrong place as soon as the panel
    /// is clamped to the screen. Same card frame, two panel sizes, two anchors.
    func testZoomAnchorFollowsThePanelSizeInsteadOfAConstant() {
        let card = CGRect(x: 200, y: 100, width: 400, height: 250)

        let small = PreviewPanelMetrics.zoomAnchor(cardFrame: card, panelSize: CGSize(width: 800, height: 500))
        let large = PreviewPanelMetrics.zoomAnchor(cardFrame: card, panelSize: CGSize(width: 1600, height: 1000))

        XCTAssertNotEqual(small, large)
        XCTAssertEqual(large.x, small.x / 2, accuracy: 0.0001)
        XCTAssertEqual(large.y, small.y / 2, accuracy: 0.0001)
    }

    func testZoomAnchorClampsAPartiallyScrolledCardIntoRange() {
        let panelSize = CGSize(width: 800, height: 500)

        let above = PreviewPanelMetrics.zoomAnchor(
            cardFrame: CGRect(x: -400, y: -300, width: 100, height: 100),
            panelSize: panelSize
        )
        XCTAssertEqual(above, UnitPoint(x: 0, y: 0))

        let below = PreviewPanelMetrics.zoomAnchor(
            cardFrame: CGRect(x: 2000, y: 2000, width: 100, height: 100),
            panelSize: panelSize
        )
        XCTAssertEqual(below, UnitPoint(x: 1, y: 1))
    }

    func testZoomAnchorFallsBackToCenterForADegeneratePanel() {
        XCTAssertEqual(
            PreviewPanelMetrics.zoomAnchor(cardFrame: CGRect(x: 0, y: 0, width: 10, height: 10), panelSize: .zero),
            UnitPoint.center
        )
    }

    // MARK: - Fallback size contract

    func testFallbackSizeMatchesTheHistoricalPanel() {
        XCTAssertEqual(PreviewPanelMetrics.fallbackSize, CGSize(width: 800, height: 500))
    }
}

/// Geometry of the window replica.
///
/// This is where "the screenshot keeps its size" is enforced: the replica is the
/// window's own rectangle, never a fitted one. The functions under test take
/// every screen value as a parameter, so the tests need no display.
final class PreviewReplicaRectTests: XCTestCase {

    /// A 1920x1080 pt primary display, the plan's measured external panel.
    private let primaryHeight: CGFloat = 1080
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1055)

    private func rect(_ cgBounds: CGRect) -> CGRect {
        PreviewReplicaPanel.replicaRect(
            forWindowBounds: cgBounds,
            primaryScreenHeight: primaryHeight,
            visibleFrame: visibleFrame
        )
    }

    /// The whole point of the mode: a window's replica is the window's size,
    /// whatever the screen can hold.
    func testReplicaKeepsTheWindowSizeExactly() {
        let sizes = [
            CGSize(width: 800, height: 600),
            CGSize(width: 1, height: 1),
            CGSize(width: 3840, height: 2160),   // larger than the display
            CGSize(width: 6016, height: 3384)    // larger than the 6K cap
        ]

        for size in sizes {
            let rect = rect(CGRect(origin: CGPoint(x: 40, y: 40), size: size))
            XCTAssertEqual(rect.size, size, "the replica was resized")
        }
    }

    func testReplicaSitsWhereTheWindowIs() {
        // A window at CG (100, 100) sized 800x600: its bottom edge is 700 px below
        // the top of the primary display, so Cocoa puts it at y = 1080 - 700.
        let replica = rect(CGRect(x: 100, y: 100, width: 800, height: 600))
        XCTAssertEqual(replica, CGRect(x: 100, y: 380, width: 800, height: 600))
    }

    /// The y axis flip, pinned at both ends of the display: the conversion has to
    /// move a window's *bottom* edge, not its top one.
    func testReplicaFlipsTheYAxisAcrossThePrimaryDisplay() {
        let atTheTop = rect(CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(atTheTop.origin.y, primaryHeight - 600)

        let atTheBottom = rect(CGRect(x: 0, y: primaryHeight - 600, width: 800, height: 600))
        XCTAssertEqual(atTheBottom.origin.y, 0)
    }

    /// A window that hangs off the screen keeps its place: the real window hangs
    /// off it too, and moving the replica would misrepresent where it is.
    func testPartiallyOffscreenWindowKeepsItsPlace() {
        let hangingOffTheRight = CGRect(x: 1700, y: 200, width: 800, height: 600)
        XCTAssertEqual(rect(hangingOffTheRight), CGRect(x: 1700, y: 280, width: 800, height: 600))

        let hangingOffTheTop = CGRect(x: 100, y: -400, width: 800, height: 600)
        // y = 1080 - (-400 + 600) = 880, i.e. above the visible frame's top.
        XCTAssertEqual(rect(hangingOffTheTop).origin.y, 880)
    }

    /// A window with no intersection at all — another Space, another display, a
    /// display that is gone — would put its replica where nobody can see it, so
    /// it is centred in the visible frame instead. The size still does not move.
    func testFullyOffscreenWindowIsCentredWithoutResizing() {
        let elsewhere = CGRect(x: 5000, y: 300, width: 800, height: 600)
        let replica = rect(elsewhere)

        XCTAssertEqual(replica.size, CGSize(width: 800, height: 600))
        XCTAssertEqual(replica.midX, visibleFrame.midX)
        XCTAssertEqual(replica.midY, visibleFrame.midY)
        XCTAssertTrue(visibleFrame.contains(replica))
    }

    /// A window larger than the screen is *not* fitted to it: the replica stays
    /// window-sized even though it cannot be seen whole. (It still overlaps the
    /// visible frame, so its origin is untouched.)
    func testOversizedWindowIsNotScaledDown() {
        let huge = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        let replica = rect(huge)

        XCTAssertEqual(replica.size, CGSize(width: 3840, height: 2160))
        XCTAssertEqual(replica.origin, CGPoint(x: 0, y: primaryHeight - 2160))
    }

    func testDegenerateBoundsProduceNoRectangle() {
        XCTAssertEqual(rect(CGRect(x: 10, y: 10, width: 0, height: 600)), .zero)
        XCTAssertEqual(rect(CGRect(x: 10, y: 10, width: 800, height: 0)), .zero)
    }

    /// A window list read before any screen could be resolved must not divide the
    /// geometry into nonsense; the position stays the window's own.
    func testNoVisibleFrameStillFlipsTheAxis() {
        let replica = PreviewReplicaPanel.replicaRect(
            forWindowBounds: CGRect(x: 30, y: 30, width: 400, height: 300),
            primaryScreenHeight: 1080,
            visibleFrame: .zero
        )
        XCTAssertEqual(replica, CGRect(x: 30, y: 750, width: 400, height: 300))
    }
}

final class PreviewInteractionModeTests: XCTestCase {

    func testOnlyTheReplicaModeAddsAReplica() {
        XCTAssertFalse(PreviewInteractionMode.highlightOnly.showsWindowReplica)
        XCTAssertTrue(PreviewInteractionMode.windowReplica.showsWindowReplica)
    }

    /// The replica replays the window at its own size, so it reads the tier that
    /// is captured at that size — the one with no ceiling below it. Reading a
    /// capped tier would scale the very thing this design refuses to scale.
    func testTheReplicaReadsTheNativeTier() {
        XCTAssertEqual(PreviewInteractionMode.windowReplica.replicaTier, .native)
        // The tier's cap has to sit at or above the largest window a display can
        // hold, or the replica would be scaled down for exactly the case it
        // exists for.
        XCTAssertEqual(ThumbnailTier.native.maxPixelSize?.width, 6016)
        XCTAssertEqual(ThumbnailTier.native.maxPixelSize?.height, 3384)
    }

    func testEveryModeHasALabelAndSummary() {
        for mode in PreviewInteractionMode.allCases {
            XCTAssertFalse(mode.displayName(language: .english).isEmpty)
            XCTAssertFalse(mode.displayName(language: .simplifiedChinese).isEmpty)
            XCTAssertFalse(mode.summary(language: .english).isEmpty)
            XCTAssertFalse(mode.summary(language: .simplifiedChinese).isEmpty)
        }
    }

    /// Layer contract: the panel shows the grid and must stay in front of the
    /// replica (and therefore interactive) rather than the replica covering the
    /// controls.
    func testReplicaSitsBelowThePreviewPanelAndAboveApps() {
        XCTAssertLessThan(
            PreviewReplicaPanel.replicaLevel.rawValue,
            NSWindow.Level.floating.rawValue,
            "the panel is .floating; the replica must not cover it"
        )
        XCTAssertGreaterThan(
            PreviewReplicaPanel.replicaLevel.rawValue,
            NSWindow.Level.normal.rawValue,
            "the replica must cover ordinary app windows"
        )
    }

    /// Scenery, not a control surface: every event must reach the panel (or the
    /// app below), and it must never take key from the panel.
    func testReplicaNeverTakesFocusOrClicks() {
        let replica = PreviewReplicaPanel.shared
        XCTAssertTrue(replica.ignoresMouseEvents)
        XCTAssertFalse(replica.canBecomeKey)
        XCTAssertFalse(replica.canBecomeMain)
        XCTAssertEqual(replica.level, PreviewReplicaPanel.replicaLevel)
    }

    func testRawValuesAreStableBecauseTheyArePersisted() {
        XCTAssertEqual(PreviewInteractionMode.highlightOnly.rawValue, "highlightOnly")
        XCTAssertEqual(PreviewInteractionMode.windowReplica.rawValue, "windowReplica")
    }

    private func decode(_ raw: String) throws -> PreviewInteractionMode {
        try JSONDecoder().decode(PreviewInteractionMode.self, from: Data("\"\(raw)\"".utf8))
    }

    /// The merge retired two raw values that are sitting in stored settings.
    /// Decoding them as "not highlightOnly" would silently drop a user back to
    /// the grid on upgrade.
    func testRetiredModesDecodeToTheMergedOne() throws {
        XCTAssertEqual(try decode("heroPane"), .windowReplica)
        XCTAssertEqual(try decode("heroPaneFullScreen"), .windowReplica)
    }

    func testCurrentAndUnknownRawValuesDecode() throws {
        XCTAssertEqual(try decode("highlightOnly"), .highlightOnly)
        XCTAssertEqual(try decode("windowReplica"), .windowReplica)
        XCTAssertEqual(try decode("somethingFromTheFuture"), .highlightOnly)
    }
}

final class PreviewSettingsCodableTests: XCTestCase {

    /// The plan requires the new preference to default to the existing
    /// behaviour, so an upgrade must not change what the user sees.
    func testDefaultSettingsStayOnHighlightOnly() {
        let settings = AppSettings.default
        XCTAssertEqual(settings.previewInteractionMode, .highlightOnly)
        XCTAssertEqual(settings.previewReplicaHoverDelay, 0.4)
    }

    func testReplicaPreferencesSurviveARoundTrip() {
        var settings = AppSettings.default
        settings.previewInteractionMode = .windowReplica
        settings.previewReplicaHoverDelay = 0.7

        do {
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            XCTAssertEqual(decoded.previewInteractionMode, .windowReplica)
            XCTAssertEqual(decoded.previewReplicaHoverDelay, 0.7)
        } catch {
            XCTFail("round trip failed: \(error)")
        }
    }

    /// Settings written before this feature have no preview keys at all. The
    /// decoder used to throw on a missing key, which would have logged the user
    /// out of every setting on upgrade.
    func testSettingsWrittenBeforeThePreviewKeysDecodeToTheDefaults() {
        do {
            let data = try JSONEncoder().encode(AppSettings.default)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return XCTFail("settings did not encode to an object")
            }
            json.removeValue(forKey: "previewInteractionMode")
            json.removeValue(forKey: "previewReplicaHoverDelay")

            let stripped = try JSONSerialization.data(withJSONObject: json)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: stripped)

            XCTAssertEqual(decoded.previewInteractionMode, .highlightOnly)
            XCTAssertEqual(decoded.previewReplicaHoverDelay, 0.4)
        } catch {
            XCTFail("decoding legacy settings failed: \(error)")
        }
    }

    /// A settings file written by the build that had the two enlarged modes: the
    /// mode is re-pointed at the merged one, and the delay keeps its old key
    /// (which the decoder still reads, and must never write again).
    func testASettingsFileFromThePreMergeBuildKeepsItsModeAndDelay() throws {
        let data = try JSONEncoder().encode(AppSettings.default)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["previewInteractionMode"] = "heroPaneFullScreen"
        json["previewHeroHoverDelay"] = 0.7
        json.removeValue(forKey: "previewReplicaHoverDelay")

        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONSerialization.data(withJSONObject: json)
        )

        XCTAssertEqual(decoded.previewInteractionMode, .windowReplica)
        XCTAssertEqual(decoded.previewReplicaHoverDelay, 0.7)
    }
}

final class ThumbnailTierCapTests: XCTestCase {

    private func bytes(_ w: Int, _ h: Int) -> Int { w * h * 4 }

    func testGridTierScalesPointsToPixels() {
        let size = ThumbnailService.pixelSize(
            forPoints: CGSize(width: 200, height: 125),
            scale: 2,
            tier: .grid
        )
        XCTAssertEqual(size, CGSize(width: 400, height: 250))
    }

    func testGridTierIsNotCapped() {
        XCTAssertNil(ThumbnailTier.grid.maxPixelSize)
    }

    /// The native cap is a documented contract, not an implementation detail: the
    /// tier budget and the replica geometry both assume it.
    func testNativeCapIsTheDocumentedValue() throws {
        let cap = try XCTUnwrap(ThumbnailTier.native.maxPixelSize)
        XCTAssertEqual(cap, CGSize(width: 6016, height: 3384))
    }

    /// A native request larger than the cap is scaled down proportionally, never
    /// squashed: this is the difference between a softer replica and a distorted
    /// one.
    func testAnOversizedNativeRequestIsCappedAspectPreservingly() throws {
        let cap = try XCTUnwrap(ThumbnailTier.native.maxPixelSize)
        // A 6K-display-filling window at 2x: 12032x6768 px, 325 MB.
        let requested = CGSize(width: 12032, height: 6768)

        let size = ThumbnailService.pixelSize(forPoints: requested, scale: 1, tier: .native)

        XCTAssertLessThanOrEqual(size.width, cap.width)
        XCTAssertLessThanOrEqual(size.height, cap.height)
        XCTAssertEqual(size.width / size.height, requested.width / requested.height, accuracy: 0.01)
        // One axis is pinned to the cap (the wider one here) and the other follows
        // the source aspect ratio — the cap bounds the tier, it does not choose an
        // arbitrary scale factor.
        XCTAssertEqual(size.width, cap.width, accuracy: 1)
    }

    /// The case the replica actually cares about: a window that fills a 1920x1080
    /// pt display is captured at its own size, untouched.
    func testARealWindowRequestIsUntouched() {
        let requested = CGSize(width: 3840, height: 2160)
        XCTAssertEqual(ThumbnailService.pixelSize(forPoints: requested, scale: 1, tier: .native), requested)
    }

    /// The invariant the cap exists for: one entry must fit the native tier's byte
    /// budget, or the cache would evict the replica it just captured.
    func testTheNativeCapFitsTheNativeBudget() throws {
        let cap = try XCTUnwrap(ThumbnailTier.native.maxPixelSize)
        XCTAssertLessThanOrEqual(bytes(Int(cap.width), Int(cap.height)), TierBudget.native.byteLimit)
    }

    /// The native tier must never self-evict for a display that exists today.
    func testTheNativeTierFitsTheLargestDisplay() {
        let sixK = ThumbnailService.pixelSize(
            forPoints: CGSize(width: 6016, height: 3384),
            scale: 1,
            tier: .native
        )
        XCTAssertEqual(sixK, CGSize(width: 6016, height: 3384))
        XCTAssertLessThan(bytes(6016, 3384), TierBudget.native.byteLimit)
    }

    func testDegenerateRequestsStillProduceAtLeastOnePixel() {
        XCTAssertEqual(
            ThumbnailService.pixelSize(forPoints: .zero, scale: 2, tier: .native),
            CGSize(width: 1, height: 1)
        )
        XCTAssertEqual(
            ThumbnailService.pixelSize(forPoints: CGSize(width: 100, height: 50), scale: 0, tier: .grid),
            CGSize(width: 100, height: 50)
        )
        XCTAssertEqual(
            ThumbnailService.pixelSize(forPoints: CGSize(width: 100, height: 50), scale: -3, tier: .grid),
            CGSize(width: 100, height: 50)
        )
    }
}

/// Offscreen layout smoke test for the card the merged mode draws.
///
/// The panel is an NSPanel, so a unit test cannot exercise "the user hovers a
/// card" end to end. It can, however, build the real SwiftUI hierarchy with a real
/// window model inside an NSHostingView and force a layout pass — which is what
/// catches a view whose geometry depends on itself, a missing environment value,
/// or a body that traps. It runs in the app-hosted test process, so the AppKit
/// side exists exactly as it does in the app.
final class PreviewCardLayoutTests: XCTestCase {

    private func makeWindow(id: CGWindowID, isOnCurrentSpace: Bool = true) -> WindowInfo {
        WindowInfo(
            id: id,
            ownerPID: 4242,
            ownerName: "SwitchlyTests",
            windowTitle: "Replica fixture",
            bounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
            isOnCurrentSpace: isOnCurrentSpace,
            windowNumber: Int(id)
        )
    }

    private func settings(mode: PreviewInteractionMode) -> AppSettings {
        var settings = AppSettings.default
        settings.previewInteractionMode = mode
        return settings
    }

    @MainActor
    private func layout<V: View>(_ view: V, size: CGSize) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Both modes draw the same card — the merged mode adds a window behind the
    /// panel, it does not change the panel — so both must lay out identically.
    @MainActor
    func testThumbnailCardLaysOutInEveryMode() {
        for mode in PreviewInteractionMode.allCases {
            let host = layout(
                WindowThumbnailView(
                    window: makeWindow(id: 1),
                    isSelected: false,
                    settings: settings(mode: mode),
                    onHoverChange: { _ in }
                ),
                size: CGSize(width: 260, height: 220)
            )

            // The assertion that matters is that this test reaches the next line:
            // building the body and running a layout pass is what would trap if
            // the card's geometry ever depended on itself. The frame check pins the
            // hosting behaviour so a silent no-op layout cannot pass either.
            XCTAssertEqual(host.frame.size, CGSize(width: 260, height: 220))
            XCTAssertNotNil(host.layer, "card did not become layer-backed in \(mode)")
            let intrinsic = host.fittingSize
            XCTAssertGreaterThanOrEqual(intrinsic.width, 150, "card lost its content width in \(mode)")
            XCTAssertGreaterThanOrEqual(intrinsic.height, 80, "card collapsed vertically in \(mode)")
        }
    }

    /// A minimized window carries the "no live content" annotation. It used to be
    /// drawn on the removed hero info bar, so this is the branch that has to stay
    /// reachable from the card.
    @MainActor
    func testThumbnailCardLaysOutForAMinimizedWindow() {
        let host = layout(
            WindowThumbnailView(
                window: makeWindow(id: 9, isOnCurrentSpace: false),
                isSelected: true,
                settings: settings(mode: .windowReplica),
                onHoverChange: { _ in }
            ),
            size: CGSize(width: 300, height: 240)
        )

        XCTAssertEqual(host.frame.size, CGSize(width: 300, height: 240))
        XCTAssertNotNil(host.layer, "minimized card did not become layer-backed")
    }
}

/// Hover policy of the window replica.
///
/// The delayed swap and its cancellation rules are the part of this feature that
/// cannot be eyeballed from a screenshot, and the one place where a pointer
/// heuristic can regress silently: SwiftUI delivers hover exits and entries in an
/// order it does not promise, and a late exit from a card the pointer already left
/// must not cancel the hover that moved on.
///
/// Window monitor that serves a fixed list and never touches the window server.
///
/// The test process runs inside the app host, whose own monitor keeps posting list
/// refreshes while a test runs. Handing the model under test a monitor that always
/// returns the same fixtures makes every refresh converge on the same state, so the
/// hover assertions cannot be raced by the machine's real windows.
private final class FixtureWindowMonitor: WindowMonitorServiceProtocol {
    private let fixtures: [WindowInfo]

    init(fixtures: [WindowInfo]) {
        self.fixtures = fixtures
    }

    func startMonitoring() {}
    func stopMonitoring() {}
    func getAllWindows() -> [WindowInfo] { fixtures }
    func getOnScreenWindows() -> [WindowInfo] { fixtures }
    func getWindows(for bundleIdentifier: String) -> [WindowInfo] { fixtures }
    func getWindows(for bundleIdentifier: String, appName: String) -> [WindowInfo] { fixtures }
    func getWindows(for app: MonitoredApp) -> [WindowInfo] { fixtures }
    func filterWindows(_ windows: [WindowInfo], for bundleIdentifier: String, appName: String?) -> [WindowInfo] { fixtures }
    func windows(ownedBy bundleURL: URL) -> [WindowInfo] { fixtures }
    func getVisibleWindowCount(for bundleIdentifier: String) -> Int { fixtures.count }
    func filterWindows(_ windows: [WindowInfo], by strategy: PreviewStrategy) -> [WindowInfo] { windows }
    func filterWindows(_ windows: [WindowInfo], by searchText: String) -> [WindowInfo] { windows }
}

@MainActor
final class PreviewReplicaHoverTests: XCTestCase {

    /// Every fixture window is in the list, so a background refresh never drops
    /// the replica; the first fixture is the selection, which is what a released
    /// hover must fall back to.
    private static let fixtureIDs: [CGWindowID] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    private static let selectionID: CGWindowID = 1

    private let delay: Double = 0.05
    /// Comfortably past `delay`; generous so a loaded CI machine cannot flake.
    private let pastDelay: UInt64 = 400_000_000

    private func replicaSettings(delay: Double) -> AppSettings {
        var settings = AppSettings.default
        settings.previewInteractionMode = .windowReplica
        settings.previewReplicaHoverDelay = delay
        return settings
    }

    /// A model wired to the fixed fixture list, with the list loaded so the
    /// baseline (selection = fixture 1, replica = fixture 1) is deterministic.
    private func makeViewModel() -> PreviewViewModel {
        let viewModel = PreviewViewModel(
            windowMonitorService: FixtureWindowMonitor(fixtures: Self.fixtureIDs.map { makeWindow(id: $0) })
        )
        viewModel.refreshAllWindows()
        return viewModel
    }

    private func makeWindow(id: CGWindowID) -> WindowInfo {
        WindowInfo(
            id: id,
            ownerPID: 777,
            ownerName: "HoverFixture",
            windowTitle: "Window \(id)",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnCurrentSpace: true,
            windowNumber: Int(id)
        )
    }

    func testHoverSwapWaitsForTheDelay() async throws {
        let viewModel = makeViewModel()
        let window = makeWindow(id: 5)
        let settings = replicaSettings(delay: delay)
        XCTAssertEqual(viewModel.replicaWindow?.id, Self.selectionID, "baseline should be the selection")

        viewModel.setHoveredWindow(window, hovering: true, settings: settings)
        XCTAssertNotEqual(
            viewModel.replicaWindow?.id, window.id,
            "the replica must not swap before the hover delay elapses"
        )

        try await Task.sleep(nanoseconds: pastDelay)
        XCTAssertEqual(viewModel.replicaWindow?.id, window.id)
    }

    func testZeroDelayStillSwapsAsynchronously() async throws {
        let viewModel = makeViewModel()
        let window = makeWindow(id: 2)

        viewModel.setHoveredWindow(window, hovering: true, settings: replicaSettings(delay: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(viewModel.replicaWindow?.id, window.id)
    }

    func testLeavingTheOnlyHoveredCardRestoresTheSelection() async throws {
        let viewModel = makeViewModel()
        let window = makeWindow(id: 3)
        let settings = replicaSettings(delay: delay)

        viewModel.setHoveredWindow(window, hovering: true, settings: settings)
        try await Task.sleep(nanoseconds: pastDelay)
        XCTAssertEqual(viewModel.replicaWindow?.id, window.id)

        viewModel.setHoveredWindow(window, hovering: false, settings: settings)
        XCTAssertEqual(
            viewModel.replicaWindow?.id, Self.selectionID,
            "leaving the card must fall back to the selection"
        )
    }

    func testLeavingTheCardCancelsAPendingSwap() async throws {
        let viewModel = makeViewModel()
        let window = makeWindow(id: 4)
        let settings = replicaSettings(delay: delay)

        viewModel.setHoveredWindow(window, hovering: true, settings: settings)
        viewModel.setHoveredWindow(window, hovering: false, settings: settings)
        try await Task.sleep(nanoseconds: pastDelay)

        XCTAssertNotEqual(
            viewModel.replicaWindow?.id, window.id,
            "a cancelled hover must not swap the replica later"
        )
    }

    /// The ordering hazard: moving from card A to card B, then receiving A's exit.
    func testStaleExitFromAnotherCardDoesNotUndoTheNewHover() async throws {
        let viewModel = makeViewModel()
        let first = makeWindow(id: 6)
        let second = makeWindow(id: 7)
        let settings = replicaSettings(delay: delay)

        viewModel.setHoveredWindow(first, hovering: true, settings: settings)
        viewModel.setHoveredWindow(second, hovering: true, settings: settings)
        viewModel.setHoveredWindow(first, hovering: false, settings: settings)

        try await Task.sleep(nanoseconds: pastDelay)
        XCTAssertEqual(
            viewModel.replicaWindow?.id, second.id,
            "the late exit cancelled the new hover"
        )
    }

    /// The same hazard in the other delivery order: exit first, then entry.
    func testExitBeforeEntryStillEndsOnTheNewCard() async throws {
        let viewModel = makeViewModel()
        let first = makeWindow(id: 8)
        let second = makeWindow(id: 9)
        let settings = replicaSettings(delay: delay)

        viewModel.setHoveredWindow(first, hovering: true, settings: settings)
        try await Task.sleep(nanoseconds: pastDelay)
        viewModel.setHoveredWindow(first, hovering: false, settings: settings)
        viewModel.setHoveredWindow(second, hovering: true, settings: settings)

        try await Task.sleep(nanoseconds: pastDelay)
        XCTAssertEqual(viewModel.replicaWindow?.id, second.id)
    }

    /// Highlight-only adds no replica, so a hover there must not pay for a
    /// window-sized capture.
    func testHoverIsIgnoredInHighlightOnly() async throws {
        let viewModel = makeViewModel()
        let window = makeWindow(id: 9)
        var settings = AppSettings.default
        settings.previewInteractionMode = .highlightOnly

        viewModel.setHoveredWindow(window, hovering: true, settings: settings)
        try await Task.sleep(nanoseconds: pastDelay)

        XCTAssertNotEqual(
            viewModel.replicaWindow?.id, window.id,
            "hover must not swap the enlarged surface outside the replica mode"
        )
    }
}
