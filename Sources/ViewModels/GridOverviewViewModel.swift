//
//  GridOverviewViewModel.swift
//  Switchly
//
//  State for the 3×3 desktop overview: desktop snapshot, selection, permission
//  degradation and the refresh window while the panel is visible.
//

import Foundation
import CoreGraphics
import AppKit

enum GridSelectionDirection {
    case up, down, left, right
}

/// What the overview needs to know about one desktop cell's chrome.
struct GridOverviewBanners: Equatable {
    var accessibilityMissing = false
    var screenRecordingMissing = false
    var spacesUnavailable = false
    var notCreatedCount = 0

    var isEmpty: Bool {
        !accessibilityMissing && !screenRecordingMissing && !spacesUnavailable && notCreatedCount == 0
    }
}

@MainActor
final class GridOverviewViewModel: ObservableObject {
    /// How often the visible overview re-reads Spaces and bumps the thumbnail
    /// revision. The panel stops the timer as soon as it hides, so no polling
    /// runs in the background.
    static let refreshInterval: TimeInterval = 6

    @Published private(set) var snapshot: DesktopSpaceSnapshot = .empty
    @Published private(set) var slots: [DesktopGridSlot] = DesktopGridSlot.makeSlots(from: .empty)
    @Published private(set) var isLoading = false
    @Published private(set) var isActive = false
    @Published private(set) var accessibilityGranted = true
    @Published private(set) var screenRecordingGranted = true
    @Published private(set) var thumbnailRevision = 0

    /// Per-display arrangements (see `AppSettings.gridLayouts`). Persisted by
    /// the owner through `onLayoutChanged`.
    @Published private(set) var layouts: [String: [Int]] = [:]

    /// Grid positions (0-based) of the card being dragged and of the card it
    /// would swap with; drive the drag feedback.
    @Published private(set) var draggingPosition: Int?
    @Published private(set) var dropTargetPosition: Int?

    /// Grid position → real desktop number for the display being shown.
    var layout: [Int] {
        DesktopGridLayout.sanitized(layouts[DesktopGridLayout.key(for: snapshot.displayID)] ?? [])
    }

    @Published var selectedNumber = 1
    @Published var style: GridStyle
    @Published var background: GridBackground
    @Published var language: AppLanguage
    @Published var material: CrystalMaterial
    @Published var glassOpacity: Double
    @Published var enableGlass: Bool

    /// Stage 4 (T15) owns the actual Space switch. The overview only reports
    /// the chosen desktop; the default handler logs so stage 3 never switches
    /// anything by accident.
    var onSwitchRequested: ((Desktop) -> Void)?
    var onLayoutChanged: ((String, [Int]) -> Void)?

    private let spaceService: DesktopSpaceServiceProtocol
    private let accessibilityStatus: () -> Bool
    private let screenRecordingStatus: () -> Bool
    private var refreshTimer: Timer?

    init(
        spaceService: DesktopSpaceServiceProtocol = DesktopSpaceService.shared,
        style: GridStyle = .default,
        background: GridBackground = .default,
        language: AppLanguage = .english,
        material: CrystalMaterial = .legacyDefault,
        glassOpacity: Double = 0.30,
        enableGlass: Bool = true,
        layouts: [String: [Int]] = [:],
        accessibilityStatus: @escaping () -> Bool = { AXIsProcessTrusted() },
        screenRecordingStatus: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) {
        self.spaceService = spaceService
        self.style = style
        self.background = background
        self.language = language
        self.material = material
        self.glassOpacity = glassOpacity
        self.enableGlass = enableGlass
        self.layouts = layouts
        self.accessibilityStatus = accessibilityStatus
        self.screenRecordingStatus = screenRecordingStatus
        self.accessibilityGranted = accessibilityStatus()
        self.screenRecordingGranted = screenRecordingStatus()
        self.onSwitchRequested = { desktop in
            AppLogger.info("Desktop grid selection recorded. number=\(desktop.number), switchInterface=stage4_T15")
        }
    }

    // MARK: - Derived state

    var currentNumber: Int? {
        snapshot.currentDesktop?.number
    }

    /// The dashed "target" ring follows keyboard selection for now. Gesture
    /// targets arrive with T13/T16 and will feed the same property.
    var targetNumber: Int? {
        // No readable desktops means no target: a key chip or dashed ring on
        // an unavailable grid would claim a destination that does not exist.
        guard !snapshot.availability.isUnavailable, let currentNumber else { return nil }
        return selectedNumber == currentNumber ? nil : selectedNumber
    }

    var selectedDesktop: Desktop? {
        snapshot.slot(selectedNumber)
    }

    var banners: GridOverviewBanners {
        GridOverviewBanners(
            accessibilityMissing: !accessibilityGranted,
            screenRecordingMissing: !screenRecordingGranted,
            spacesUnavailable: snapshot.availability.isUnavailable,
            notCreatedCount: snapshot.availability.isUnavailable ? 0 : slots.filter { !$0.isCreated }.count
        )
    }

    var windowsShownByOverview: Set<CGWindowID> {
        Set(slots.compactMap(\.desktop).flatMap { $0.windows.prefix(3).map(\.id) })
    }

