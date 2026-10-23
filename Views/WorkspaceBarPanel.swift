//
//  WorkspaceBarPanel.swift
//  Switchly
//
//  Centered workspace window switcher
//

import SwiftUI
import AppKit
import Combine

/// Shared layout constants for the workspace bar so the panel frame, the
/// SwiftUI layout, and the card design always agree on sizes.
private enum WorkspaceBarMetrics {
    // Cards
    static let cardWidth: CGFloat = 208
    static let cardPadding: CGFloat = 10
    static let cardInnerSpacing: CGFloat = 8
    static let cardSpacing: CGFloat = 12          // gap between cards
    static let thumbnailHeight: CGFloat = 118
    static let cardTextHeight: CGFloat = 20       // app icon chip + title row

    // Panel
    static let panelPadding: CGFloat = 16
    static let headerHeight: CGFloat = 28         // glyph + name (+ window count)
    static let panelSpacing: CGFloat = 12         // header / strip / footer gap
    static let footerHeight: CGFloat = 20         // indicator pills + key hints
    // 12 + 12 inside the ScrollView. Deliberately roomy: the selected
    // card scales 1.03 (about 3 pt per side on a 208 pt card), so a card
    // resting against the strip edge would grow past the ScrollView clip and
    // lose part of its accent ring.
    static let scrollHorizontalPadding: CGFloat = 24
    static let minimumPanelWidth: CGFloat = 360

    static var thumbnailWidth: CGFloat {
        cardWidth - cardPadding * 2
    }

    static var cardHeight: CGFloat {
        cardPadding * 2 + thumbnailHeight + cardInnerSpacing + cardTextHeight
    }

    static var panelHeight: CGFloat {
        panelPadding * 2 + headerHeight + panelSpacing + cardHeight + panelSpacing + footerHeight
    }

    /// Width the panel needs to fit `itemCount` cards without any horizontal
    /// blank space. Falls back to the minimum for an empty workspace.
    static func panelWidth(for itemCount: Int) -> CGFloat {
        guard itemCount > 0 else { return minimumPanelWidth }
        return CGFloat(itemCount) * cardWidth
            + CGFloat(itemCount - 1) * cardSpacing
            + panelPadding * 2
            + scrollHorizontalPadding
    }
}

/// Content width of the workspace bar's card strip. Compared against
/// the panel width to decide whether the scroll-affordance edge fade should
/// be shown.
private struct StripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

class WorkspaceBarPanel: NSPanel {
    static let shared = WorkspaceBarPanel()
    private static let panelHeight = WorkspaceBarMetrics.panelHeight
    private static let minimumPanelWidth: CGFloat = WorkspaceBarMetrics.minimumPanelWidth
    private static let horizontalScreenMargin: CGFloat = 48

    private let viewModel = WorkspaceBarViewModel()
    private var keyDownMonitor: Any?
    private var itemsCancellable: AnyCancellable?
    private var isSwitching = false
    private var isDismissing = false
    private var interestCancellable: AnyCancellable?

    /// Bumped on every show; a dismissal animation only closes the panel
    /// when its generation is still current (see `hide()`).
    private var generation = 0

    private init() {
        let contentRect = NSRect(x: 0, y: 0, width: Self.minimumPanelWidth, height: Self.panelHeight)
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        hasShadow = false
        isOpaque = false
        isReleasedWhenClosed = false

        let hostingView = NSHostingView(rootView: WorkspaceBarView(viewModel: viewModel))
        hostingView.autoresizingMask = [.width, .height]
        contentView = hostingView
        applyRoundedCorners()

        positionInCurrentScreen()
        setupKeyHandling()
        observeItemsChanges()
    }

