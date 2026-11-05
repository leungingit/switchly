//
//  WindowMonitorService.swift
//  Switchly
//
//  Service for monitoring and retrieving system windows
//

import Foundation
import CoreGraphics
import AppKit

protocol WindowMonitorServiceProtocol {
    func startMonitoring()
    func stopMonitoring()
    func getAllWindows() -> [WindowInfo]
    var isEnumeratingWindows: Bool { get }
    var isWindowDiscoveryLimited: Bool { get }
    /// On-screen windows only — the fast path without the per-app
    /// Accessibility enumeration (see the concrete `getOnScreenWindows`).
    func getOnScreenWindows() -> [WindowInfo]
    func getWindows(for bundleIdentifier: String) -> [WindowInfo]
    func getWindows(for bundleIdentifier: String, appName: String) -> [WindowInfo]
    func getWindows(for app: MonitoredApp) -> [WindowInfo]
    func windows(ownedBy bundleURL: URL) -> [WindowInfo]
    func getVisibleWindowCount(for bundleIdentifier: String) -> Int
    func filterWindows(_ windows: [WindowInfo], by strategy: PreviewStrategy) -> [WindowInfo]
    func filterWindows(_ windows: [WindowInfo], by searchText: String) -> [WindowInfo]
    func filterWindows(_ windows: [WindowInfo], for bundleIdentifier: String, appName: String?) -> [WindowInfo]
}

extension WindowMonitorServiceProtocol {
    var isEnumeratingWindows: Bool { false }
    var isWindowDiscoveryLimited: Bool { false }
    /// 在同一份窗口快照中匹配应用，避免每个应用都重新枚举系统窗口。
    func filterWindows(_ windows: [WindowInfo], for bundleIdentifier: String, appName: String?) -> [WindowInfo] {
        let normalizedName = appName?.lowercased()
        let applications = Dictionary(uniqueKeysWithValues: Set(windows.map(\.ownerPID)).map { pid in
            let app = NSRunningApplication(processIdentifier: pid)
            return (pid, (bundleID: app?.bundleIdentifier, name: app?.localizedName?.lowercased()))
        })
        return windows.filter { window in
            guard let app = applications[window.ownerPID], app.bundleID == bundleIdentifier else {
                return false
            }
            guard let normalizedName, !normalizedName.isEmpty else { return true }
            return app.name == normalizedName || window.ownerName.lowercased() == normalizedName
        }
    }
}

class WindowMonitorService: WindowMonitorServiceProtocol {
    private let settingsService: SettingsServiceProtocol
    private let thumbnailService: ThumbnailServiceProtocol
    private var activeBundleIdentifier: String?
    private let maxPreheatWindowsPerTick = 8
    private var monitorTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Interval the running timer was built with, so a settings change can be
    /// compared against it (see `restartMonitoringIfFrequencyChanged`).
    private var monitorInterval: TimeInterval = 0

    private let enumerationQueue = DispatchQueue(label: "com.switchly.windowEnumeration", qos: .userInitiated)
    private var accessibilityWindowsCache: (date: Date, windows: [WindowInfo])?
    private(set) var isEnumeratingWindows = false
    var isWindowDiscoveryLimited: Bool { !AXIsProcessTrusted() }
    private var enumerationProgress: Progress?
    private var enumerationRevision = 0

    static let shared = WindowMonitorService()
    
    init(
        settingsService: SettingsServiceProtocol = SettingsService.shared,
        thumbnailService: ThumbnailServiceProtocol = ThumbnailService.shared
    ) {
        self.settingsService = settingsService
        self.thumbnailService = thumbnailService
        AppLogger.debug("WindowMonitorService initialized")
    }
    
    func startMonitoring() {
        guard monitorTimer == nil else { return }
        let settings = settingsService.loadSettings()
        monitorInterval = settings.monitorFrequency.interval
        AppLogger.info("Starting window monitoring. interval=\(settings.monitorFrequency.interval), frequency=\(settings.monitorFrequency.rawValue)")
        setupWorkspaceObservers()
        activeBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        processWindowChanges(reason: "startup")
        monitorTimer = Timer.scheduledTimer(withTimeInterval: settings.monitorFrequency.interval, repeats: true) { [weak self] _ in
            self?.processWindowChanges(reason: "timer")
        }
    }

