//
//  GridPrerequisiteViewModel.swift
//  Switchly
//
//  One observable prerequisite state shared by the settings tab and the
//  onboarding window (T17, T18, T20).
//
//  Both surfaces instantiate this view model over the same
//  `GridPrerequisiteService`, so the count, the labels and the "can't check"
//  wording can never disagree. It reads only; nothing here writes a system
//  preference.
//

import Foundation
import AppKit
import Combine

@MainActor
final class GridPrerequisiteViewModel: ObservableObject {
    @Published private(set) var snapshot: GridPrerequisiteSnapshot = .empty
    @Published private(set) var spaceCount = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var language: AppLanguage

    private let service: GridPrerequisiteServiceProtocol
    private let spaceService: DesktopSpaceServiceProtocol
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?

    init(
        service: GridPrerequisiteServiceProtocol = GridPrerequisiteService(),
        spaceService: DesktopSpaceServiceProtocol = DesktopSpaceService.shared,
        language: AppLanguage = SettingsService.shared.loadSettings().language
    ) {
        self.service = service
        self.spaceService = spaceService
        self.language = language
    }

    /// Live NotificationCenter registrations. Exposed so a test can prove
    /// repeated open/close never stacks them.
    var observerCount: Int { observers.count }

    // MARK: - Lifecycle

    /// Starts reacting to app activation. Calling it twice is a no-op, so a
    /// window that is shown again cannot register a second observer.
    func startObserving() {
        guard observers.isEmpty else { return }
        let token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        observers.append(token)
    }

    /// Removes every registration. Safe to call when nothing is registered.
    func stopObserving() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers.removeAll()
        refreshTask?.cancel()
        refreshTask = nil
    }

    func applySettings(_ settings: AppSettings) {
        language = settings.language
    }

    // MARK: - Refresh

    /// Re-reads the desktop count and every prerequisite. The desktop read is
    /// async and off the main thread; the snapshot itself is cheap.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let result = await spaceService.loadSnapshot()
        guard !Task.isCancelled else {
            isRefreshing = false
            return
        }
        spaceCount = max(result.desktops.count, result.maxDisplayDesktopCount)
        snapshot = service.snapshot(spaceCount: spaceCount)
        isRefreshing = false
        AppLogger.debug(
            "Grid prerequisites refreshed. met=\(snapshot.metCount)/\(snapshot.totalCount), desktops=\(spaceCount)"
        )
    }

    /// Fire-and-forget refresh used by the Re-check button.
    ///
    /// Opening the window fires several refreshes at once (show, onAppear,
    /// app activation). Cancelling the in-flight one would leave the snapshot
    /// empty, because `refresh()` skips while busy and a cancelled run drops
    /// its result; so an in-flight refresh is left to finish.
    func refreshSoon() {
        guard !isRefreshing else { return }
        refreshTask = Task { @MainActor [weak self] in
            await self?.refresh()
        }
    }

    // MARK: - Actions

    /// Opens the System Settings pane (or Mission Control) for one item.
    /// Read-only: the app never changes the setting itself.
    func openSettings(for prerequisite: GridPrerequisite) {
        if prerequisite.opensMissionControl {
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    AppLogger.warning("Could not open Mission Control. error=\(error.localizedDescription)")
                }
            }
            return
        }
        guard let url = prerequisite.settingsURL else { return }
        AppLogger.info("Opening system settings for grid prerequisite. item=\(prerequisite.rawValue)")
        NSWorkspace.shared.open(url)
    }
}