    override var canBecomeKey: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if handleKey(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func resignKey() {
        super.resignKey()
        if isVisible && !isSwitching {
            hide()
        }
    }

    func show(workspaceID: UUID, source: UsageEventSource = .workspaceShortcut) {
        generation += 1
        // The workspace bar is keyboard-only: there is no pointer entry point
        // to compare against, which the panel states explicitly.
        UsageStatisticsService.shared.record(.workspacePresented, source: source, at: Date())
        viewModel.show(workspaceID: workspaceID)
        positionInCurrentScreen()
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Motion.fadePanel(self, to: 1, duration: MotionTokens.panelDuration)
    }

    func hide() {
        guard !isDismissing else {
            return
        }
        isDismissing = true
        let generationAtDismiss = generation
        viewModel.hide()
        Motion.fadePanel(self, to: 0, duration: MotionTokens.panelDuration) { [weak self] in
            guard let self else {
                return
            }
            guard generationAtDismiss == self.generation else {
                // Re-shown while the dismissal animation was still running.
                self.isDismissing = false
                return
            }
            ThumbnailService.shared.clearRefreshInterest(owner: self)
            self.orderOut(nil)
            self.alphaValue = 1
            self.isDismissing = false
        }
    }

    func beginSwitch() {
        isSwitching = true
    }



    func endSwitch() {
        isSwitching = false
    }

    private func setupKeyHandling() {
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else {
                return event
            }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            hide()
            return true
        case 48:
            viewModel.selectItem(offset: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case 123:
            viewModel.selectItem(offset: -1)
            return true
        case 124:
            viewModel.selectItem(offset: 1)
            return true
        case 125:
            viewModel.switchWorkspace(offset: 1)
            return true
        case 126:
            viewModel.switchWorkspace(offset: -1)
            return true
        case 36, 76:
            Task {
                self.beginSwitch()
                if viewModel.selectedItem?.isWindow == true {
                    self.hide()
                }
                let shouldClose = await viewModel.activateSelectedItem()
                await MainActor.run {
                    self.endSwitch()
                    if shouldClose {
                        self.hide()
                    }
                }
            }
            return true
        default:
            return false
        }
    }

    private func applyRoundedCorners() {
        guard let contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.layer?.cornerRadius = GlassPanelCorner.radius
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
    }

    private func positionInCurrentScreen(
        animated: Bool = false,
        duration: TimeInterval = MotionTokens.morphDuration
    ) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            center()
            return
        }

        // The panel width adapts to the number of window cards so it is never
        // wider than its content. Clamped to a sensible minimum and to the
        // available screen width.
        let maxPanelWidth = visibleFrame.width - Self.horizontalScreenMargin * 2
        let desiredWidth = WorkspaceBarMetrics.panelWidth(for: viewModel.items.count)
        let panelWidth = min(max(desiredWidth, Self.minimumPanelWidth), maxPanelWidth)
        viewModel.panelWidth = panelWidth
        let frame = NSRect(
            x: visibleFrame.midX - panelWidth / 2,
            y: visibleFrame.midY - Self.panelHeight / 2,
            width: panelWidth,
            height: Self.panelHeight
        )
        if animated {
            // Refit the width with the morph timing so the panel breathes
            // open/closed instead of jumping (e.g. workspace switches).
            Motion.movePanel(self, to: frame, duration: duration)
        } else {
            setFrame(frame, display: true)
        }
    }

    /// Re-fits the panel width while visible when the window list changes
    /// (e.g. switching workspaces that hold different numbers of windows),
    /// and keeps the thumbnail auto-refresh tick pointed at the windows this
    /// panel shows. While no panel is on screen the tick does zero work.
    private func observeItemsChanges() {
        itemsCancellable = viewModel.$items
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isVisible else { return }
                // A workspace switch morphs the panel width at the same
                // duration as the strip slide, so the two read as one motion.
                self.positionInCurrentScreen(
                    animated: true,
                    duration: MotionTokens.workspaceSwitchDuration
                )
                self.publishRefreshInterest()
            }

        interestCancellable = viewModel.$isVisible
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                guard let self else { return }
                if visible {
                    self.publishRefreshInterest()
                } else {
                    ThumbnailService.shared.clearRefreshInterest(owner: self)
                }
            }
    }

    private func publishRefreshInterest() {
        guard isVisible else { return }
        let windowIDs = viewModel.items.compactMap { item -> CGWindowID? in
            if case .window(let window, _) = item {
                return window.id
            }
            return nil
        }
        ThumbnailService.shared.setRefreshInterest(Set(windowIDs), owner: self)
    }
}

@MainActor
final class WorkspaceBarViewModel: ObservableObject {
    @Published var workspace: Workspace?
    @Published var workspaces: [Workspace] = []
    @Published var items: [WorkspaceBarItem] = []
    @Published var selectedItemID: String?
    @Published var isVisible = false
    @Published var panelWidth: CGFloat = WorkspaceBarMetrics.minimumPanelWidth

    /// Direction of the last workspace switch; drives the strip slide.
    @Published var workspaceTransitionDirection: MotionTokens.StripDirection = .forward

    private let settingsService: SettingsServiceProtocol
    private let windowMonitorService: WindowMonitorServiceProtocol
    private let windowSwitchService: WindowSwitchServiceProtocol
    private var windowListCancellable: AnyCancellable?

