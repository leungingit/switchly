//
//  PluginScene3DController.swift
//  Switchly
//
//  T06: per-slot lifecycle for a scene3d component.
//
//  Ownership:
//  - the controller owns at most one `PluginScene3DInstance`;
//  - the instance owns the cloned scene, camera, textures and renderer;
//  - a scene host (`SCNView`) is only weakly referenced by the controller and
//    is cleared on teardown;
//  - the frame scheduler only runs while inertia is settling.
//
//  Async asset loads are guarded by a monotonically increasing generation plus
//  the active/size checks at completion. A late result for an old descriptor,
//  a hidden slot or a slot that shrank can never replace current state.
//  Asset decoding happens off the main actor; every live SceneKit mutation and
//  every published state change happens on the main actor.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import QuartzCore
import SceneKit
import simd

/// The view-layer bridge. Services only know that something can mount a scene
/// and provide hit candidates; they never import a concrete SCNView.
@MainActor
protocol PluginScene3DSceneHosting: AnyObject, Scene3DHitProviding {
    func mountScene(_ scene: SCNScene?)
    func refreshDisplay()
}

@MainActor
protocol PluginScene3DFrameScheduling: AnyObject {
    var isRunning: Bool { get }
    func start(tick: @escaping @MainActor (TimeInterval) -> Void)
    func stop()
}

/// RunLoop-main timer used for inertia only. It is never started for a static
/// scene, so hidden cards do not keep a display link alive.
@MainActor
final class PluginScene3DFrameTimer: NSObject, PluginScene3DFrameScheduling {
    private var timer: Timer?
    private var tick: (@MainActor (TimeInterval) -> Void)?
    private var lastTimestamp: TimeInterval?
    private let interval: TimeInterval

    init(interval: TimeInterval = 1.0 / 60.0) {
        self.interval = interval
        super.init()
    }

    var isRunning: Bool { timer != nil }

    func start(tick: @escaping @MainActor (TimeInterval) -> Void) {
        stop()
        self.tick = tick
        lastTimestamp = CACurrentMediaTime()
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(fire), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        tick = nil
        lastTimestamp = nil
    }

    @objc private func fire() {
        let now = CACurrentMediaTime()
        let previous = lastTimestamp ?? now
        lastTimestamp = now
        // Clamp a long main-thread stall so inertia cannot jump.
        let delta = min(max(now - previous, 0), 1.0 / 15.0)
        tick?(delta)
    }
}

enum PluginScene3DAssetFile {
    /// 读取前检查：符号链接解析后必须仍在插件包内，且大小不超过 GLB 上限，
    /// 避免整文件读入内存后才发现越界或超限。文件不存在时交给 reader 处理。
    static func violation(_ url: URL, within directory: URL) -> PluginScene3DFailure? {
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return nil
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard resolved.standardizedFileURL.path.hasPrefix(prefix), values.isRegularFile == true else {
            return .preflightRejected("scene3d asset must be a regular file inside the plugin package")
        }
        if let size = values.fileSize, size > GLBPreflight.Budget.maxFileBytes {
            return .preflightRejected("scene3d asset exceeds \(GLBPreflight.Budget.maxFileBytes) bytes")
        }
        return nil
    }
}

/// Immutable load request that can cross to a background task. The cache and
/// loader are internally thread-safe; the only mutable object produced is the
/// template scene, which is never mutated after decoding.
private final class PluginScene3DLoadJob: @unchecked Sendable {
    let asset: String
    let assetDirectory: URL
    let pluginID: String
    let dataReader: (URL) throws -> Data
    let loader: PluginScene3DAssetLoading
    let cache: PluginScene3DAssetCache

    init(asset: String,
         assetDirectory: URL,
         pluginID: String,
         dataReader: @escaping (URL) throws -> Data,
         loader: PluginScene3DAssetLoading,
         cache: PluginScene3DAssetCache) {
        self.asset = asset
        self.assetDirectory = assetDirectory
        self.pluginID = pluginID
        self.dataReader = dataReader
        self.loader = loader
        self.cache = cache
    }

    func run() -> Result<PluginScene3DAsset, PluginScene3DFailure> {
        let started = DispatchTime.now().uptimeNanoseconds
        defer { AppLogger.performance("Scene3DAsset", since: started) }
        let data: Data
        let url = assetDirectory.appendingPathComponent(asset)
        if let failure = PluginScene3DAssetFile.violation(url, within: assetDirectory) { return .failure(failure) }
        do {
            data = try dataReader(url)
        } catch {
            return .failure(.assetMissing)
        }
        let identity = PluginScene3DIdentity(pluginID: pluginID,
                                             assetHash: PluginScene3DAssetCache.hash(data))
        do {
            let asset = try cache.asset(for: identity) {
                try loader.load(data: data, identity: identity)
            }
            return .success(asset)
        } catch let failure as PluginScene3DFailure {
            return .failure(failure)
        } catch {
            return .failure(.decodeFailed(error.localizedDescription))
        }
    }
}