    /// Re-applies the monitor cadence after a settings change. The timer used
    /// to be built once at launch and keep the launch-time interval forever,
    /// so changing the monitoring frequency did nothing until the app was
    /// relaunched. Only the cadence is rebuilt — everything else about
    /// monitoring is idempotent, but an unnecessary restart would re-run the
    /// full window pass for no reason.
    func restartMonitoringIfFrequencyChanged() {
        let interval = settingsService.loadSettings().monitorFrequency.interval
        guard interval != monitorInterval else {
            return
        }
        AppLogger.info("Monitor frequency changed. oldInterval=\(monitorInterval), newInterval=\(interval)")
        stopMonitoring()
        startMonitoring()
    }
    
    func stopMonitoring() {
        enumerationProgress?.cancel()
        enumerationProgress = nil
        isEnumeratingWindows = false
        accessibilityWindowsCache = nil
        enumerationRevision += 1
        monitorTimer?.invalidate()
        monitorTimer = nil
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        AppLogger.info("Stopped window monitoring")
    }
    
    func getAllWindows() -> [WindowInfo] {
        var windows = getOnScreenWindows()

        let accessibilityWindows = getAccessibilityWindowsCached(excluding: Set(windows.map(\.id)))
        windows.append(contentsOf: accessibilityWindows)

        windows = removeOverlayTwins(from: windows)

        AppLogger.verbose("Loaded all windows. rawCount=\(windows.count), accessibilityCount=\(accessibilityWindows.count)")
        return windows.filter { $0.isOnCurrentSpace } + windows.filter { !$0.isOnCurrentSpace }
    }