    init(
        settingsService: SettingsServiceProtocol = SettingsService.shared,
        windowMonitorService: WindowMonitorServiceProtocol = WindowMonitorService.shared,
        windowSwitchService: WindowSwitchServiceProtocol = WindowSwitchService.shared
    ) {
        self.settingsService = settingsService
        self.windowMonitorService = windowMonitorService
        self.windowSwitchService = windowSwitchService
        observeWindowListChanges()
    }

    func show(workspaceID: UUID) {
        isVisible = true
        let settings = settingsService.loadSettings()
        workspaces = settings.workspaces
        workspace = workspaces.first { $0.id == workspaceID }
        refreshItems()
    }

    func hide() {
        isVisible = false
    }

    func switchWorkspace(offset: Int) {
        guard let workspace,
              !workspaces.isEmpty,
              let currentIndex = workspaces.firstIndex(where: { $0.id == workspace.id }) else {
            return
        }

        let nextIndex = (currentIndex + offset + workspaces.count) % workspaces.count
        applyWorkspace(at: nextIndex, direction: offset >= 0 ? .forward : .backward)
    }

    /// Jumps straight to a workspace (indicator pill tap). The direction
    /// follows the list order, so a tap on the pill to the right slides the
    /// strip exactly like pressing the down arrow would.
    func selectWorkspace(id: UUID) {
        guard let workspace,
              id != workspace.id,
              let currentIndex = workspaces.firstIndex(where: { $0.id == workspace.id }),
              let nextIndex = workspaces.firstIndex(where: { $0.id == id }) else {
            return
        }
        applyWorkspace(at: nextIndex, direction: nextIndex > currentIndex ? .forward : .backward)
    }

    /// Swaps the active workspace and records the travel direction so the
    /// strip slides the way the gesture pointed. `switchWorkspace` passes
    /// the arrow key’s sign (wrapping past the last workspace still travels
    /// forward); `selectWorkspace` derives it from the list order.
    private func applyWorkspace(at index: Int, direction: MotionTokens.StripDirection) {
        guard workspaces.indices.contains(index) else {
            return
        }
        self.workspace = workspaces[index]
        self.workspaceTransitionDirection = direction
        refreshItems()
    }

    func selectItem(offset: Int) {
        guard !items.isEmpty else {
            selectedItemID = nil
            return
        }

        guard let selectedItemID,
              let currentIndex = items.firstIndex(where: { $0.id == selectedItemID }) else {
            selectedItemID = items[0].id
            return
        }

        let nextIndex = (currentIndex + offset + items.count) % items.count
        self.selectedItemID = items[nextIndex].id
    }

    func activateSelectedItem() async -> Bool {
        guard let item = selectedItem else {
            return false
        }

        return await activate(item)
    }

    var selectedItem: WorkspaceBarItem? {
        guard let selectedItemID else {
            return nil
        }
        return items.first { $0.id == selectedItemID }
    }

    func activate(_ item: WorkspaceBarItem) async -> Bool {
        switch item {
        case .window(let window, _):
            do {
                try await windowSwitchService.switchToWindow(window)
                return true
            } catch {
                AppLogger.error("Workspace window switch failed. windowID=(window.id), error=\(error)")
                return false
            }
        case .placeholder(let appItem, _):
            openApp(appItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refreshItems()
            }
            return false
        }
    }

    func refreshItems() {
        guard let workspace else {
            items = []
            selectedItemID = nil
            return
        }

        let snapshot = workspace.appItems.isEmpty ? [] : windowMonitorService.getAllWindows()
        let nextItems = workspace.appItems.flatMap { appItem -> [WorkspaceBarItem] in
            // Match by name as well as bundle ID: several products can share a
            // bundle identifier (e.g. ChatGPT and ChatGPT Atlas), and without
            // the name check one product's windows would show up under the
            // other's card and switching would jump to the wrong app.
            let windows = sortedWindows(
                windowMonitorService.filterWindows(snapshot, for: appItem.bundleIdentifier, appName: appItem.appName),
                strategy: workspace.windowSortStrategy
            )

            if windows.isEmpty {
                return workspace.missingAppDisplayMode == .placeholder
                    ? [.placeholder(appItem, id: "placeholder-\(appItem.id.uuidString)")]
                    : []
            }

            return windows.map { window in
                .window(window, appItem: appItem)
            }
        }

        items = nextItems
        if let selectedItemID, nextItems.contains(where: { $0.id == selectedItemID }) {
            return
        }
        selectedItemID = nextItems.first?.id
    }

