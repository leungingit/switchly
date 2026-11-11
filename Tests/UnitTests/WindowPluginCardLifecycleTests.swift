import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Switchly

private final class CardScopeRuntime: PluginRuntimeProtocol {
    let manifest: PluginManifest
    var onInvalidate: (() -> Void)?
    let lock = NSLock()
    private var contexts = Set<String>()
    private var resumes = 0
    var distinctContext: ((Int) -> Void)?
    var suspended: (() -> Void)?
    init(manifest: PluginManifest) { self.manifest = manifest }
    var resumeCount: Int { lock.lock(); defer { lock.unlock() }; return resumes }
    func render(context: PluginRenderContext) async -> Result<[PluginSlotContent], PluginRuntimeError> {
        let (inserted, count, callback) = record(context)
        if inserted { callback?(count) }
        return .success([PluginSlotContent(slot: .titleAccessory,
                                          node: .button(id: "capture", symbol: "camera", label: "Capture", size: .s,
                                                        variant: .plain, enabled: true, selected: false))])
    }
    private func record(_ context: PluginRenderContext) -> (Bool, Int, ((Int) -> Void)?) {
        lock.lock()
        let inserted = contexts.insert("\(context.windowID):\(context.presentationID ?? "")").inserted
        let count = contexts.count, callback = distinctContext
        lock.unlock()
        return (inserted, count, callback)
    }
    func performAction(id: String, value: Double?, context: PluginRenderContext) async -> Result<Void, PluginRuntimeError> { .success(()) }
    func resume() { lock.lock(); resumes += 1; lock.unlock() }
    func suspend() { suspended?() }
    func unmount() {}
}

private struct CardScopeRegistry: PluginRegistryProtocol {
    let package: PluginPackage
    func reload() -> (plugins: [PluginPackage], failures: [PluginLoadFailure]) { ([package], []) }
}

private final class CardScopeMedia: MediaBridging {
    let queue = DispatchQueue(label: "capture-card-test.media")
    func supports(bundleID: String) -> Bool { false }
    func nowPlaying(bundleID: String) throws -> NowPlaying? { nil }
    func perform(_ command: MediaCommand, bundleID: String) throws {}
    func artwork(bundleID: String) throws -> Data? { nil }
}

private final class CardScopeHostSpy: PluginHosting {
    let runtime: PluginRuntimeProtocol
    private let lock = NSLock()
    private var reads = 0
    private var interests = 0
    init(_ runtime: PluginRuntimeProtocol) { self.runtime = runtime }
    var counts: (reads: Int, interests: Int) { lock.lock(); defer { lock.unlock() }; return (reads, interests) }
    func runtimes(for bundleID: String) -> [PluginRuntimeProtocol] { [runtime] }
    func installedPlugins() -> [InstalledPlugin] { [] }
    func artwork(for bundleID: String) async -> Data? { nil }
    func mediaRead(for bundleID: String) async -> MediaReadContext? { recordRead(); return nil }
    private func recordRead() { lock.lock(); reads += 1; lock.unlock() }
    func acquireMediaRead(for bundleID: String, invalidate: @escaping () -> Void) -> MediaReadInterest? {
        lock.lock(); interests += 1; lock.unlock(); return nil
    }
    func unmountAll() { runtime.unmount() }
    func reload() {}
}

@MainActor
private final class CardScopeState: ObservableObject { @Published var visible = true }

private struct CardScopeFixture: View {
    @ObservedObject var state: CardScopeState
    let host: PluginHosting
    var body: some View {
        HStack {
            ForEach(1..<4, id: \.self) { id in
                DockWindowPluginCard(window: WindowInfo(id: UInt32(id), ownerPID: 10, ownerName: "Fixture", windowTitle: "Window \(id)",
                                                       bounds: CGRect(x: 0, y: 0, width: 200, height: 120), isOnCurrentSpace: true, windowNumber: id),
                                     isSelected: false, settings: .default,
                                     context: PluginRenderContext(bundleID: "com.test.app", pid: 10, appName: "Fixture", windowID: UInt32(id), titleSummary: "Fixture"),
                                     isPanelVisible: state.visible, appBottomBar: nil, host: host,
                                     thumbnail: NSImage(size: NSSize(width: 40, height: 20)))
            }
        }
    }
}

