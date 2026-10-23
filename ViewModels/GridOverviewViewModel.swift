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
        slots = DesktopGridSlot.makeSlots(from: result)
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
    }

    // MARK: - Selection

    func select(_ number: Int) {
        guard (1...9).contains(number) else { return }
        selectedNumber = number
    }

    func moveSelection(_ direction: GridSelectionDirection) {
        let row = (selectedNumber - 1) / 3
        let column = (selectedNumber - 1) % 3

        let target: (row: Int, column: Int)
        switch direction {
        case .up: target = (max(0, row - 1), column)
        case .down: target = (min(2, row + 1), column)
        case .left: target = (row, max(0, column - 1))
        case .right: target = (row, min(2, column + 1))
        }
        select(target.row * 3 + target.column + 1)
    }

    /// Tab / Shift-Tab. The focus path runs 1…9 in visual order and wraps at
    /// the ends, which is what a keyboard user expects from Tab (T21).
    func focusAdjacent(forward: Bool) {
        let next = forward
            ? (selectedNumber % 9) + 1
            : ((selectedNumber - 2 + 9) % 9) + 1
        select(next)
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
