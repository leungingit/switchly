//
//  StatusBarView.swift
//  Switchly
//
//  Status bar item with menu
//

import SwiftUI
import AppKit
import Combine
import QuartzCore

class StatusBarController {
    static let shared = StatusBarController()
    
    private var statusItem: NSStatusItem?
    private var popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var statusIconRestoreWorkItem: DispatchWorkItem?
    
    private init() {
        AppLogger.info("Initializing StatusBarController")
        setupStatusItem()
        setupPopover()
        setupObservers()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        AppLogger.debug("Created status item. hasButton=\(statusItem?.button != nil)")
        
        if let button = statusItem?.button {
            configureStatusButton(button)
            button.action = #selector(togglePopover(_:))
            button.target = self
            AppLogger.debug("Configured status item button. hasImage=\(button.image != nil), action=\(String(describing: button.action)), target=\(String(describing: button.target))")
        } else {
            AppLogger.error("Status item button is nil")
        }
        
        setupMenu()
    }

    private func configureStatusButton(_ button: NSStatusBarButton) {
        let configuration = NSImage.SymbolConfiguration(hierarchicalColor: .white)
        let image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Switchly")?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        button.image = image
        button.contentTintColor = .white
    }
    
    private func setupMenu() {
        let settings = SettingsService.shared.loadSettings()
        let menu = NSMenu()
        
        let openPreviewItem = NSMenuItem(title: settings.language.localizedString("Open Preview"), action: #selector(openPreview), keyEquivalent: "")
        openPreviewItem.target = self
        menu.addItem(openPreviewItem)

        let desktopGridItem = NSMenuItem(title: settings.language.localizedString("Desktop Grid"), action: #selector(openDesktopGrid), keyEquivalent: "")
        desktopGridItem.target = self
        // R10: the master switch is the only gate. The entry stays visible so
        // the feature is discoverable, but it cannot open the overview while
        // the grid is off (Preferences → Desktop Grid turns it on).
        desktopGridItem.isEnabled = settings.gridEnabled
        menu.addItem(desktopGridItem)

        menu.addItem(NSMenuItem.separator())
        let preferencesItem = NSMenuItem(title: settings.language.localizedString("Preferences..."), action: #selector(openPreferences), keyEquivalent: "")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        let workspacesItem = NSMenuItem(title: settings.language.localizedString("Workspaces..."), action: #selector(openWorkspaces), keyEquivalent: "")
        workspacesItem.target = self
        menu.addItem(workspacesItem)

        let statisticsItem = NSMenuItem(title: settings.language.localizedString("Statistics..."), action: #selector(openStatistics), keyEquivalent: "")
        statisticsItem.target = self
        menu.addItem(statisticsItem)
        
        let aboutItem = NSMenuItem(title: settings.language.localizedString("About Switchly"), action: #selector(openAboutWindow), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: settings.language.localizedString("Quit Switchly"), action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
        AppLogger.info("Configured status menu. itemCount=\(menu.items.count), openPreviewEnabled=\(openPreviewItem.isEnabled), preferencesEnabled=\(preferencesItem.isEnabled), aboutEnabled=\(aboutItem.isEnabled), quitEnabled=\(quitItem.isEnabled)")
    }
    
    private func setupPopover() {
        popover.contentSize = NSSize(width: 300, height: 200)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: StatusBarPopoverView())
        AppLogger.debug("Configured status popover. contentSize=\(popover.contentSize)")
    }

    private func setupObservers() {
        NotificationCenter.default.publisher(for: .settingsDidChange)
            .sink { [weak self] _ in
                AppLogger.info("Status bar settings changed; rebuilding menu")
                if let button = self?.statusItem?.button {
                    self?.configureStatusButton(button)
                }
                self?.setupMenu()
            }
            .store(in: &cancellables)

        // A window switch completed without any panel on screen (single-window
        // auto-switch, current-app window shortcut). LSUIElement apps have no
        // Dock icon, so a pulse on the status item is the only confirmation
        // the user gets that the switch happened.
        NotificationCenter.default.publisher(for: .switchDidComplete)
            .sink { [weak self] _ in
                self?.pulseStatusItem()
            }
            .store(in: &cancellables)
    }

    /// Briefly swaps the status icon to a checkmark and scales the button up
    /// and back — a two-beat confirmation that a background switch landed.
    /// Skipped entirely under Reduce Motion.
    private func pulseStatusItem() {
        guard let button = statusItem?.button, !MotionTokens.reduceMotion else {
            return
        }

        // Template image: the status item re-tints it for the menu bar's
        // current appearance. A fixed white hierarchical color was nearly
        // invisible on a light menu bar.
        let checkmark = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        checkmark?.isTemplate = true
        button.image = checkmark

        button.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 1.0
        pulse.toValue = 1.3
        pulse.duration = MotionTokens.microDuration
        pulse.autoreverses = true
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        button.layer?.add(pulse, forKey: "switchlyAutoSwitchPulse")

        statusIconRestoreWorkItem?.cancel()
        let restore = DispatchWorkItem { [weak self] in
            guard let self, let button = self.statusItem?.button else {
                return
            }
            self.configureStatusButton(button)
        }
        statusIconRestoreWorkItem = restore
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: restore)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        AppLogger.info("Toggling status popover. isShown=\(popover.isShown)")
        if popover.isShown {
            popover.performClose(sender)
        } else {
            if let button = statusItem?.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                AppLogger.debug("Status popover shown")
            } else {
                AppLogger.error("Cannot show status popover because status item button is nil")
            }
        }
    }
    
    @objc private func openPreview() {
        AppLogger.info("Status menu selected: Open Preview")
        PreviewPanel.shared.show()
    }

    @objc private func openDesktopGrid() {
        AppLogger.info("Status menu selected: Desktop Grid")
        Task { @MainActor in
            // The menu item is disabled while the grid is off; the panel's own
            // `show()` re-checks the switch so a stale menu cannot bypass it.
            GridOverviewPanel.shared.toggle()
        }
    }
    
    @objc private func openPreferences() {
        AppLogger.info("Status menu selected: Preferences")
        NotificationCenter.default.post(name: .openPreferences, object: nil)
    }

    @objc private func openWorkspaces() {
        AppLogger.info("Status menu selected: Workspaces")
        NotificationCenter.default.post(name: .openWorkspaces, object: nil)
    }

    @objc private func openStatistics() {
        AppLogger.info("Status menu selected: Statistics")
        NotificationCenter.default.post(name: .openStatistics, object: nil)
    }
    
    @objc private func openAboutWindow() {
        AppLogger.info("Status menu selected: About")
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }
    
    @objc private func quitApp() {
        AppLogger.info("Status menu selected: Quit")
        NSApplication.shared.terminate(nil)
    }
}

struct StatusBarPopoverView: View {
    @StateObject private var viewModel = StatusBarViewModel()
    @State private var settings = SettingsService.shared.loadSettings()
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Switchly")
                .font(.headline)
            
            Button(action: {
                AppLogger.info("Status popover selected: Open Preview")
                PreviewPanel.shared.show()
            }) {
                Label(t("Open Preview"), systemImage: "square.on.square")
            }
            
            Button(action: {
                AppLogger.info("Status popover selected: Preferences")
                NotificationCenter.default.post(name: .openPreferences, object: nil)
            }) {
                Label(t("Preferences..."), systemImage: "gear")
            }

            Button(action: {
                AppLogger.info("Status popover selected: Workspaces")
                NotificationCenter.default.post(name: .openWorkspaces, object: nil)
            }) {
                Label(t("Workspaces..."), systemImage: "square.grid.2x2")
            }

            Button(action: {
                AppLogger.info("Status popover selected: Statistics")
                NotificationCenter.default.post(name: .openStatistics, object: nil)
            }) {
                Label(t("Statistics..."), systemImage: "chart.xyaxis.line")
            }
            
            Divider()
            
            Button(action: {
                viewModel.quitApp()
            }) {
                Label(t("Quit"), systemImage: "power")
            }
        }
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: .settingsDidChange)) { _ in
            settings = SettingsService.shared.loadSettings()
            ThemeApplier.apply(settings.theme)
        }
    }

    private func t(_ key: String) -> String {
        settings.language.localizedString(key)
    }
}

struct StatusBarView: View {
    var body: some View {
        EmptyView()
    }
}

extension Notification.Name {
    static let openPreferences = Notification.Name("com.switchly.openPreferences")
    static let openWorkspaces = Notification.Name("com.switchly.openWorkspaces")
    static let openStatistics = Notification.Name("com.switchly.openStatistics")
}