@MainActor
final class WindowPluginCardLifecycleTests: XCTestCase {
    func testCameraTitleRowFitsPanelCardMetrics() {
        XCTAssertEqual(DockPanelMetrics.cardSize(cardWidth: 120).height, 113, "Inactive window plugins preserve the existing panel budget")
        for width: CGFloat in [120, 200, 280] {
            var settings = AppSettings.default
            settings.dockPreviewCardWidth = width
            let window = WindowInfo(id: 1, ownerPID: 10, ownerName: "Fixture", windowTitle: "Long English title · 较长的窗口标题",
                                    bounds: CGRect(x: 0, y: 0, width: 200, height: 120), isOnCurrentSpace: true, windowNumber: 1)
            let accessory = AnyView(PluginSymbolButton(symbol: "camera", label: "Capture", size: .s, prominent: false, selected: false, action: {}))
            let view = NSHostingView(rootView: DockWindowCard(window: window, isSelected: false, settings: settings,
                                                            pluginAccessory: accessory, initialThumbnail: { _ in .loaded(NSImage(size: NSSize(width: 40, height: 20))) }))
            let fitted = view.fittingSize
            let budget = DockPanelMetrics.cardSize(cardWidth: width, titleAccessoryHeight: DesignTokens.Plugin.controlSmall)
            XCTAssertLessThanOrEqual(fitted.width, budget.width + 0.5)
            XCTAssertLessThanOrEqual(fitted.height, budget.height + 0.5)
        }
    }

    func testCaptureOnlyWindowOverlayDoesNotDependOnMediaSnapshots() async {
        var manifest = PluginManifest(id: "com.test.capture-only", name: ["en": "Capture"], version: "1", apiVersion: 2,
                                      matches: ["*"], permissions: [.windowCapture], entry: "main.js", refreshInterval: 15)
        manifest.renderScope = .window
        let host = CardScopeHostSpy(CardScopeRuntime(manifest: manifest))
        let model = DockPluginOverlayModel(host: host, scope: .window)
        let published = expectation(description: "capture control published")
        let subscription = model.slotsPublisher.filter { $0[.titleAccessory]?.isEmpty == false }.prefix(1).sink { _ in published.fulfill() }
        model.start(context: PluginRenderContext(bundleID: "com.test.app", pid: 1, appName: "Fixture", windowID: 1, titleSummary: "Fixture"))
        await fulfillment(of: [published], timeout: 1)
        XCTAssertEqual(host.counts.reads, 0)
        XCTAssertEqual(host.counts.interests, 0)
        model.stop()
        withExtendedLifetime(subscription) {}
    }

    func testThreeMountedCardsStopAndResumeWithFreshPresentationContexts() async throws {
        var manifest = PluginManifest(id: "com.test.window-card", name: ["en": "Fixture"], version: "1", apiVersion: 2,
                                      matches: ["*"], permissions: [], entry: "main.js", refreshInterval: 15)
        manifest.renderScope = .window
        let runtime = CardScopeRuntime(manifest: manifest)
        let package = PluginPackage(manifest: manifest, directory: FileManager.default.temporaryDirectory, source: "", origin: .builtin)
        let host = PluginHost(registry: CardScopeRegistry(package: package), grants: { [:] }, mediaBridge: CardScopeMedia(), makeRuntime: { _, _ in runtime })
        let state = CardScopeState()
        let mounted = expectation(description: "three initial contexts"), restored = expectation(description: "three fresh contexts")
        runtime.distinctContext = { count in
            if count == 3 { mounted.fulfill() }
            if count == 6 { restored.fulfill() }
        }
        let stopped = expectation(description: "shared runtime suspended"), stoppedAgain = expectation(description: "shared runtime suspended again")
        var stops = 0
        runtime.suspended = { stops += 1; if stops == 1 { stopped.fulfill() }; if stops == 2 { stoppedAgain.fulfill() } }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 250), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CardScopeFixture(state: state, host: host))
        window.orderFront(nil)
        defer { window.close() }
        await fulfillment(of: [mounted], timeout: 2)
        XCTAssertEqual(runtime.resumeCount, 1)
        state.visible = false
        await fulfillment(of: [stopped], timeout: 2)
        state.visible = true
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertEqual(runtime.resumeCount, 2)
        state.visible = false
        await fulfillment(of: [stoppedAgain], timeout: 2)
    }
}