    /// Keeps the strip honest while the panel is open: closing a window
    /// through a card's traffic lights, or an app quitting on its own, must
    /// drop that card instead of leaving a dead thumbnail behind.
    private func observeWindowListChanges() {
        windowListCancellable = NotificationCenter.default.publisher(for: .windowListDidRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isVisible else { return }
                self.refreshItems()
            }
    }

    private func sortedWindows(_ windows: [WindowInfo], strategy: WorkspaceWindowSortStrategy) -> [WindowInfo] {
        switch strategy {
        case .titleAscending:
            return windows.sorted { lhs, rhs in
                let leftTitle = lhs.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let rightTitle = rhs.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if leftTitle.isEmpty != rightTitle.isEmpty {
                    return !leftTitle.isEmpty
                }
                if leftTitle != rightTitle {
                    return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
                }
                return lhs.windowNumber < rhs.windowNumber
            }
        }
    }

    private func openApp(_ appItem: WorkspaceAppItem) {
        if let runningApp = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == appItem.bundleIdentifier }) {
            runningApp.activate(options: [.activateIgnoringOtherApps])
            return
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appItem.bundleIdentifier) else {
            AppLogger.warning("Cannot open workspace placeholder app. bundleID=\(appItem.bundleIdentifier)")
            return
        }

        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                AppLogger.error("Failed to open workspace app. bundleID=\(appItem.bundleIdentifier), error=\(error)")
            }
        }
    }
}

enum WorkspaceBarItem: Identifiable, Equatable {
    case window(WindowInfo, appItem: WorkspaceAppItem)
    case placeholder(WorkspaceAppItem, id: String)

    var id: String {
        switch self {
        case .window(let window, _):
            return "window-\(window.id)"
        case .placeholder(_, let id):
            return id
        }
    }

    var title: String {
        switch self {
        case .window(let window, _):
            return window.displayName
        case .placeholder(let appItem, _):
            return appItem.appName
        }
    }

    /// The backing window for card-level affordances (traffic lights).
    /// `nil` for placeholders, which have no window to act on.
    var window: WindowInfo? {
        if case .window(let window, _) = self {
            return window
        }
        return nil
    }

    var appItem: WorkspaceAppItem {
        switch self {
        case .window(_, let appItem):
            return appItem
        case .placeholder(let appItem, _):
            return appItem
        }
    }

    var isWindow: Bool {
        if case .window = self {
            return true
        }
        return false
    }
}

