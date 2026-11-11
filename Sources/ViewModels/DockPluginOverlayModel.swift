//
//  DockPluginOverlayModel.swift
//  Switchly
//
//  Plugin render state for the Dock preview. Renders only while the panel is
//  visible: start() on show / target change, stop() on hide, which cancels the
//  refresh loop and detaches invalidations but keeps the plugin VMs, so a round
//  in progress (a dealt hand, a revealed song) continues when the panel reopens.
//  unload() is the hard reset that also frees the VMs. Main thread only.
//

import AppKit
import Combine

/// A host-owned action address. Percent-encoding each component keeps plugin
/// IDs and action IDs separate even when either contains punctuation.
struct PluginActionNamespace: Hashable {
    let pluginID: String
    let actionID: String

    var identifier: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let plugin = pluginID.addingPercentEncoding(withAllowedCharacters: allowed) ?? pluginID
        let action = actionID.addingPercentEncoding(withAllowedCharacters: allowed) ?? actionID
        return "switchly-plugin-action:\(plugin):\(action)"
    }
}

/// One plugin's content for a slot. Several plugins may share a slot (the
/// Music card and the weather gacha both ask for `center`), so slots hold a
/// stack instead of a single winner.
struct PluginSlotEntry: Identifiable, Equatable {
    let id: String
    let node: PluginUINode
    /// The plugin's directory, for `scene` sprite assets.
    let directory: URL?
}

final class DockPluginOverlayModel: ObservableObject {
    private struct DisplayState {
        var slots: [PluginSlot: [PluginSlotEntry]] = [:]
        var artwork: NSImage?
        var artworkToken: String?
        var owners: [String: OwnedAction] = [:]
        var mediaRead: MediaReadContext?
    }
    @Published private var display = DisplayState()
    var slots: [PluginSlot: [PluginSlotEntry]] { display.slots }
    var slotsPublisher: AnyPublisher<[PluginSlot: [PluginSlotEntry]], Never> {
        $display.map(\.slots).removeDuplicates().eraseToAnyPublisher()
    }
    var artwork: NSImage? { display.artwork }
    var artworkToken: String? { display.artworkToken }
    var mediaRead: MediaReadContext? { display.mediaRead }
    private var artworkRevision = 0
    private var artworkData: Data?
    private var mediaInterest: MediaReadInterest?
    private var runtimeInterest: PluginLifetime?
    private var rendering = false
    private var renderRequested = false
    var hasCenter: Bool { !(slots[.center] ?? []).isEmpty }

    func hasWindowPlugins(bundleID: String) -> Bool {
        host.installedPlugins().contains {
            $0.authorization.isEnabled && $0.package.manifest.renderScope == .window && $0.package.manifest.matches(bundleID: bundleID)
        }
    }

    /// Upper bound per slot, so one misbehaving plugin cannot push the panel down.
    static let maxEntriesPerSlot = 3

    /// True when an active plugin's own option asks to drop the window thumbnails.
    func hidesWindowPreviews(in settings: AppSettings) -> Bool {
        runtimes.contains { runtime in
            runtime.manifest.hidePreviewsKeys.contains {
                settings.pluginSettings[runtime.manifest.id]?[$0.key] ?? $0.default
            }
        }
    }

    /// Re-render cadence when a plugin does not declare refreshInterval.
    static let defaultRefreshInterval: TimeInterval = 1

    private let host: PluginHosting
    private let scope: PluginRenderScope
    private var context: PluginRenderContext?
    private var runtimes: [PluginRuntimeProtocol] = []
    private var readsMedia: Bool { scope == .app || runtimes.contains { $0.manifest.permissions.contains(.mediaNowPlaying) } }
    private struct OwnedAction {
        let runtime: PluginRuntimeProtocol
        let namespace: PluginActionNamespace
    }
    private var actionOwners: [String: OwnedAction] { display.owners }
    private var loopTask: Task<Void, Never>?
    /// Bumped on every start/stop so a render that finishes after the
    /// target changed cannot overwrite newer state.
    private var generation = 0
    /// Prevent an older async refresh from publishing after a newer one.
    private var renderRevision = 0
    private var pendingActions = 0

