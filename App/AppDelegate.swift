//
//  AppDelegate.swift
//  Switchly
//
//  Application delegate handling setup and lifecycle
//

import Cocoa
import SwiftUI
import ServiceManagement
import Combine
import CoreGraphics

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var preferencesWindow: NSWindow?
    private var workspacesWindow: NSWindow?
    private var statisticsWindow: NSWindow?
    private var statisticsKeyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.configure()
        AppLogger.info("Application did finish launching. pid=\(ProcessInfo.processInfo.processIdentifier), bundleID=\(Bundle.main.bundleIdentifier ?? "nil"), appPath=\(Bundle.main.bundlePath)")
        setupApplication()
        setupServices()
        setupStatusBar()
        setupObservers()
        promptRequiredPermissionsIfNeeded()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.info("Application will terminate")
        DockHoverMonitor.shared.stop()
        PreviewTriggerMonitor.shared.stop()
        WindowMonitorService.shared.stopMonitoring()
        ThumbnailService.shared.stopAutoRefresh()
        // The only synchronous wait in the statistics pipeline, and the only
        // place it is acceptable: quitting. Bounded so a slow disk cannot hang
        // the app on the way out.
        UsageStatisticsService.shared.flushSync(timeout: 0.5)
    }
    
    private func setupApplication() {
        let lsUIElement = Bundle.main.object(forInfoDictionaryKey: "LSUIElement") ?? "nil"
        AppLogger.info("Configuring activation policy. previous=\(NSApp.activationPolicy().rawValue), LSUIElement=\(lsUIElement)")
        NSApp.setActivationPolicy(.accessory)
        AppLogger.info("Activation policy configured. current=\(NSApp.activationPolicy().rawValue)")
    }
    
    private func setupServices() {
        AppLogger.info("Setting up services")
        let settings = SettingsService.shared.loadSettings()
        ThemeApplier.apply(settings.theme)
        AppLogger.debug("Loaded startup settings. launchAtLogin=\(settings.launchAtLogin), hideMainWindowOnLaunch=\(settings.hideMainWindowOnLaunch), monitoredApps=\(settings.monitoredApps.count), globalShortcutKey=\(settings.globalShortcutKey ?? "nil"), monitorFrequency=\(settings.monitorFrequency.rawValue)")
        WindowMonitorService.shared.startMonitoring()
        ShortcutService.shared.setupGlobalShortcuts()
        // Usage statistics: the flag is read on every record, so keep it in a
        // plain property; the file loads on the io queue while the app starts.
        UsageStatisticsService.shared.isEnabled = settings.usageStatisticsEnabled
        Task { await UsageStatisticsService.shared.awaitReady() }
        // Keep thumbnails fresh: the auto-refresh timer re-captures cached
        // windows on an 8s cadence so previews always reflect current window
        // content. Cheap when no panel is open (the tick no-ops on an empty
        // cache), and stopped on terminate.
        ThumbnailService.shared.startAutoRefresh()
        
        if #available(macOS 13.0, *) {
            do {
                if settings.launchAtLogin {
                    AppLogger.debug("Registering launch at login")
                    try SMAppService.mainApp.register()
                } else {
                    AppLogger.debug("Unregistering launch at login")
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                AppLogger.error("Failed to update login item status: \(error)")
            }
        } else {
            // macOS 12 and earlier: SMAppService is unavailable.
            // Inform the user to add the app manually via System Settings → Users & Groups → Login Items.
            if settings.launchAtLogin {
                AppLogger.info("Launch at login requested on macOS <13; cannot register via SMAppService")
            }
        }
        
        let isPermissionGranted = AccessibilityService.shared.isPermissionGranted
        AppLogger.info("Accessibility permission status. granted=\(isPermissionGranted)")
        let canCaptureScreen = CGPreflightScreenCaptureAccess()
        AppLogger.info("Screen capture permission status. granted=\(canCaptureScreen)")

        DockHoverMonitor.shared.updateSettings()
        PreviewTriggerMonitor.shared.updateSettings()
        AppLogger.info("Dock preview initialized")
    }
    
    private func setupStatusBar() {
        AppLogger.info("Setting up status bar controller")
        _ = StatusBarController.shared
    }

    private func setupObservers() {
        AppLogger.debug("Setting up app-level observers")
        NotificationCenter.default.publisher(for: .openPreferences)
            .sink { [weak self] _ in
                AppLogger.info("Received openPreferences notification")
                self?.openPreferences()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .togglePreview)
            .sink { _ in
                AppLogger.info("Received togglePreview notification")
                // Dead path since the global shortcut moved to its own
                // notification; kept in sync so it cannot silently start
                // counting as "unknown".
                PreviewPanel.shared.toggleVisibility(source: .unknown)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .globalShortcutTriggered)
            .sink { _ in
                AppLogger.info("Received globalShortcutTriggered notification")
                // The shortcut is a toggle: the panel counts itself only when
                // this actually puts it on screen.
                PreviewPanel.shared.toggleVisibility(source: .globalShortcut)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .currentAppWindowShortcutTriggered)
            .sink { [weak self] notification in
                guard let offset = notification.object as? Int else {
                    AppLogger.warning("Received currentAppWindowShortcutTriggered notification without offset payload")
                    return
                }
                self?.switchCurrentAppWindow(offset: offset)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .workspaceShortcutTriggered)
            .sink { notification in
                guard let workspaceID = notification.object as? UUID else {
                    AppLogger.warning("Received workspaceShortcutTriggered notification without workspace id payload")
                    return
                }
                WorkspaceBarPanel.shared.show(workspaceID: workspaceID, source: .workspaceShortcut)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openWorkspaces)
            .sink { [weak self] _ in
                AppLogger.info("Received openWorkspaces notification")
                self?.openWorkspaces()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openStatistics)
            .sink { [weak self] _ in
                AppLogger.info("Received openStatistics notification")
                self?.openStatistics()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .appShortcutTriggered)
            .sink { notification in
                guard let apps = notification.object as? [MonitoredApp] else {
                    AppLogger.warning("Received appShortcutTriggered notification without MonitoredApp array payload")
                    return
                }
                AppLogger.info("Received appShortcutTriggered notification. apps=\(apps.map { $0.appName }.joined(separator: ","))")

                // Single-window auto-switch: if exactly one monitored app with autoSwitchIfSingle enabled
                // has exactly one window, switch directly instead of showing the preview panel.
                if apps.count == 1 {
                    let app = apps[0]
                    if app.autoSwitchIfSingle {
                        let appWindows = WindowMonitorService.shared.getWindows(for: app)
                        let visibleWindowCount = WindowMonitorService.shared.getVisibleWindowCount(for: app.bundleIdentifier)
                        if appWindows.count == 1 && visibleWindowCount == 1 {
                            AppLogger.info("Auto-switching single window. app=\(app.appName)")
                            Task {
                                do {
                                    try await WindowSwitchService.shared.switchToWindow(appWindows[0])
                                    // No panel is shown for this switch; the
                                    // status bar pulse is the only feedback.
                                    UsageStatisticsService.shared.record(.quickSwitch,
                                                                        source: QuickSwitchAttribution.source(for: .singleWindowAutoSwitch),
                                                                        at: Date())
                                    NotificationCenter.default.post(name: .switchDidComplete, object: nil)
                                } catch {
                                    AppLogger.error("Auto-switch single window failed. app=\(app.appName), error=\(error)")
                                }
                            }
                            return
                        } else {
                            AppLogger.info("Showing preview instead of auto-switch. app=\(app.appName), previewWindowCount=\(appWindows.count), visibleWindowCount=\(visibleWindowCount)")
                        }
                    }
                }

                PreviewPanel.shared.showWindows(for: apps, source: .appShortcut)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .settingsDidChange)
            .sink { _ in
                DockHoverMonitor.shared.updateSettings()
                PreviewTriggerMonitor.shared.updateSettings()
                let latest = SettingsService.shared.loadSettings()
                UsageStatisticsService.shared.isEnabled = latest.usageStatisticsEnabled
                if !latest.usageStatisticsEnabled {
                    // Switching off stops recording; whatever was already
                    // recorded is flushed (and deliberately NOT deleted).
                    Task { await UsageStatisticsService.shared.flush() }
                }
            }
            .store(in: &cancellables)

        setupStatisticsKeyHandling()
    }

    /// ESC closes the statistics window. A local monitor (not SwiftUI
    /// `onExitCommand`, which is unreliable without a focused control) scoped
    /// to the statistics window only; while the clear-confirmation sheet is
    /// up, ESC belongs to the sheet, not the window.
    private func setupStatisticsKeyHandling() {
        statisticsKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.statisticsWindow,
                  window.isVisible,
                  event.window === window,
                  event.keyCode == 53, // ESC
                  window.attachedSheet == nil else {
                return event
            }
            window.performClose(nil)
            return nil
        }
    }

    private func switchCurrentAppWindow(offset: Int) {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              let bundleID = frontmostApp.bundleIdentifier else {
            AppLogger.warning("Cannot switch current app window because frontmost app is unavailable")
            return
        }

        if bundleID == Bundle.main.bundleIdentifier {
            AppLogger.info("Ignoring current app window shortcut while Switchly is frontmost")
            return
        }

        let windows = WindowMonitorService.shared.getWindows(for: bundleID)
        guard windows.count > 1 else {
            AppLogger.info("Current app has no other switchable windows. bundleID=\(bundleID), count=\(windows.count)")
            return
        }

        let focusedWindowID = AccessibilityService.shared.focusedWindowID(for: frontmostApp.processIdentifier)
        let currentIndex = focusedWindowID.flatMap { id in
            windows.firstIndex { $0.id == id }
        } ?? 0
        let targetIndex = (currentIndex + offset + windows.count) % windows.count
        let targetWindow = windows[targetIndex]
        AppLogger.info("Switching current app window. bundleID=\(bundleID), offset=\(offset), focusedWindowID=\(focusedWindowID.map { "\($0)" } ?? "nil"), currentIndex=\(currentIndex), targetIndex=\(targetIndex), windowID=\(targetWindow.id)")

        Task {
            do {
                try await WindowSwitchService.shared.switchToWindow(targetWindow)
                UsageStatisticsService.shared.record(.quickSwitch,
                                                    source: QuickSwitchAttribution.source(for: .currentAppWindowRotation),
                                                    at: Date())
                NotificationCenter.default.post(name: .switchDidComplete, object: nil)
            } catch {
                AppLogger.error("Current app window shortcut failed. bundleID=\(bundleID), windowID=\(targetWindow.id), error=\(error)")
            }
        }
    }
    
    private func promptRequiredPermissionsIfNeeded() {
        let accessibilityGranted = AccessibilityService.shared.checkPermissionStatus()
        let screenCaptureGranted = CGPreflightScreenCaptureAccess()

        guard !accessibilityGranted || !screenCaptureGranted else {
            AppLogger.info("Required permissions are already granted")
            return
        }

        if OnboardingWindow.shouldShow() {
            AppLogger.info("Showing onboarding window for first launch. accessibility=\(accessibilityGranted), screenCapture=\(screenCaptureGranted)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                OnboardingWindow.show()
            }
        } else {
            AppLogger.warning("Required permissions are missing; opening permissions preferences. accessibility=\(accessibilityGranted), screenCapture=\(screenCaptureGranted)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openPreferences(selectedTab: .permissions)
            }
        }
    }

    private func openPreferences(selectedTab: PreferencesTab = .general) {
        AppLogger.info("Opening preferences. existingWindow=\(preferencesWindow != nil)")
        if let window = preferencesWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            AppLogger.debug("Focused existing preferences window. isVisible=\(window.isVisible), isKeyWindow=\(window.isKeyWindow)")
            return
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 450),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = SettingsService.shared.loadSettings().language.localizedString("Switchly Preferences")
        window.setFrameAutosaveName("PreferencesWindow")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: PreferencesView(initialTab: selectedTab))
        window.isReleasedWhenClosed = false
        
        window.delegate = self
        preferencesWindow = window

        Motion.fadeInWindow(window)
        NSApp.activate(ignoringOtherApps: true)
        AppLogger.info("Created preferences window. frame=\(window.frame), isVisible=\(window.isVisible), activationPolicy=\(NSApp.activationPolicy().rawValue)")
    }

    private func openWorkspaces() {
        AppLogger.info("Opening workspaces. existingWindow=\(workspacesWindow != nil)")
        if let window = workspacesWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = SettingsService.shared.loadSettings().language.localizedString("Workspaces")
        window.setFrameAutosaveName("WorkspacesWindow")
        // Match the Preferences window: hide the native title bar so the
        // Liquid Glass background drawn by WorkspacesView extends across the
        // whole window, including the title-bar strip.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: WorkspacesView())
        window.isReleasedWhenClosed = false
        window.delegate = self
        workspacesWindow = window

        Motion.fadeInWindow(window)
        NSApp.activate(ignoringOtherApps: true)
        AppLogger.info("Created workspaces window. frame=\(window.frame)")
    }

    private func openStatistics() {
        AppLogger.info("Opening statistics. existingWindow=\(statisticsWindow != nil)")
        if let window = statisticsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // The panel renders from the in-memory snapshot, so opening it never
        // waits for a disk write (see the plan's section 5.4 C).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 810),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = SettingsService.shared.loadSettings().language.localizedString("Statistics")
        window.setFrameAutosaveName("StatisticsWindow")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.contentView = NSHostingView(rootView: StatisticsView())
        window.isReleasedWhenClosed = false
        window.delegate = self
        statisticsWindow = window

        Motion.fadeInWindow(window)
        NSApp.activate(ignoringOtherApps: true)
        AppLogger.info("Created statistics window. frame=\(window.frame)")
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == preferencesWindow {
            AppLogger.info("Preferences window will close")
            preferencesWindow = nil
        }
        if let window = notification.object as? NSWindow, window == workspacesWindow {
            AppLogger.info("Workspaces window will close")
            workspacesWindow = nil
        }
        if let window = notification.object as? NSWindow, window == statisticsWindow {
            AppLogger.info("Statistics window will close")
            statisticsWindow = nil
        }
    }
}