    // MARK: - Lifecycle

    /// Loads the snapshot and starts the bounded refresh window.
    func activate() async {
        isActive = true
        refreshPermissions()
        if snapshot.desktops.isEmpty {
            isLoading = true
        }
        await reload()
        guard isActive else { return }
        startRefreshTimer()
    }

    func deactivate() {
        isActive = false
        isLoading = false
        endDrag()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// True while the visible-only refresh timer is scheduled. The panel and
    /// the tests use it to prove a hidden overview runs nothing (T22).
    var isRefreshTimerActive: Bool { refreshTimer != nil }

    /// Whether cells may start real captures. False as soon as the panel is
    /// hidden, so an in-flight load is cancelled instead of finishing a
    /// screenshot for an invisible panel (T22).
    var shouldCaptureThumbnails: Bool { isActive && screenRecordingGranted }

    func reload() async {
        let result = await spaceService.loadSnapshot()
        guard isActive else { return }

        snapshot = result
        slots = DesktopGridSlot.makeSlots(from: result, layout: layout)
        refreshPermissions()
        clampSelection()
        thumbnailRevision &+= 1
        isLoading = false

        AppLogger.debug(
            "Desktop grid snapshot. desktops=\(result.desktops.count), current=\(currentNumber.map(String.init) ?? "nil"), selected=\(selectedNumber), availability=\(result.availability)"
        )
    }

    /// Re-reads the two permission axes without touching Spaces.
    func refreshPermissions() {
        accessibilityGranted = accessibilityStatus()
        screenRecordingGranted = screenRecordingStatus()
    }

    /// Applies every settings axis the overview consumes. The panel calls
    /// this on `.settingsDidChange`, so C/B, cream/white, theme material and
    /// language all take effect while the overview is open.
    func applySettings(_ settings: AppSettings) {
        style = settings.gridStyle
        background = settings.gridBackground
        language = settings.language
        material = settings.crystalMaterial
        glassOpacity = settings.backgroundBlurOpacity
        enableGlass = settings.enableBackgroundBlur
        layouts = settings.gridLayouts
        slots = DesktopGridSlot.makeSlots(from: snapshot, layout: layout)
    }

    /// Drag-and-drop: swaps the desktops shown at two grid positions
    /// (0-based) and reports the new layout so it can be persisted.
    func swapPositions(_ a: Int, _ b: Int) {
        endDrag()
        let swapped = DesktopGridLayout.swapped(layout, a, b)
        guard swapped != layout else { return }
        let key = DesktopGridLayout.key(for: snapshot.displayID)
        layouts[key] = swapped
        slots = DesktopGridSlot.makeSlots(from: snapshot, layout: swapped)
        onLayoutChanged?(key, swapped)
        AppLogger.info("Desktop grid layout changed. layout=\(swapped.map(String.init).joined(separator: ","))")
    }

    func beginDrag(_ position: Int) {
        draggingPosition = position
        dropTargetPosition = nil
    }

    func setDropTarget(_ position: Int?) {
        dropTargetPosition = position
    }

    func endDrag() {
        draggingPosition = nil
        dropTargetPosition = nil
    }


    // MARK: - Selection

    func select(_ number: Int) {
        guard (1...9).contains(number) else { return }
        selectedNumber = number
    }

    func moveSelection(_ direction: GridSelectionDirection) {
        let position = position(of: selectedNumber)
        let row = position / 3
        let column = position % 3

        let target: (row: Int, column: Int)
        switch direction {
        case .up: target = (max(0, row - 1), column)
        case .down: target = (min(2, row + 1), column)
        case .left: target = (row, max(0, column - 1))
        case .right: target = (row, min(2, column + 1))
        }
        select(layout[target.row * 3 + target.column])
    }

    private func position(of number: Int) -> Int {
        layout.firstIndex(of: number) ?? 0
    }

    /// Tab / Shift-Tab. The focus path runs 1…9 in visual order and wraps at
    /// the ends, which is what a keyboard user expects from Tab (T21).
    func focusAdjacent(forward: Bool) {
        let current = position(of: selectedNumber)
        let next = forward ? (current + 1) % 9 : (current + 8) % 9
        select(layout[next])
    }

    /// Selects the desktop and asks for the switch. A not-created slot is
    /// selected (so its guidance stays readable) but never triggers a switch.
    func selectAndActivate(_ number: Int) {
        select(number)
        activateSelection()
    }

    func activateSelection() {
        guard let desktop = selectedDesktop else {
            AppLogger.info("Desktop grid activation ignored. number=\(selectedNumber), reason=not_created")
            return
        }
        onSwitchRequested?(desktop)
    }

    func selectCurrentDesktop() {
        if let currentNumber {
            select(currentNumber)
        }
    }

    // MARK: - Private

    private func clampSelection() {
        guard (1...9).contains(selectedNumber) else {
            selectedNumber = 1
            return
        }
        if snapshot.desktops.isEmpty {
            selectedNumber = 1
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive else { return }
                await self.reload()
            }
        }
        timer.tolerance = 1
        refreshTimer = timer
    }
}