@MainActor
final class PluginScene3DController: ObservableObject, Scene3DHitProviding {
    @Published private(set) var state: PluginScene3DState = .idle
    @Published private(set) var accessibilityElements: [Scene3DAccessibilityModel.Element] = []

    private(set) var descriptor: PluginScene3DDescriptor
    private(set) var pluginID: String
    private(set) var assetDirectory: URL
    private(set) var artwork: PluginSurfaceArtwork?
    private(set) var palette: PluginSurfacePalette
    /// Real appearance of the hosting view; picks the model's finish for
    /// device palettes (silver in light, space gray in dark).
    private var hostIsDark = false
    private var effectivePalette: PluginSurfacePalette { palette.resolved(dark: hostIsDark) }
    private(set) var slotSize: CGSize = .zero
    private(set) var isActive = false
    private(set) var instance: PluginScene3DInstance?
    private(set) var hitSession: Scene3DInputSession?
    private var pressAppearance: [String: (scale: SCNVector3, opacity: CGFloat)] = [:]
    /// Exposed only for deterministic cancellation tests.
    private(set) var generation = 0

    private weak var host: (any PluginScene3DSceneHosting)?
    private var loadTask: Task<Void, Never>?
    private var frameScheduler: PluginScene3DFrameScheduling?

    private let loader: PluginScene3DAssetLoading
    private let cache: PluginScene3DAssetCache
    private let dataReader: (URL) throws -> Data
    private let rasterizerFactory: @MainActor () -> PluginSurfaceRasterizing
    private let frameSchedulerFactory: @MainActor () -> PluginScene3DFrameScheduling
    private let reduceMotion: () -> Bool
    private let resetViewLabel: String
    private var actionSink: (String, Double?) -> Void