    init(host: PluginHosting = PluginHost.shared, scope: PluginRenderScope = .app) {
        self.host = host
        self.scope = scope
    }


    func start(context: PluginRenderContext) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard context.bundleID != self.context?.bundleID || context.windowID != self.context?.windowID
                || context.pid != self.context?.pid || context.captureTarget != self.context?.captureTarget else { return }
        stop()
        let runtimes = host.runtimes(for: context.bundleID).filter { ($0.manifest.renderScope ?? .app) == scope }
        guard !runtimes.isEmpty else { return }
        var context = context
        context.presentationID = UUID().uuidString
        self.context = context
        self.runtimes = runtimes
        if scope == .window { AppLogger.debug("Window plugin started. windowID=\(context.windowID) generation=\(self.generation) runtimes=\(runtimes.count)") }
        let generation = self.generation
        if readsMedia {
            mediaInterest = host.acquireMediaRead(for: context.bundleID) { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == generation else { return }
                    // 先撤销旧封面；文字与下一批封面仍作为一个状态提交。
                    if self.display.mediaRead?.artworkIsCurrent() != true {
                        var cleared = self.display
                        cleared.artwork = nil
                        cleared.artworkToken = nil
                        self.display = cleared
                        self.artworkData = nil
                    }
                    self.renderRevision += 1
                    self.renderOnce(generation: generation)
                }
            }
        }
        runtimeInterest = host.acquireRuntimeVisibility(runtimes) { [weak self] in
            DispatchQueue.main.async { self?.renderOnce(generation: generation) }
        }
        let interval = runtimes.compactMap { $0.manifest.effectiveRefreshInterval }.min() ?? Self.defaultRefreshInterval
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.render(generation: generation)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        generation += 1
        renderRevision += 1
        pendingActions = 0
        loopTask?.cancel()
        loopTask = nil
        runtimeInterest?.cancel()
        runtimeInterest = nil
        mediaInterest?.cancel()
        mediaInterest = nil
        renderRequested = false
        runtimes = []
        context = nil
        display = DisplayState()
        artworkData = nil
    }

    /// 授权变化后重新向 Host 取运行时，不能让可见面板继续使用旧授权对象。
    func reloadCurrentContext() {
        guard let current = context else { return }
        stop()
        start(context: current)
    }

    /// Hard reset: frees every plugin VM, so a plugin's own state starts over.
    func unload() {
        stop()
        host.unmountAll()
    }

    deinit {
        loopTask?.cancel()
        runtimeInterest?.cancel()
        mediaInterest?.cancel()
        // Host 可被多个叠层共享；销毁一个消费者不能卸载其他人的 VM 和读取兴趣。
    }

    /// Routes a control event to the plugin that rendered it, then re-renders.
    func perform(actionID: String, value: Double? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let owned = actionOwners[actionID] ?? legacyActionOwner(actionID), let context else { return }
        perform(owned: owned, value: value, context: context)
    }

    /// Explicit route used by rendered slot entries. The plugin's own action ID
    /// remains unchanged when it crosses into the runtime.
    func perform(pluginID: String, actionID: String, value: Double? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let namespace = PluginActionNamespace(pluginID: pluginID, actionID: actionID)
        guard let owned = actionOwners[namespace.identifier], let context else { return }
        perform(owned: owned, value: value, context: context)
    }

    private func perform(owned: OwnedAction, value: Double?, context: PluginRenderContext) {
        if owned.namespace.actionID == "next" || owned.namespace.actionID == "previous" {
            artworkData = nil
            display.artwork = nil
            display.artworkToken = nil
        }
        let generation = self.generation
        pendingActions += 1
        renderRevision += 1
        Task { @MainActor [weak self] in
            if case .failure(let error) = await owned.runtime.performAction(
                id: owned.namespace.actionID, value: value, context: context
            ) {
                AppLogger.warning("Plugin action failed. plugin=\(owned.runtime.manifest.id) action=\(owned.namespace.actionID) error=\(error)")
            }
            guard let self, generation == self.generation else { return }
            self.pendingActions -= 1
            if self.pendingActions == 0 { await self.render(generation: generation) }
            // External state can settle after the command returns (Music's
            // `player state` lags `playpause`). One bounded reconciliation
            // repaints the control without waiting for the next refresh tick;
            // a hidden panel or a newer action drops the late render.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard generation == self.generation, self.pendingActions == 0 else { return }
            await self.render(generation: generation)
        }
    }

    /// Keeps the legacy `perform(actionID:)` call path for one owner. If two
    /// plugins expose the same raw ID, only the namespaced path is unambiguous.
    private func legacyActionOwner(_ actionID: String) -> OwnedAction? {
        let matches = actionOwners.values.filter { $0.namespace.actionID == actionID }
        guard matches.count == 1 else {
            if matches.count > 1 {
                AppLogger.throttledWarning(
                    key: "plugin.action.ambiguous.\(actionID)",
                    "Plugin action is ambiguous without a namespace. action=\(actionID) owners=\(matches.count)"
                )
            }
            return nil
        }
        return matches[0]
    }

    private func renderOnce(generation: Int, allowRetry: Bool = true) {
        Task { @MainActor [weak self] in await self?.render(generation: generation, allowRetry: allowRetry) }
    }

    @MainActor
    private func render(generation: Int, allowRetry: Bool = true) async {
        guard generation == self.generation, pendingActions == 0, let context else { return }
        if rendering { renderRequested = true; return }
        rendering = true
        defer {
            rendering = false
            if renderRequested {
                renderRequested = false
                renderOnce(generation: self.generation, allowRetry: false)
            }
        }
        renderRevision += 1
        let revision = renderRevision
        let mediaRead: MediaReadContext?
        if readsMedia { mediaRead = await host.mediaRead(for: context.bundleID) }
        else { mediaRead = nil }
        guard generation == self.generation, revision == renderRevision else { return }
        var merged: [PluginSlot: [PluginSlotEntry]] = [:]
        var owners: [String: OwnedAction] = [:]
        for runtime in runtimes {
            // A failing plugin only loses its own overlay.
            guard case .success(let contents) = await runtime.render(context: context, mediaRead: mediaRead) else { continue }
            guard generation == self.generation, revision == renderRevision else { return }
            // Plugins render in registry order and stack inside a slot, capped.
            for content in contents {
                guard (merged[content.slot]?.count ?? 0) < Self.maxEntriesPerSlot else { continue }
                merged[content.slot, default: []].append(PluginSlotEntry(id: runtime.manifest.id,
                                                                       node: content.node,
                                                                       directory: runtime.assetDirectory))
                content.node.actionIDs.forEach { actionID in
                    let namespace = PluginActionNamespace(pluginID: runtime.manifest.id, actionID: actionID)
                    owners[namespace.identifier] = OwnedAction(runtime: runtime, namespace: namespace)
                }
            }
        }
        guard generation == self.generation, revision == renderRevision else { return }
        let usesArtwork = merged.values.contains { $0.contains { $0.node.usesArtwork } }
        let image: NSImage?
        let token: String?
        if let mediaRead {
            guard await host.mediaReadIsCurrent(mediaRead, bundleID: context.bundleID) else {
                renderRequested = allowRetry
                return
            }
            image = usesArtwork ? mediaRead.artwork : nil
            token = usesArtwork ? mediaRead.artworkToken : nil
        } else if usesArtwork {
            // 自定义 Host/fixture 的兼容路径也先准备图片再整批发布。
            let data = usesArtwork ? await host.artwork(for: context.bundleID) : nil
            let decoded = await Task.detached {
                MediaReadContext(nowPlaying: nil, artwork: data.flatMap { MediaArtworkDecoder.decode($0) },
                                 artworkToken: nil, validate: { true })
            }.value
            image = decoded.artwork
            if data != artworkData { artworkRevision += 1 }
            artworkData = data
            token = image == nil ? nil : "artwork-\(artworkRevision)"
        } else {
            image = nil
            token = nil
            artworkData = nil
        }
        guard generation == self.generation, revision == renderRevision else { return }
        guard mediaRead?.isFresh() != false else {
            renderRequested = allowRetry
            return
        }
        display = DisplayState(slots: merged, artwork: image, artworkToken: token, owners: owners, mediaRead: mediaRead)
    }
}