struct WorkspaceBarView: View {
    @ObservedObject var viewModel: WorkspaceBarViewModel
    @State private var settings = SettingsService.shared.loadSettings()
    /// Content width of the card strip — drives the scroll-affordance fade.
    @State private var stripContentWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceBarMetrics.panelSpacing) {
            header

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: WorkspaceBarMetrics.cardSpacing) {
                        if viewModel.items.isEmpty {
                            emptyState
                        } else {
                            ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                                WorkspaceBarCard(
                                    item: item,
                                    isSelected: viewModel.selectedItemID == item.id,
                                    settings: settings
                                ) {
                                    Task {
                                        WorkspaceBarPanel.shared.beginSwitch()
                                        if item.isWindow {
                                            WorkspaceBarPanel.shared.hide()
                                        }
                                        let shouldClose = await viewModel.activate(item)
                                        await MainActor.run {
                                            WorkspaceBarPanel.shared.endSwitch()
                                            if shouldClose {
                                                WorkspaceBarPanel.shared.hide()
                                            }
                                        }
                                    }
                                }
                                .id(item.id)
                                .staggeredEntrance(index: index, axis: .horizontal)
                                .transition(MotionTokens.cardTransition)
                            }
                        }
                    }
                    .padding(.horizontal, WorkspaceBarMetrics.scrollHorizontalPadding / 2)
                    .background(
                        // Measure the strip content so the edge fade below
                        // only appears when there is something to scroll to.
                        GeometryReader { proxy in
                            Color.clear.preference(key: StripWidthKey.self, value: proxy.size.width)
                        }
                    )
                    // Swapping workspaces slides the strip in the direction of
                    // travel, mirroring the arrow key that triggered it.
                    .id(viewModel.workspace?.id)
                    .transition(MotionTokens.stripTransition(direction: viewModel.workspaceTransitionDirection))
                }
                .onPreferenceChange(StripWidthKey.self) { width in
                    stripContentWidth = width
                }
                .mask(stripMask)
                .animation(
                    MotionTokens.animated(.easeOut(duration: MotionTokens.workspaceSwitchDuration)),
                    value: viewModel.workspace?.id
                )
                .onChange(of: viewModel.selectedItemID) { selectedID in
                    guard let selectedID else {
                        return
                    }
                    // Always .center, never .leading / .trailing: aligning the
                    // selected card to the strip edge pushes it (and the 1.03
                    // selection scale that grows it past its frame) into the
                    // ScrollView clip, which cuts the accent ring off. Centering
                    // clamps to the natural position for the first and last
                    // card, so neither can ever reach a clip edge.
                    withAnimation(MotionTokens.animated(.easeOut(duration: MotionTokens.microDuration))) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }

            footer
        }
        .padding(WorkspaceBarMetrics.panelPadding)
        .frame(width: viewModel.panelWidth, height: WorkspaceBarMetrics.panelHeight)
        .scaleEffect(viewModel.isVisible ? 1 : 0.96, anchor: .center)
        .opacity(viewModel.isVisible ? 1 : 0)
        .animation(MotionTokens.animated(MotionTokens.panelSpring), value: viewModel.isVisible)
        .panelGlass(
            isActive: (settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque),
            opacity: backgroundOpacity,
            cornerRadius: GlassPanelCorner.radius,
            material: settings.crystalMaterial
        )
        .shadow(color: .black.opacity(0.24), radius: 22, x: 0, y: 12)
        .preferredColorScheme(settings.theme.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChange)) { _ in
            settings = SettingsService.shared.loadSettings()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            workspaceGlyph

            VStack(alignment: .leading, spacing: 1) {
                workspaceName
                windowCount
            }

            Spacer(minLength: 8)

            counterBadge
        }
        .frame(height: WorkspaceBarMetrics.headerHeight)
    }

    /// Accent-tinted glyph standing in for the workspace itself — the name
    /// alone used to leave the header visually unanchored next to the strip.
    private var workspaceGlyph: some View {
        Image(systemName: "rectangle.3.group")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.accentColor)
            .frame(width: 26, height: 26)
            .cardSurface(
                fill: Color.accentColor.opacity((settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.16 : 0.10),
                cornerRadius: DesignTokens.Radius.control
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.control, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: DesignTokens.hairline)
            )
            .accessibilityHidden(true)
    }

    /// Workspace name. Crossfades on switch (macOS 13+); under Reduce Motion
    /// and on older systems the text simply swaps.
    private var workspaceName: some View {
        let name = Text(viewModel.workspace?.name ?? t("Workspaces"))
            .font(.headline)
            .lineLimit(1)
        return Group {
            if #available(macOS 13.0, *), !MotionTokens.reduceMotion {
                name.contentTransition(.opacity)
            } else {
                name
            }
        }
        .animation(
            MotionTokens.animated(.easeOut(duration: MotionTokens.workspaceSwitchDuration)),
            value: viewModel.workspace?.id
        )
    }

    /// Window count in the current workspace, rolled like the preview
    /// panel's header so the two panels share one rhythm.
    private var windowCount: some View {
        let text = Text(String(format: t("%d windows"), viewModel.items.count))
            .font(.caption)
            .foregroundColor(.secondary)
        return Group {
            if #available(macOS 13.0, *), !MotionTokens.reduceMotion {
                text.contentTransition(.numericText())
            } else {
                text
            }
        }
        .animation(
            MotionTokens.animated(.easeOut(duration: MotionTokens.contentSwapDuration)),
            value: viewModel.items.count
        )
    }

    /// "2 / 5" position pill — tells the user where they are in the list
    /// without counting cards, and rolls its digits on every switch.
    private var counterBadge: some View {
        let index = (viewModel.workspaces.firstIndex(where: { $0.id == viewModel.workspace?.id }) ?? 0) + 1
        let text = Text("\(index) / \(viewModel.workspaces.count)")
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundColor(.secondary)
        return Group {
            if #available(macOS 13.0, *), !MotionTokens.reduceMotion {
                text.contentTransition(.numericText())
            } else {
                text
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .cardSurface(fill: chipFill, cornerRadius: DesignTokens.Radius.chip)
        .animation(
            MotionTokens.animated(.easeOut(duration: MotionTokens.contentSwapDuration)),
            value: index
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            workspaceIndicator

            Spacer(minLength: 12)

            keyHints
        }
        .frame(height: WorkspaceBarMetrics.footerHeight)
    }

    /// One pill per workspace; the active one widens into a capsule. Tapping
    /// a pill jumps to that workspace with the same slide the arrow keys
    /// produce, so the indicator is both a map and a control.
    @ViewBuilder
    private var workspaceIndicator: some View {
        if viewModel.workspaces.count >= 2 {
            HStack(spacing: 7) {
                ForEach(viewModel.workspaces) { workspace in
                    let isActive = workspace.id == viewModel.workspace?.id
                    Button {
                        viewModel.selectWorkspace(id: workspace.id)
                    } label: {
                        Capsule()
                            .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.32))
                            .frame(width: isActive ? 20 : 7, height: 7)
                            .padding(.vertical, 6)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(workspace.name)
                    .accessibilityLabel(workspace.name)
                    .accessibilityHint(t("Switch workspace"))
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                    .animation(MotionTokens.animated(MotionTokens.indicatorSpring), value: isActive)
                }
            }
        }
    }

    /// Keyboard affordances. A borderless panel gives no chrome to hint at
    /// its keys, so the switching vocabulary is spelled out instead.
    private var keyHints: some View {
        HStack(spacing: 10) {
            if viewModel.workspaces.count >= 2 {
                hintKey("↑↓", t("Switch workspace"))
            }
            hintKey("←→", t("Select window"))
            hintKey("↵", t("Switch"))
        }
    }

    private func hintKey(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption2.weight(.semibold).monospaced())
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .cardSurface(fill: chipFill, cornerRadius: DesignTokens.Radius.chip)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.chip, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: DesignTokens.hairline)
                )
            Text(text)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var chipFill: Color {
        Color(nsColor: .controlBackgroundColor)
            .opacity((settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.28 : 1)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.secondary)
            Text(t("No windows in this workspace"))
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)
            Text(t("Add apps in the Workspaces window."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(width: max(viewModel.panelWidth - 60, 0), height: 96)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Strip mask

    /// Edge fade while the strip overflows — the strip hides its scroll
    /// indicators, so this is the only "more content" affordance.
    ///
    /// The fade band is a fixed 16 pt, not a percentage of the panel: a 4%
    /// band on a wide panel swallowed half of the first card, accent ring
    /// included, and read as a clipped border rather than a hint.
    @ViewBuilder
    private var stripMask: some View {
        if stripContentWidth > viewModel.panelWidth {
            let fade = min(16 / max(viewModel.panelWidth, 1), 0.2)
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: fade),
                    .init(color: .black, location: 1 - fade),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Rectangle()
        }
    }

    private var backgroundOpacity: Double {
        min(max(settings.panelGlassDensity, 0), 1)
    }

    private func t(_ key: String) -> String {
        settings.language.localizedString(key)
    }
}