    /// Fast path used by the monitor hot-loop. Returns only on-screen windows
    /// without the expensive per-app Accessibility enumeration, so the main
    /// thread stays responsive when the user switches focus between apps.
    func getOnScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            AppLogger.error("CGWindowListCopyWindowInfo returned nil while getting all windows")
            return []
        }
        
        var windows: [WindowInfo] = []
        for windowDict in windowList {
            guard let windowID = windowDict[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = windowDict[kCGWindowOwnerPID as String] as? pid_t,
                  let ownerName = windowDict[kCGWindowOwnerName as String] as? String,
                  let boundsDict = windowDict[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            let bounds = extractCGRect(from: boundsDict)
            let layer = windowDict[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0, bounds.width >= 80, bounds.height >= 60 else {
                continue
            }

            let windowTitle = windowDict[kCGWindowName as String] as? String ?? ""
            let isOnCurrentSpace = true
            
            let windowInfo = WindowInfo(
                id: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                windowTitle: windowTitle,
                bounds: bounds,
                isOnCurrentSpace: isOnCurrentSpace,
                windowNumber: Int(windowID)
            )
            
            windows.append(windowInfo)
        }

        return windows
    }

    private func getAccessibilityWindowsCached(excluding existingWindowIDs: Set<CGWindowID>) -> [WindowInfo] {
        // AX 逐应用枚举可能超时，放到专用串行队列；不以全局时间预算静默漏掉后面的应用。
        guard !isWindowDiscoveryLimited else { return [] }
        if !isEnumeratingWindows,
           accessibilityWindowsCache.map({ Date().timeIntervalSince($0.date) >= 2 }) ?? true {
            isEnumeratingWindows = true
            let progress = Progress(totalUnitCount: 1)
            enumerationProgress = progress
            let revision = enumerationRevision
            enumerationQueue.async { [weak self] in
                guard let self, !progress.isCancelled else { return }
                let windows = self.getAccessibilityWindows(excluding: [], progress: progress)
                DispatchQueue.main.async {
                    guard !progress.isCancelled else { return }
                    if revision == self.enumerationRevision {
                        self.accessibilityWindowsCache = (Date(), windows)
                    }
                    self.isEnumeratingWindows = false
                    self.enumerationProgress = nil
                    self.refreshWindowList()
                }
            }
        }
        let cgWindows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let existingIDs = Set(cgWindows.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        // The cache can be up to 2 s old, and a desktop switch inside that window
        // moves its windows off screen while the cached flags still say "current
        // desktop". Re-read membership now so a window that just left is not
        // presented as being on the current desktop (it would then be raised
        // without switching desktops and fail verification).
        let spaces = WindowSpaceSnapshot()
        return (accessibilityWindowsCache?.windows ?? []).filter {
            !existingWindowIDs.contains($0.id) && (existingIDs.contains($0.id) || $0.isMinimized || $0.id & 0x8000_0000 != 0)
        }.map { window in
            guard let membership = spaces.isOnCurrentSpace(window.id) else { return window }
            return WindowInfo(
                id: window.id, ownerPID: window.ownerPID, ownerName: window.ownerName,
                windowTitle: window.windowTitle, bounds: window.bounds,
                isOnCurrentSpace: membership, windowNumber: window.windowNumber,
                isMinimized: window.isMinimized, isHidden: window.isHidden,
                isOnOtherSpace: !membership
            )
        }
    }

    private func getAccessibilityWindows(excluding existingWindowIDs: Set<CGWindowID>, progress: Progress) -> [WindowInfo] {
        guard AXIsProcessTrusted() else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [WindowInfo] = []
        var seen = existingWindowIDs
        let spaces = WindowSpaceSnapshot()

        for app in NSWorkspace.shared.runningApplications {
            guard !progress.isCancelled else { return [] }
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ownPID,
                  let ownerName = app.localizedName else {
                continue
            }

            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.3)
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsValue
            ) == .success,
                  let axWindows = windowsValue as? [AXUIElement] else {
                continue
            }

            for axWindow in axWindows {
                guard !progress.isCancelled else { return [] }
                AXUIElementSetMessagingTimeout(axWindow, 0.3)
                if let info = accessibilityWindowInfo(
                    for: axWindow,
                    ownerPID: app.processIdentifier,
                    ownerName: ownerName,
                    excluding: seen,
                    isHidden: app.isHidden,
                    spaces: spaces
                ) {
                    result.append(info)
                    seen.insert(info.id)
                }
            }
        }

        // CG 全量列表只能补充有明确其他桌面归属的用户窗口，避免把离屏辅助面和残留 surface 当窗口。
        let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in all {
            guard !progress.isCancelled else { return [] }
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID, !seen.contains(id),
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  spaces.isOnCurrentSpace(id) == false else { continue }
            let bounds = extractCGRect(from: boundsDict)
            guard bounds.width >= 80, bounds.height >= 60 else { continue }
            result.append(WindowInfo(id: id, ownerPID: pid, ownerName: app.localizedName ?? "",
                                     windowTitle: entry[kCGWindowName as String] as? String ?? "",
                                     bounds: bounds, isOnCurrentSpace: false, windowNumber: Int(id),
                                     isHidden: app.isHidden, isOnOtherSpace: true))
            seen.insert(id)
        }
        return result
    }

    private func accessibilityWindowInfo(
        for axWindow: AXUIElement,
        ownerPID: pid_t,
        ownerName: String,
        excluding existingWindowIDs: Set<CGWindowID>,
        isHidden: Bool,
        spaces: WindowSpaceSnapshot
    ) -> WindowInfo? {
        guard axWindowSubrole(axWindow) == kAXStandardWindowSubrole as String,
              let bounds = axWindowFrame(axWindow),
              bounds.width >= 80,
              bounds.height >= 60 else {
            return nil
        }

        let title = axWindowTitle(axWindow) ?? ""

        // The private AXWindowNumber attribute is not exposed by every app.
        // When it is missing we synthesize a stable ID (high bit set, so it
        // cannot collide with real CG window IDs) and let the window be
        // matched by title/bounds when switching, so minimized windows are
        // still listed in the workspace bar instead of disappearing.
        let windowID: CGWindowID
        let minimized = axWindowIsMinimized(axWindow)
        if let number = WindowSystemIdentity.windowID(axWindow) {
            guard !existingWindowIDs.contains(number) else { return nil }
            windowID = number
        } else {
            // 无真实 ID 的普通窗口不能安全截图或确认聚焦。
            guard minimized else { return nil }
            windowID = synthesizedWindowID(ownerPID: ownerPID, title: title, bounds: bounds)
        }
        let membership = spaces.isOnCurrentSpace(windowID)

        return WindowInfo(
            id: windowID,
            ownerPID: ownerPID,
            ownerName: ownerName,
            windowTitle: title,
            bounds: bounds,
            isOnCurrentSpace: membership == true,
            windowNumber: Int(windowID),
            isMinimized: minimized,
            isHidden: isHidden,
            isOnOtherSpace: membership == false
        )
    }

    /// Produces a stable pseudo window ID for minimized windows whose app does
    /// not expose AXWindowNumber. The high bit is set so synthesized IDs never
    /// collide with real CG window IDs (which stay well below 2^31).
    private func synthesizedWindowID(ownerPID: pid_t, title: String, bounds: CGRect) -> CGWindowID {
        let key = "\(ownerPID)|\(title)|\(Int(bounds.origin.x))|\(Int(bounds.origin.y))|\(Int(bounds.width))|\(Int(bounds.height))"
        var hash: UInt32 = 2166136261
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return hash | 0x8000_0000
    }

    private func axWindowIsMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else {
            return false
        }
        if let isMinimized = value as? Bool {
            return isMinimized
        }
        return (value as? NSNumber)?.boolValue ?? false
    }

    private func axWindowSubrole(_ window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axWindowTitle(_ window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func axWindowFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let position = positionValue as! AXValue
        let size = sizeValue as! AXValue
        var point = CGPoint.zero
        var cgSize = CGSize.zero

        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &cgSize) else {
            return nil
        }

        return CGRect(origin: point, size: cgSize)
    }

    // MARK: - Overlay window filtering

    /// Some apps (notably Electron apps such as Feishu/Lark) draw transparent
    /// overlay widgets (watermarks, notification panels) that appear in the
    /// CG window list at layer 0 with the exact same bounds as the real
    /// window. They pollute the preview grid, capture as blank/gray
    /// thumbnails, and clicking them switches to a sibling window.
    ///
    /// When the same app owns multiple windows with identical bounds, consult
    /// the app's Accessibility hierarchy and keep only the "standard" window.
    private func removeOverlayTwins(from windows: [WindowInfo]) -> [WindowInfo] {
        var excluded: Set<CGWindowID> = []
        // Overlays share the real window's desktop. Windows on another desktop are
        // not in kAXWindows, so they can never match the AX "standard" set and
        // would be dropped as twins — e.g. two maximized windows of one app on
        // different desktops have identical bounds but are both real.
        let groups = Dictionary(grouping: windows.filter { !$0.isOnOtherSpace }) { overlayTwinKey($0) }

        for (_, group) in groups where group.count > 1 {
            guard let pid = group.first?.ownerPID,
                  let standardIDs = standardAXWindowCGIDs(for: pid, group: group) else {
                continue
            }
            let matched = group.filter { standardIDs.contains($0.id) }
            if !matched.isEmpty, matched.count < group.count {
                let drop = Set(group.map(\.id)).subtracting(matched.map(\.id))
                excluded.formUnion(drop)
                AppLogger.info("Removed overlay twin windows. ownerPID=\(pid), dropped=\(drop.count)")
            }
        }

        guard !excluded.isEmpty else {
            return windows
        }
        return windows.filter { !excluded.contains($0.id) }
    }

    private func overlayTwinKey(_ window: WindowInfo) -> String {
        let b = window.bounds
        return "\(window.ownerPID):\(Int(b.origin.x)):\(Int(b.origin.y)):\(Int(b.width)):\(Int(b.height))"
    }

    /// Returns the CG window IDs that correspond to the app's standard
    /// (AXStandardWindow) windows for the given twin group.
    ///
    /// - Prefers matching by `AXWindowNumber` when the app exposes it.
    /// - Falls back to z-order pairing, using the app's focused window to decide
    ///   which end of the AX list is the front (the direction is app-specific —
    ///   Chrome lists front-to-back, Feishu back-to-front).
    /// - Returns `nil` when the mapping is ambiguous or the app exposes no
    ///   focused window, so no window is dropped on uncertainty.
    private func standardAXWindowCGIDs(for pid: pid_t, group: [WindowInfo]) -> Set<CGWindowID>? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else {
            return nil
        }

        let standardWindows = axWindows.filter { axWindowIsStandard($0) }

        // Preferred: match by AXWindowNumber.
        var byNumber = Set<CGWindowID>()
        var allHaveNumbers = true
        for axWindow in standardWindows {
            if let number = WindowSystemIdentity.windowID(axWindow) {
                byNumber.insert(number)
            } else {
                allHaveNumbers = false
            }
        }
        if allHaveNumbers, !byNumber.isEmpty {
            return byNumber
        }

        // Fallback: pair by z-order. Both lists describe the same windows, but
        // they do **not** have a universal direction: measured on this system,
        // Chrome reports its frontmost window at AX index 0 (front-to-back)
        // while Feishu reports it at the last index (back-to-front). Assuming
        // front-to-back inverted the pair for Feishu, so the real window was
        // dropped and the transparent watermark overlay kept — leaving a card
        // that cannot be switched to. The app's own focused window is the
        // anchor that reveals the direction.
        guard axWindows.count == group.count else {
            return nil
        }
        guard let focusedIndex = focusedWindowIndex(in: axWindows, ownerPID: pid) else {
            AppLogger.debug("Overlay twin pairing skipped: app has no focused window. pid=\(pid)")
            return nil
        }
        let frontToBack: Bool
        if focusedIndex == 0 {
            frontToBack = true
        } else if focusedIndex == axWindows.count - 1 {
            frontToBack = false
        } else {
            // The anchor is in the middle, so it does not reveal a direction.
            // Dropping a window on a guess is what produced the wrong result
            // before, so leave the list untouched instead.
            AppLogger.debug("Overlay twin pairing skipped: ambiguous AX order. pid=\(pid), focusedIndex=\(focusedIndex), count=\(axWindows.count)")
            return nil
        }

        var paired = Set<CGWindowID>()
        for (index, axWindow) in axWindows.enumerated() where axWindowIsStandard(axWindow) {
            // The focused window is the app's topmost one, i.e. group[0].
            let cgIndex = frontToBack ? index - focusedIndex : focusedIndex - index
            guard cgIndex >= 0, cgIndex < group.count else { continue }
            paired.insert(group[cgIndex].id)
        }
        return paired
    }

    /// Index of the application's focused (key) window inside its own
    /// `kAXWindows` list, or `nil` when the attribute is unavailable.
    ///
    /// Used as an orientation anchor: an app's focused window is its topmost
    /// one, so its position in the list tells us which end is the front.
    private func focusedWindowIndex(in axWindows: [AXUIElement], ownerPID: pid_t) -> Int? {
        let appElement = AXUIElementCreateApplication(ownerPID)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let focused = value as! AXUIElement
        return axWindows.firstIndex { CFEqual($0, focused) }
    }

    private func axWindowIsStandard(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String else {
            // Assume standard when the attribute is unavailable to avoid
            // over-filtering legitimate windows.
            return true
        }
        return subrole == (kAXStandardWindowSubrole as String)
    }
    
    private func extractCGRect(from dict: [String: Any]) -> CGRect {
        guard let x = cgFloatValue(dict["X"]),
              let y = cgFloatValue(dict["Y"]),
              let width = cgFloatValue(dict["Width"]),
              let height = cgFloatValue(dict["Height"]) else {
            return .zero
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func cgFloatValue(_ value: Any?) -> CGFloat? {
        switch value {
        case let value as CGFloat:
            return value
        case let value as Double:
            return CGFloat(value)
        case let value as Int:
            return CGFloat(value)
        case let value as NSNumber:
            return CGFloat(truncating: value)
        default:
            return nil
        }
    }
    
    func getWindows(for bundleIdentifier: String) -> [WindowInfo] {
        windows(matching: bundleIdentifier, appName: nil)
    }

    /// Returns the windows belonging to one specific app *instance*.
    ///
    /// Filtering by the app name in addition to the bundle ID disambiguates
    /// distinct products that share a bundle identifier (e.g. ChatGPT and
    /// ChatGPT Atlas both use `com.openai.chat`). Without the name check one
    /// product's windows leak into the other's preview and switch target.
    func getWindows(for bundleIdentifier: String, appName: String) -> [WindowInfo] {
        windows(matching: bundleIdentifier, appName: appName)
    }
    
    func getWindows(for app: MonitoredApp) -> [WindowInfo] {
        windows(matching: app.bundleIdentifier, appName: app.appName)
    }

    /// Returns the windows owned by any running process that belongs to the
    /// product at `bundleURL` — i.e. whose own bundle/executable URL lives
    /// at-or-under the product's bundle root.
    ///
    /// This is the authoritative attribution for Dock-icon-scoped previews.
    /// Apps frequently span several processes (main app, nested bundles such
    /// as WeChat's WeChatAppEx.app, renderer/mini-program helpers), and the
    /// windows they own can be reported under any of them. Matching by an
    /// exact bundle URL then shows "No windows" for the nested Dock icon,
    /// while matching by PID only resolves the icon to whichever process the
    /// Dock happened to map it to. The product root (see
    /// `WindowAttribution.productRootURL`) collapses all of these into one
    /// identity, so every window of the product is listed.
    func windows(ownedBy bundleURL: URL) -> [WindowInfo] {
        guard let productRoot = WindowAttribution.productRootURL(for: bundleURL) else {
            return []
        }
        let allWindows = getAllWindows()
        let matched = allWindows.filter { window in
            guard let app = NSRunningApplication(processIdentifier: window.ownerPID) else {
                return false
            }
            return WindowAttribution.process(app, belongsTo: productRoot)
        }
        AppLogger.info("Matched windows by product root. bundleURL=\(bundleURL.path), root=\(productRoot.path), count=\(matched.count)")
        return matched
    }

    private func windows(matching bundleIdentifier: String, appName: String?) -> [WindowInfo] {
        let allWindows = getAllWindows()
        let windows = filterWindows(allWindows, for: bundleIdentifier, appName: appName)
        AppLogger.debug("Filtered windows for app. bundleID=\(bundleIdentifier), appName=\(appName ?? "nil"), count=\(windows.count)")
        return windows
    }

    func getVisibleWindowCount(for bundleIdentifier: String) -> Int {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            AppLogger.error("CGWindowListCopyWindowInfo returned nil while counting windows. bundleID=\(bundleIdentifier)")
            return 0
        }

        let count = windowList.filter { windowDict in
            guard let ownerPID = windowDict[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = windowDict[kCGWindowBounds as String] as? [String: Any],
                  let bundleID = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier else {
                return false
            }

            let layer = windowDict[kCGWindowLayer as String] as? Int ?? 0
            let bounds = extractCGRect(from: boundsDict)
            return bundleID == bundleIdentifier
                && layer == 0
                && bounds.width > 0
                && bounds.height > 0
        }.count

        AppLogger.debug("Counted visible windows. bundleID=\(bundleIdentifier), count=\(count)")
        return count
    }
    
    func filterWindows(_ windows: [WindowInfo], by strategy: PreviewStrategy) -> [WindowInfo] {
        switch strategy {
        case .allApplications:
            AppLogger.debug("Window filter strategy allApplications. inputCount=\(windows.count)")
            return windows
        case .configuredOnly:
            let settings = settingsService.loadSettings()
            let filteredWindows = windows.filter { window in
                guard let runningApp = NSRunningApplication(processIdentifier: window.ownerPID),
                      let runningBundleID = runningApp.bundleIdentifier else {
                    return false
                }
                // Match by bundle ID *and* app name: distinct products can
                // share a bundle identifier (e.g. ChatGPT and ChatGPT Atlas
                // both use `com.openai.codex`), and filtering on the bundle ID
                // alone would pull the other product's windows into this
                // app's preview and switch target.
                return settings.monitoredApps.contains { app in
                    guard app.bundleIdentifier == runningBundleID else {
                        return false
                    }
                    guard !app.appName.isEmpty else {
                        return true
                    }
                    return app.appName.lowercased()
                        == (runningApp.localizedName ?? window.ownerName).lowercased()
                }
            }
            AppLogger.debug("Window filter strategy configuredOnly. inputCount=\(windows.count), configuredApps=\(settings.monitoredApps.count), outputCount=\(filteredWindows.count)")
            return filteredWindows
        }
    }
    
    func filterWindows(_ windows: [WindowInfo], by searchText: String) -> [WindowInfo] {
        guard !searchText.isEmpty else {
            return windows
        }
        
        let searchLowercased = searchText.lowercased()
        return windows.filter { window in
            window.ownerName.lowercased().contains(searchLowercased) ||
            window.windowTitle.lowercased().contains(searchLowercased)
        }
    }
    
    private func refreshWindowList() {
        AppLogger.verbose("Posting window list refresh notification")
        NotificationCenter.default.post(name: .windowListDidRefresh, object: nil)
    }

    private func setupWorkspaceObservers() {
        guard workspaceObservers.isEmpty else {
            return
        }

        let notificationCenter = NSWorkspace.shared.notificationCenter
        let activatedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.accessibilityWindowsCache = nil
            self?.enumerationRevision += 1
            self?.activeBundleIdentifier = app.bundleIdentifier
            self?.processWindowChanges(reason: "activated:\(app.bundleIdentifier ?? "unknown")")
        }

        let launchedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.accessibilityWindowsCache = nil
            self?.enumerationRevision += 1
            self?.processWindowChanges(reason: "launched:\(app.bundleIdentifier ?? "unknown")")
        }

        let terminatedObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.accessibilityWindowsCache = nil
            self?.enumerationRevision += 1
            self?.processWindowChanges(reason: "terminated:\(app.bundleIdentifier ?? "unknown")")
        }

        let spaceObserver = notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.accessibilityWindowsCache = nil
            self?.enumerationRevision += 1
            self?.refreshWindowList()
        }
        workspaceObservers = [activatedObserver, launchedObserver, terminatedObserver, spaceObserver]
        AppLogger.debug("Workspace observers registered")
    }

    /// 通知可见面板刷新，并为尚无缓存截图的窗口预热。
    /// 已有缓存（内存或磁盘）的窗口不再预热；它们由打开面板时的按需路径
    /// 和可见面板的 refresh interest 维护。
    func processWindowChanges(reason: String) {
        // Use the on-screen-only fast path here so focus switches stay snappy:
        // the full (AX-heavy) enumeration is reserved for the preview panel.
        let windows = getOnScreenWindows()
        AppLogger.verbose("Processed window changes. reason=\(reason), windows=\(windows.count)")
        refreshWindowList()
        preheatUncachedThumbnails(windows: windows, reason: reason)
    }

    private func preheatUncachedThumbnails(windows: [WindowInfo], reason: String) {
        guard !windows.isEmpty else { return }

        let settings = settingsService.loadSettings()
        let monitoredBundleIDs = Set(settings.monitoredApps.filter(\.isEnabled).map(\.bundleIdentifier))
        let activeBundleID = activeBundleIdentifier

        // 先挑出没有缓存的窗口，再做 LaunchServices 查询，避免缓存命中的窗口白付 IPC 成本。
        let uncached = windows.filter { thumbnailService.getCachedThumbnail(for: $0, tier: .grid) == nil }
        guard !uncached.isEmpty else { return }

        let bundleIDs: [CGWindowID: String?] = Dictionary(
            uniqueKeysWithValues: uncached.map { ($0.id, NSRunningApplication(processIdentifier: $0.ownerPID)?.bundleIdentifier) }
        )
        func score(_ window: WindowInfo) -> Int {
            let bundleID = bundleIDs[window.id] ?? nil
            var score = 0
            if bundleID == activeBundleID { score += 30 }
            if bundleID.map({ monitoredBundleIDs.contains($0) }) == true { score += 20 }
            if !window.windowTitle.isEmpty { score += 5 }
            return score
        }

        let prioritized = uncached.sorted { score($0) > score($1) }.prefix(maxPreheatWindowsPerTick)
        thumbnailService.preheatUncachedThumbnails(
            for: Array(prioritized),
            size: settings.thumbnailSize.dimensions,
            reason: reason
        )
    }
}

extension Notification.Name {
    static let windowListDidRefresh = Notification.Name("com.switchly.windowListDidRefresh")
}