    init(descriptor: PluginScene3DDescriptor,
         pluginID: String,
         assetDirectory: URL,
         artwork: PluginSurfaceArtwork? = nil,
         palette: PluginSurfacePalette = .system(),
         loader: PluginScene3DAssetLoading = GLTFKit2Scene3DAssetLoader(),
         cache: PluginScene3DAssetCache = .shared,
         dataReader: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) },
         rasterizerFactory: @escaping @MainActor () -> PluginSurfaceRasterizing,
         frameSchedulerFactory: @escaping @MainActor () -> PluginScene3DFrameScheduling = {
             PluginScene3DFrameTimer()
         },
         reduceMotion: @escaping () -> Bool = { MotionTokens.reduceMotion },
         resetViewLabel: String = NSLocalizedString("Reset 3D view",
                                                   comment: "Reset the scene3d camera"),
         actionSink: @escaping (String, Double?) -> Void = { _, _ in }) {
        self.descriptor = descriptor
        self.pluginID = pluginID
        self.assetDirectory = assetDirectory
        self.artwork = artwork
        self.palette = palette
        self.loader = loader
        self.cache = cache
        self.dataReader = dataReader
        self.rasterizerFactory = rasterizerFactory
        self.frameSchedulerFactory = frameSchedulerFactory
        self.reduceMotion = reduceMotion
        self.resetViewLabel = resetViewLabel
        self.actionSink = actionSink
    }

    var cameraPose: Scene3DCameraController.Pose {
        hitSession?.cameraPose ?? descriptorCamera
    }

    var isCameraSettled: Bool { hitSession?.isCameraSettled ?? true }

    var canHostScene: Bool {
        PluginScene3DViewport.canHost3D(in: slotSize)
    }

    // MARK: - Configuration

    /// Replaces the declaration for this slot. The old scene is torn down
    /// immediately so two target switches cannot show stale geometry. If the
    /// slot is visible, the new asset is loaded (through the shared cache).
    func configure(descriptor: PluginScene3DDescriptor,
                   pluginID: String,
                   assetDirectory: URL,
                   artwork: PluginSurfaceArtwork?,
                   palette: PluginSurfacePalette) {
        guard self.descriptor != descriptor
                || self.pluginID != pluginID
                || self.assetDirectory != assetDirectory
                || self.artwork?.token != artwork?.token
                || self.palette != palette else {
            return
        }
        // A pending decode only depends on the plugin-scoped asset path.
        // Presentation changes can update the request that finishLoad uses
        // without cancelling and decoding the same asset a second time.
        if loadTask != nil,
           self.pluginID == pluginID,
           self.assetDirectory == assetDirectory,
           self.descriptor.asset == descriptor.asset {
            self.descriptor = descriptor
            self.artwork = artwork
            self.palette = palette
            return
        }
        // Playback ticks only change what is painted on the surfaces (progress,
        // play icon, cover). Repaint the live scene instead of rebuilding it,
        // otherwise the model flashes and loses its camera pose every second.
        if let instance, case .ready = state,
           descriptor.canRepaintInPlace(from: self.descriptor),
           self.pluginID == pluginID,
           self.palette.darkFinish == palette.darkFinish,
           self.assetDirectory == assetDirectory,
           instance.refreshSurfaces(descriptor: descriptor,
                                    assetDirectory: assetDirectory,
                                    artwork: artwork,
                                    palette: palette.resolved(dark: hostIsDark)) {
            self.descriptor = descriptor
            self.artwork = artwork
            self.palette = palette
            accessibilityElements = Scene3DAccessibilityModel.elements(
                texts: instance.texts,
                hits: instance.hits,
                resetViewLabel: resetViewLabel
            )
            host?.refreshDisplay()
            return
        }
        self.descriptor = descriptor
        self.pluginID = pluginID
        self.assetDirectory = assetDirectory
        self.artwork = artwork
        self.palette = palette
        cancelLoad()
        teardownInstance()
        state = .idle
        if isActive {
            beginLoadIfPossible()
        }
    }

    /// Called by the host view when its effective appearance is known or
    /// changes. Rebuilds from the cached asset only if the finish changes.
    func updateHostAppearance(dark: Bool) {
        guard dark != hostIsDark else { return }
        let before = effectivePalette.darkFinish
        hostIsDark = dark
        guard effectivePalette.darkFinish != before, isActive, instance != nil else { return }
        reassembleForNewSize(preserving: cameraPose)
    }

    /// Replaces the action closure when SwiftUI re-renders the same
    /// `@StateObject` controller. The installed session reads `actionSink`
    /// through a weak-self closure, so no reinstall is required.
    func updateActionSink(_ sink: @escaping (String, Double?) -> Void) {
        actionSink = sink
    }

    // MARK: - Host

    func attach(host: any PluginScene3DSceneHosting) {
        // A SwiftUI host may be replaced without an intervening detach. Clear
        // the previous SCNView before switching so it cannot keep the last
        // SCNScene (and its GPU resources) alive.
        if let previous = self.host, previous !== host {
            previous.mountScene(nil)
        }
        self.host = host
        if let instance {
            host.mountScene(instance.scene)
            host.refreshDisplay()
        }
    }

    func detach(host: any PluginScene3DSceneHosting) {
        // Always clear the host being dismantled, even when it is no longer
        // the current one: SwiftUI may tear the old NSView down after the new
        // one attached, and a stale view must not retain an old scene.
        host.mountScene(nil)
        if self.host === host {
            self.host = nil
        }
    }

    func hitCandidates(at point: CGPoint) -> [Scene3DHitRouter.Candidate] {
        guard isActive, instance != nil else { return [] }
        return host?.hitCandidates(at: point) ?? []
    }

    // MARK: - Lifecycle

    /// Idempotent. Re-mounts an existing scene after a hide/show cycle and
    /// starts a fresh load when there is no live instance.
    func start() {
        guard !isActive else {
            if let instance {
                host?.mountScene(instance.scene)
                host?.refreshDisplay()
            }
            hitSession?.start()
            return
        }
        isActive = true
        if let instance, instance.darkFinish != effectivePalette.darkFinish {
            reassembleForNewSize(preserving: cameraPose)
            return
        }
        if let instance {
            host?.mountScene(instance.scene)
            host?.refreshDisplay()
            hitSession?.start()
            return
        }
        beginLoadIfPossible()
    }

    /// Stops input, inertia and the frame scheduler but keeps the loaded scene
    /// so a quick re-show does not decode again. Cancels a pending load.
    /// Idempotent.
    func stop() {
        guard isActive else { return }
        isActive = false
        cancelLoad()
        hitSession?.stop()
        stopFrameLoop()
        if case .loading = state {
            state = instance.map { .ready($0.identity) } ?? .idle
        }
    }

    /// Full uninstall. Cancels everything, clears the host's scene reference
    /// and releases cloned geometry, textures and materials.
    func unload() {
        isActive = false
        cancelLoad()
        stopFrameLoop()
        teardownInstance()
        state = .idle
    }

    // MARK: - Layout

    /// Applies the real slot size. Under 220×380 pt the component must fall
    /// back to the 2D tree; the host should then either enlarge the slot or
    /// show the fallback. This method never changes the official Dock.
    func updateSlotSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else {
            return
        }
        guard abs(size.width - slotSize.width) > 0.5
                || abs(size.height - slotSize.height) > 0.5 else {
            return
        }
        slotSize = size

        guard canHostScene else {
            cancelLoad()
            teardownInstance()
            stopFrameLoop()
            state = .fallback(.slotTooSmall)
            return
        }

        if case .fallback(.slotTooSmall) = state {
            state = .idle
        }
        guard isActive else { return }

        if self.instance != nil {
            reassembleForNewSize(preserving: cameraPose)
        } else if case .loading = state {
            // The pending load reads the latest slot size at completion.
        } else if state != .idle {
            // A real failure stays on screen until an explicit start or
            // configure retries it; a resize alone must not thrash the decoder.
            if case .fallback = state { return }
            beginLoadIfPossible()
        } else {
            beginLoadIfPossible()
        }
    }

    // MARK: - Pointer (top-left coordinates, forwarded to T05)

    func pointerDown(at point: CGPoint) {
        stopFrameLoop()
        hitSession?.pointerDown(at: point)
    }

    func pointerDragged(to point: CGPoint) {
        hitSession?.pointerDragged(to: point)
    }

    func pointerUp(at point: CGPoint) {
        hitSession?.pointerUp(at: point)
        if let session = hitSession, session.isActive, !session.isCameraSettled {
            startFrameLoopIfNeeded()
        }
    }

    func pointerCancelled() {
        hitSession?.pointerCancelled()
        stopFrameLoop()
    }

    /// Starts an automatic turn from the on-screen controls.
    func spin(_ direction: Scene3DCameraController.SpinDirection) {
        guard let session = hitSession, session.spin(direction) else { return }
        startFrameLoopIfNeeded()
    }

    @discardableResult
    func resetView() -> Bool {
        guard let session = hitSession else { return false }
        let changed = session.resetView()
        stopFrameLoop()
        return changed
    }

    @discardableResult
    func performAccessibilityAction(_ actionID: String) -> Bool {
        // The reset action reports whether the pose actually changed, matching
        // `resetView()`. The T05 session accepts reset unconditionally, which
        // would make a second activation look like a successful change.
        if actionID == Scene3DAccessibilityModel.resetViewElementID {
            return resetView()
        }
        return hitSession?.performAccessibilityAction(actionID) ?? false
    }

    // MARK: - Loading

    private var descriptorCamera: Scene3DCameraController.Pose {
        Scene3DCameraController.Pose(yaw: descriptor.camera.yaw,
                                     pitch: descriptor.camera.pitch)
    }

    private func beginLoadIfPossible() {
        guard isActive, canHostScene, instance == nil, loadTask == nil else { return }
        let token = nextGeneration()
        state = .loading
        let job = PluginScene3DLoadJob(asset: descriptor.asset,
                                       assetDirectory: assetDirectory,
                                       pluginID: pluginID,
                                       dataReader: dataReader,
                                       loader: loader,
                                       cache: cache)
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = job.run()
            guard !Task.isCancelled else { return }
            await self?.finishLoad(result, generation: token)
        }
    }

    private func finishLoad(_ result: Result<PluginScene3DAsset, PluginScene3DFailure>,
                            generation token: Int) {
        guard token == generation, isActive, canHostScene, instance == nil else { return }
        loadTask = nil

        switch result {
        case .success(let asset):
            do {
                let instance = try PluginScene3DAssembly.assemble(
                    asset: asset,
                    descriptor: descriptor,
                    assetDirectory: assetDirectory,
                    slotSize: slotSize,
                    artwork: artwork,
                    palette: effectivePalette,
                    rasterizer: rasterizerFactory()
                )
                install(instance, pose: descriptorCamera)
            } catch let failure as PluginScene3DFailure {
                fail(failure)
            } catch {
                fail(.decodeFailed(error.localizedDescription))
            }
        case .failure(let failure):
            fail(failure)
        }
    }

    /// Rebuilds from the cached template after the slot size changed, keeping
    /// the user's current camera angle and avoiding a network/disk decode.
    private func reassembleForNewSize(preserving pose: Scene3DCameraController.Pose) {
        guard let current = instance,
              let asset = cache.cachedAsset(for: current.identity) else {
            teardownInstance()
            beginLoadIfPossible()
            return
        }
        do {
            let next = try PluginScene3DAssembly.assemble(
                asset: asset,
                descriptor: descriptor,
                assetDirectory: assetDirectory,
                slotSize: slotSize,
                artwork: artwork,
                palette: effectivePalette,
                rasterizer: rasterizerFactory()
            )
            install(next, pose: pose)
        } catch let failure as PluginScene3DFailure {
            fail(failure)
        } catch {
            fail(.decodeFailed(error.localizedDescription))
        }
    }

    private func install(_ instance: PluginScene3DInstance,
                         pose: Scene3DCameraController.Pose) {
        cancelLoad()
        teardownInstance()

        self.instance = instance
        pressAppearance = [:]
        for hit in instance.hits where pressAppearance[hit.node] == nil {
            if let node = instance.contentRoot.childNode(withName: hit.node, recursively: true) {
                pressAppearance[hit.node] = (node.scale, node.opacity)
            }
        }
        let camera = Scene3DCameraController(
            initialPose: pose,
            limits: Scene3DCameraController.Limits(
                horizontal: descriptor.rotate.horizontal,
                vertical: descriptor.rotate.vertical,
                pitchMin: descriptor.rotate.resolvedPitchRange.lowerBound,
                pitchMax: descriptor.rotate.resolvedPitchRange.upperBound
            )
        )
        let session = Scene3DInputSession(
            hitProvider: self,
            camera: camera,
            hits: instance.hits,
            reduceMotion: reduceMotion,
            cameraPosition: { pose in
                Scene3DCameraController.Geometry.worldPosition(for: pose,
                                                               distance: instance.cameraDistance)
            },
            actionSink: { [weak self] id, value in
                self?.animatePress(for: id)
                self?.actionSink(id, value)
            }
        )
        session.onCameraChanged = { [weak self] pose in
            self?.applyCamera(pose)
        }
        session.start()
        hitSession = session
        instance.apply(pose)

        accessibilityElements = Scene3DAccessibilityModel.elements(
            texts: instance.texts,
            hits: instance.hits,
            resetViewLabel: resetViewLabel
        )
        state = .ready(instance.identity)
        host?.mountScene(instance.scene)
        host?.refreshDisplay()
        stopFrameLoop()
    }

    private func fail(_ failure: PluginScene3DFailure) {
        loadTask = nil
        hitSession?.stop()
        stopFrameLoop()
        teardownInstance()
        state = .fallback(failure)
    }

    private func applyCamera(_ pose: Scene3DCameraController.Pose) {
        instance?.apply(pose)
        host?.refreshDisplay()
    }

    // MARK: - Frames

    private func startFrameLoopIfNeeded() {
        guard isActive, !isCameraSettled else { return }
        if frameScheduler?.isRunning == true { return }
        let scheduler = frameScheduler ?? frameSchedulerFactory()
        frameScheduler = scheduler
        scheduler.start { [weak self] delta in
            self?.advanceFrame(by: delta)
        }
    }

    private func advanceFrame(by delta: TimeInterval) {
        guard isActive, let session = hitSession else {
            stopFrameLoop()
            return
        }
        let keepRunning = session.advance(by: delta)
        if !keepRunning {
            stopFrameLoop()
        }
    }

    private func stopFrameLoop() {
        frameScheduler?.stop()
        frameScheduler = nil
    }

    // MARK: - Teardown

    private func teardownInstance() {
        host?.mountScene(nil)
        hitSession?.stop()
        hitSession = nil
        instance?.teardown()
        instance = nil
        pressAppearance = [:]
        accessibilityElements = []
    }

    private func animatePress(for actionID: String) {
        guard !reduceMotion(), let instance,
              let hit = instance.hits.first(where: { $0.actionID == actionID }),
              let appearance = pressAppearance[hit.node],
              let node = instance.contentRoot.childNode(withName: hit.node, recursively: true)
        else { return }
        node.removeAction(forKey: "scene3d.press")
        node.scale = appearance.scale
        node.opacity = appearance.opacity
        let down = SCNAction.group([.scale(by: 0.94, duration: 0.08),
                                    .fadeOpacity(to: appearance.opacity * 0.62, duration: 0.08)])
        let up = SCNAction.group([.scale(by: 1 / 0.94, duration: 0.18),
                                  .fadeOpacity(to: appearance.opacity, duration: 0.18)])
        down.timingMode = .easeOut
        up.timingMode = .easeOut
        node.runAction(.sequence([down, up]), forKey: "scene3d.press")
        host?.refreshDisplay()
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
        generation += 1
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }
}