private struct WorkspaceBarCard: View {
    let item: WorkspaceBarItem
    let isSelected: Bool
    let settings: AppSettings
    let action: () -> Void

    @State private var thumbnailState: ThumbnailLoadState
    /// Hover lives inside the card — see WindowThumbnailView.
    @State private var isHovered = false
    @Environment(\.colorScheme) private var inheritedColorScheme
    /// Resolved once in init: NSWorkspace.icon(forFile:) hits the file system
    /// and QuickLook, and this used to run on every body evaluation.
    private let appIcon: NSImage

    init(item: WorkspaceBarItem, isSelected: Bool, settings: AppSettings, action: @escaping () -> Void) {
        self.item = item
        self.isSelected = isSelected
        self.settings = settings
        self.action = action
        self.appIcon = AppIconCache.icon(forBundleIdentifier: item.appItem.bundleIdentifier)
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage()
        // Show the cached thumbnail immediately so workspace cards never flash
        // a loading spinner for a window that was already captured (the common
        // case, since the monitor preheats high-value windows on every window-
        // list change). Placeholder items have no window, so they stay on
        // `.loading` and render the placeholder via `thumbnailArea`.
        let initial: ThumbnailLoadState
        if let window = item.window,
           let cached = ThumbnailService.shared.getCachedThumbnail(for: window) {
            initial = .loaded(cached)
        } else {
            initial = .loading
        }
        _thumbnailState = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceBarMetrics.cardInnerSpacing) {
            thumbnailArea

            titleRow
        }
        .padding(WorkspaceBarMetrics.cardPadding)
        .frame(
            width: WorkspaceBarMetrics.cardWidth,
            height: WorkspaceBarMetrics.cardHeight,
            alignment: .topLeading
        )
        .cardSurface(
            fill: cardFill,
            cornerRadius: DesignTokens.Radius.card,
            material: settings.crystalMaterial,
            isSelected: isSelected || isHovered
        )
        .crystalSpecularRim(
            cornerRadius: DesignTokens.Radius.card,
            material: settings.crystalMaterial,
            isHighlighted: isSelected || isHovered
        )
        .overlay(alignment: .topLeading) {
            // Window controls, as in the dock preview and the preview grid.
            // Revealed on hover or selection so a resting strip stays clean.
            if isHovered || isSelected, let window = item.window {
                WindowTrafficLightButtons(
                    window: window,
                    language: settings.language,
                    diameter: 10
                )
                .padding(WorkspaceBarMetrics.cardPadding - 2)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Selection marker. Keyboard navigation moves the selection
            // without a pointer, so the selected card needs a badge that
            // survives at a glance — the accent ring alone does not when the
            // strip also scrolls under the edge fade.
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor))
                    .shadow(color: .black.opacity(0.22), radius: 3, x: 0, y: 1)
                    .padding(WorkspaceBarMetrics.cardPadding - 2)
                    .accessibilityHidden(true)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
        .onTapGesture(perform: action)
        .scaleEffect(isSelected ? 1.03 : (isHovered ? 1.02 : 1.0))
        .shadow(color: .black.opacity(isSelected ? 0.28 : 0), radius: isSelected ? 10 : 0, x: 0, y: 4)
        // Accent glow under the selection so it reads as lifted off the glass.
        .shadow(color: Color.accentColor.opacity(isSelected ? 0.35 : 0), radius: isSelected ? 10 : 0, x: 0, y: 4)
        .animation(MotionTokens.animated(MotionTokens.cardSpring), value: isSelected)
        .animation(MotionTokens.animated(MotionTokens.microSpring), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: item.id) {
            await loadThumbnail()
        }
        .onReceive(NotificationCenter.default.publisher(for: .thumbnailDidUpdate)) { notification in
            guard let windowID = notification.object as? CGWindowID,
                  let window = item.window,
                  windowID == window.id,
                  let cached = ThumbnailService.shared.getCachedThumbnail(for: window) else {
                return
            }
            // Background refreshes swap without the crossfade — see
            // WindowThumbnailView.
            if notification.userInfo?["animated"] as? Bool == false {
                var transaction = Transaction()
                transaction.animation = nil
                withTransaction(transaction) {
                    thumbnailState = .loaded(cached)
                }
            } else {
                thumbnailState = .loaded(cached)
            }
        }
        .environment(\.colorScheme, cardColorScheme)
        .accessibilityLabel(primaryTitle)
        .accessibilityHint(item.isWindow ? t("Switch") : settings.language.localizedString("Open app"))
        .accessibilityAddTraits(.isButton)
    }

    /// A custom card backing sets the card's own text contrast; hover and
    /// selection replace the fill with an accent tint, so they keep the
    /// scheme inherited from the panel.
    private var cardColorScheme: ColorScheme {
        guard !isHovered, !isSelected else { return inheritedColorScheme }
        return settings.windowCardBackdrop.textColorScheme ?? inheritedColorScheme
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailArea: some View {
        Group {
            if item.isWindow {
                windowThumbnailArea
            } else {
                // A placeholder card is an app that is not running. Its
                // thumbnail says so; the title row carries the "Open app"
                // action, so the two never repeat the same words.
                placeholderThumbnail(
                    icon: appIcon,
                    text: settings.language.localizedString("Not running")
                )
            }
        }
        .frame(
            width: WorkspaceBarMetrics.thumbnailWidth,
            height: WorkspaceBarMetrics.thumbnailHeight
        )
    }

    @ViewBuilder
    private var windowThumbnailArea: some View {
        Group {
            switch thumbnailState {
            case .loaded(let thumbnail):
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(settings.thumbnailBackdrop.resolvedColor())
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail))
                    // Hairline inner edge: the thumbnail is the brightest
                    // surface in the panel and needs a defined rim against the
                    // card fill, exactly like a real window against a desktop.
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.16), lineWidth: DesignTokens.hairline)
                    )
                    .transition(MotionTokens.thumbnailTransition)
            case .failed(let fallbackIcon):
                placeholderThumbnail(icon: fallbackIcon, text: settings.language.localizedString("Preview unavailable"))
                    .transition(.opacity)
            case .placeholder(let fallbackIcon):
                placeholderThumbnail(icon: fallbackIcon, text: settings.language.localizedString("Loading preview"))
                    .transition(.opacity)
            case .loading:
                // .fill(), not .cardSurface(): a bare Shape paints itself with
                // the foreground style, which would cover the skeleton fill
                // with a solid block.
                RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail)
                    .fill(skeletonFill)
                    .overlay(ProgressView().progressViewStyle(.circular))
                    .skeletonPulse(isActive: true)
                    .transition(.opacity)
            }
        }
        .animation(MotionTokens.animated(.easeOut(duration: MotionTokens.contentSwapDuration)), value: thumbnailState)
    }


    private func placeholderThumbnail(icon: NSImage?, text: String) -> some View {
        // .fill(), not .cardSurface(): a bare Shape paints itself with the
        // foreground style, which would cover the skeleton fill with a solid
        // block (this is what the old placeholder actually rendered).
        RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail)
            .fill(skeletonFill)
            .overlay {
                VStack(spacing: 6) {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 40, height: 40)
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 26))
                            .foregroundColor(.secondary)
                    }
                    Text(text)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            // Dashed rim marks the card as "no live window" — a placeholder
            // is an action (open the app), not a preview.
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.thumbnail, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }

    private func loadThumbnail() async {
        guard let window = item.window else {
            return
        }

        if let cached = ThumbnailService.shared.getCachedThumbnail(for: window) {
            // Initial `@State` already renders the cached image; avoid an
            // unnecessary redraw. The auto-refresh tick will refresh it via
            // `.thumbnailDidUpdate` when a fresher capture lands.
            if case .loaded(let current) = thumbnailState, current === cached {
                return
            }
            await MainActor.run {
                thumbnailState = .loaded(cached)
            }
            return
        }

        let fallbackIcon = appIcon
        await MainActor.run {
            thumbnailState = .placeholder(fallbackIcon)
        }

        do {
            // Point size: ThumbnailService converts to device pixels itself
            // (× backingScaleFactor). The old `* 2` here predates that
            // conversion and double-scaled the request — 4x the needed pixels
            // on a 2x display, 9x on 3x — while sharing the grid cache key
            // with the preview panel, so the two surfaces kept overwriting
            // each other's entries at different resolutions.
            let image = try await ThumbnailService.shared.captureThumbnail(
                for: window,
                size: CGSize(
                    width: WorkspaceBarMetrics.thumbnailWidth,
                    height: WorkspaceBarMetrics.thumbnailHeight
                )
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.thumbnailState = .loaded(image)
            }
        } catch {
            guard !Task.isCancelled else { return }
            AppLogger.warning("Workspace bar thumbnail failed. windowID=\(window.id), error=\(error)")
            await MainActor.run {
                thumbnailState = .failed(appIcon)
            }
        }
    }

    // MARK: - Styling

    /// Solid card fill — see WindowThumbnailView.cardFill.
    private var cardFill: Color {
        if isHovered {
            return Color.accentColor.opacity((settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.18 : 0.10)
        }
        if isSelected {
            return Color.accentColor.opacity((settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.12 : 0.06)
        }
        return settings.windowCardFill(opacity: cardFillOpacity)
    }

    private var cardFillOpacity: Double {
        guard (settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) else { return 1 }
        return settings.crystalMaterial.cardOpacity
    }

    private var cardBorder: Color {
        if isHovered {
            return Color.accentColor.opacity(0.7)
        }
        return Color(nsColor: .separatorColor)
    }

    private var skeletonFill: Color {
        let opacity: Double = (settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.3 : 0.1
        return Color(nsColor: .textBackgroundColor).opacity(opacity)
    }

    /// App icon on a chip, matching the preview grid's title row: the bare
    /// 16pt icon used to float against the card fill.
    private var titleRow: some View {
        HStack(spacing: 6) {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .padding(3)
                .cardSurface(fill: chipFill, cornerRadius: DesignTokens.Radius.chip)
                .accessibilityHidden(true)

            Text(primaryTitle)
                .font(.caption.weight(.medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            if !item.isWindow {
                Spacer(minLength: 4)
                Text(settings.language.localizedString("Open app"))
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chipFill: Color {
        Color(nsColor: .controlBackgroundColor)
            .opacity((settings.enableBackgroundBlur && settings.crystalMaterial.glassStyle != .opaque) ? 0.5 : 1)
    }

    private var primaryTitle: String {
        switch item {
        case .window(let window, _):
            if settings.showWindowTitles && !window.windowTitle.isEmpty {
                return window.windowTitle
            }
            return window.ownerName
        case .placeholder(let appItem, _):
            return appItem.appName
        }
    }

    private func t(_ key: String) -> String {
        settings.language.localizedString(key)
    }
}
