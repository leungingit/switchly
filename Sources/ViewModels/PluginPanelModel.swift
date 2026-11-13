import AppKit
import Combine

@MainActor
final class PluginPanelModel: ObservableObject {
    @Published private(set) var entries: [PluginSlotSurface.Entry] = []
    @Published private(set) var errorKey: String?
    @Published private(set) var isLoading = true
    @Published private(set) var presentationRevision = UUID()
    @Published private(set) var pendingPermissions: [PluginCapability] = []
    let pluginID: String
    private let host: PluginHosting
    private var runtime: PluginRuntimeProtocol?
    private var lease: PluginLifetime?
    private var loadingTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var epoch = UUID()
    private var dataGeneration: UUID?
    private var renderRevision = 0
    private var visible = false
    private var wantsRender = false
    private var actions: [(String, Double?)] = []
    private var observers = Set<AnyCancellable>()
    private let context: PluginRenderContext

    init(pluginID: String, host: PluginHosting) {
        self.pluginID = pluginID; self.host = host
        context = PluginRenderContext(bundleID: "", pid: 0, appName: "", windowID: 0, titleSummary: "", presentationID: UUID().uuidString, surface: "panel")
        NotificationCenter.default.publisher(for: .settingsDidChange).receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.visible else { return }; self.stop(); self.start()
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: .activityDataDidChange).receive(on: DispatchQueue.main).sink { [weak self] notification in
            guard let self, self.visible else { return }
            let generation = notification.userInfo?["generation"] as? UUID
            if self.dataGeneration != generation {
                self.dataGeneration = generation; self.renderRevision &+= 1
                self.presentationRevision = UUID(); self.entries = []
            }
            self.scheduleRefresh()
        }.store(in: &observers)
    }
    func start() {
        guard !visible else { return }; visible = true
        let token = epoch
        loadingTask = Task { [weak self, host, pluginID] in
            let pending = await Task.detached(priority: .userInitiated) {
                host.installedPlugins().first(where: { $0.id == pluginID })?.authorization.pendingPermissions ?? []
            }.value
            guard let self, self.visible, self.epoch == token, !Task.isCancelled else { return }
            self.pendingPermissions = pending
            if pending.contains(.activityRead) { self.isLoading = false; return }
            let loaded = await host.loadPanelRuntime(pluginID: pluginID)
            guard self.visible, self.epoch == token, !Task.isCancelled else { return }
            guard let loaded else { self.errorKey = "Enable this plugin in Preferences to open its panel."; self.isLoading = false; return }
            self.runtime = loaded
            self.lease = host.acquireRuntimeVisibility([loaded]) { [weak self] in Task { @MainActor in self?.scheduleRefresh() } }
            self.wantsRender = true; self.pump()
            self.pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard let self, self.visible, self.epoch == token, !Task.isCancelled else { return }
                    self.scheduleRefresh()
                }
            }
        }
    }
    func stop() {
        visible = false; epoch = UUID(); loadingTask?.cancel(); loadingTask = nil
        operation?.cancel(); operation = nil; refreshTask?.cancel(); refreshTask = nil
        pollingTask?.cancel(); pollingTask = nil
        lease?.cancel(); lease = nil; runtime = nil; entries = []; isLoading = true; errorKey = nil
        pendingPermissions = []
        wantsRender = false; actions.removeAll(); presentationRevision = UUID()
    }
    func perform(id: String, value: Double?) {
        guard visible, runtime != nil else { return }
        // 拖动/连续调日期合并同一动作的尚未处理值，队列始终有界。
        if let last = actions.last, last.0 == id { actions[actions.count - 1] = (id, value) }
        else if actions.count < 16 { actions.append((id, value)) }
        wantsRender = true; pump()
    }
    private func scheduleRefresh() {
        guard visible, refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil; self.wantsRender = true; self.pump()
        }
    }
    /// Promise等待期仍保持单一操作所有者，避免refresh与onAction并发覆盖插件状态。
    private func pump() {
        guard visible, operation == nil, let runtime else { return }
        let token = epoch
        operation = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == token { self.operation = nil } }
            while self.visible && self.epoch == token && !Task.isCancelled && (self.wantsRender || !self.actions.isEmpty) {
                while !self.actions.isEmpty {
                    let action = self.actions.removeFirst()
                    _ = await runtime.performAction(id: action.0, value: action.1, context: self.context)
                    guard self.visible, self.epoch == token, !Task.isCancelled else { return }
                }
                self.wantsRender = false
                let revision = self.renderRevision
                let result = await runtime.render(context: self.context)
                guard self.visible, self.epoch == token, !Task.isCancelled else { return }
                guard revision == self.renderRevision, self.actions.isEmpty else { self.wantsRender = true; continue }
                self.isLoading = false
                switch result {
                case .success(let slots):
                    self.entries = slots.filter { $0.slot == .panel }.map { .init(id: self.pluginID, node: $0.node, assetDirectory: runtime.assetDirectory) }
                    self.errorKey = nil
                case .failure:
                    self.errorKey = "The plugin panel could not be loaded. Try reopening it."; self.entries = []
                }
            }
        }
    }
}
