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
    @Published private(set) var slots: [PluginSlot: [PluginSlotEntry]] = [:]
    /// Cover for `image(source: {artwork})`, drawn by the host only.
    @Published private(set) var artwork: NSImage?
    private var artworkData: Data?
    var hasCenter: Bool { !(slots[.center] ?? []).isEmpty }

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
    private var context: PluginRenderContext?
    private var runtimes: [PluginRuntimeProtocol] = []
    private var actionOwners: [String: PluginRuntimeProtocol] = [:]
    private var loopTask: Task<Void, Never>?
    /// Bumped on every start/stop so a render that finishes after the
    /// target changed cannot overwrite newer state.
    private var generation = 0

    init(host: PluginHosting = PluginHost.shared) {
        self.host = host
    }


    func start(context: PluginRenderContext) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard context.bundleID != self.context?.bundleID || context.windowID != self.context?.windowID else { return }
        stop()
        let runtimes = host.runtimes(for: context.bundleID)
        guard !runtimes.isEmpty else { return }
        self.context = context
        self.runtimes = runtimes
        let generation = self.generation
        for runtime in runtimes {
            runtime.onInvalidate = { [weak self] in
                DispatchQueue.main.async { self?.renderOnce(generation: generation) }
            }
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
        loopTask?.cancel()
        loopTask = nil
        runtimes.forEach { $0.onInvalidate = nil }
        runtimes = []
        actionOwners = [:]
        context = nil
        if !slots.isEmpty { slots = [:] }
        artwork = nil
        artworkData = nil
    }

    /// Hard reset: frees every plugin VM, so a plugin's own state starts over.
    func unload() {
        stop()
        host.unmountAll()
    }

    deinit {
        host.unmountAll()
    }

    /// Routes a control event to the plugin that rendered it, then re-renders.
    func perform(actionID: String, value: Double? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let runtime = actionOwners[actionID], let context else { return }
        let generation = self.generation
        Task { @MainActor [weak self] in
            if case .failure(let error) = await runtime.performAction(id: actionID, value: value, context: context) {
                AppLogger.warning("Plugin action failed. plugin=\(runtime.manifest.id) action=\(actionID) error=\(error)")
            }
            await self?.render(generation: generation)
        }
    }

    private func renderOnce(generation: Int) {
        Task { @MainActor [weak self] in await self?.render(generation: generation) }
    }

    @MainActor
    private func render(generation: Int) async {
        guard generation == self.generation, let context else { return }
        var merged: [PluginSlot: [PluginSlotEntry]] = [:]
        var owners: [String: PluginRuntimeProtocol] = [:]
        for runtime in runtimes {
            // A failing plugin only loses its own overlay.
            guard case .success(let contents) = await runtime.render(context: context) else { continue }
            guard generation == self.generation else { return }
            // Plugins render in registry order and stack inside a slot, capped.
            for content in contents {
                guard (merged[content.slot]?.count ?? 0) < Self.maxEntriesPerSlot else { continue }
                merged[content.slot, default: []].append(PluginSlotEntry(id: runtime.manifest.id,
                                                                       node: content.node,
                                                                       directory: runtime.assetDirectory))
                content.node.actionIDs.forEach { owners[$0] = runtime }
            }
        }
        guard generation == self.generation else { return }
        actionOwners = owners
        if merged != slots { slots = merged }
        guard merged.values.contains(where: { $0.contains { $0.node.usesArtwork } }) else { return }
        let data = await host.artwork(for: context.bundleID)
        guard generation == self.generation, data != artworkData else { return }
        artworkData = data
        artwork = data.flatMap(NSImage.init(data:))
    }
}
