//
//  DesktopSpaceService.swift
//  Switchly
//
//  Read-only enumeration of ordinary desktops (Spaces), their current value
//  and the window membership of each desktop.
//
//  Reuses CG window metadata and the Space IDs from the read-only SkyLight
//  bridge. It never creates, deletes, reorders or switches a Space.
//

import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

protocol DesktopSpaceServiceProtocol {
    /// Reads the overview's desktop list. Never throws: a private-framework or
    /// snapshot failure resolves to `.unavailable` so the UI can degrade.
    func loadSnapshot() async -> DesktopSpaceSnapshot
    /// Desktops and the current one, without window membership. The swipe
    /// path uses it: enumerating every window delayed the HUD and the switch.
    func loadLayout() async -> DesktopSpaceSnapshot
}

extension DesktopSpaceServiceProtocol {
    func loadLayout() async -> DesktopSpaceSnapshot { await loadSnapshot() }
}

/// Cheap "which desktop am I on" read, without enumerating windows.
///
/// The navigation confirmation loop polls this several times a second; a full
/// snapshot costs one CoreGraphics window list plus one Space query per
/// window, which is far too much for that cadence.
protocol DesktopCurrentDesktopReading {
    func currentDesktopNumber() async -> Int?
}

final class DesktopSpaceService: DesktopSpaceServiceProtocol, DesktopCurrentDesktopReading {
    static let shared = DesktopSpaceService()

    private let bridge: SpaceReading
    private let windowProvider: () -> [WindowInfo]
    private let activeDisplayProvider: () -> String?
    private let queue = DispatchQueue(
        label: "com.switchly.desktopSpace",
        qos: .userInitiated
    )

    init(
        bridge: SpaceReading = SkyLightSpaceBridge(),
        windowProvider: @escaping () -> [WindowInfo] = DesktopSpaceService.readOnscreenWindows,
        activeDisplayProvider: @escaping () -> String? = DesktopSpaceService.pointerDisplayUUID
    ) {
        self.bridge = bridge
        self.windowProvider = windowProvider
        self.activeDisplayProvider = activeDisplayProvider
    }

    func loadSnapshot() async -> DesktopSpaceSnapshot {
        let bridge = self.bridge
        let windowProvider = self.windowProvider
        let activeDisplayProvider = self.activeDisplayProvider
        let queue = self.queue

        return await withCheckedContinuation { continuation in
            queue.async {
                guard bridge.isAvailable, let displays = bridge.readSpaces() else {
                    AppLogger.warning("Desktop space snapshot unavailable")
                    continuation.resume(returning: .unavailable(reason: "space_snapshot_unavailable"))
                    return
                }

                let windows = windowProvider()
                let memberships = bridge.spaceIDs(forWindowIDs: windows.map(\.id))
                continuation.resume(
                    returning: DesktopSpaceService.buildSnapshot(
                        displays: displays,
                        windows: windows,
                        memberships: memberships,
                        activeDisplay: activeDisplayProvider(),
                        capturedAt: Date()
                    )
                )
            }
        }
    }

    func loadLayout() async -> DesktopSpaceSnapshot {
        let bridge = self.bridge
        let activeDisplayProvider = self.activeDisplayProvider
        let queue = self.queue
        return await withCheckedContinuation { continuation in
            queue.async {
                guard bridge.isAvailable, let displays = bridge.readSpaces() else {
                    continuation.resume(returning: .unavailable(reason: "space_snapshot_unavailable"))
                    return
                }
                continuation.resume(
                    returning: DesktopSpaceService.buildSnapshot(
                        displays: displays,
                        windows: [],
                        memberships: [:],
                        activeDisplay: activeDisplayProvider(),
                        capturedAt: Date()
                    )
                )
            }
        }
    }

    func currentDesktopNumber() async -> Int? {
        let bridge = self.bridge
        let activeDisplayProvider = self.activeDisplayProvider
        let queue = self.queue
        return await withCheckedContinuation { continuation in
            queue.async {
                guard bridge.isAvailable,
                      let displays = bridge.readSpaces(),
                      let selection = DesktopSpaceService.ordinarySpaces(
                          in: displays,
                          activeDisplay: activeDisplayProvider()
                      ),
                      let index = selection.spaces.firstIndex(where: { $0.id == selection.currentSpaceID }) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: index + 1)
            }
        }
    }

    // MARK: - Pure mapping (unit tested)

    /// The display the overview targets and its ordinary spaces.
    ///
    /// One display only: the one in use (under the pointer), then the main
    /// one, otherwise the first with ordinary spaces. Space IDs are
    /// display-scoped, so mixing displays would produce two "current" cells
    /// and duplicate numbering. The display in use wins even with a single
    /// desktop, so gestures there stay inert instead of driving another
    /// display's desktops.
    static func ordinarySpaces(
        in displays: [RawDisplaySpaces],
        activeDisplay: String? = nil
    ) -> (spaces: [RawSpace], currentSpaceID: UInt64)? {
        let candidates = displays.filter { display in
            display.spaces.contains { $0.type == 0 }
        }
        guard let display = candidates.first(where: { activeDisplay != nil && $0.identifier == activeDisplay })
            ?? candidates.first(where: \.isMain)
            ?? candidates.first else {
            return nil
        }
        return (display.spaces.filter { $0.type == 0 }, display.currentSpaceID)
    }

    /// Maps one raw display snapshot to the overview's domain model.
    ///
    /// - The overview targets one display: the display in use, then the main
    ///   display, otherwise the first display with ordinary spaces. Space IDs are
    ///   display-scoped, so mixing displays would produce two "current" cells
    ///   and duplicate numbering.
    /// - Only ordinary spaces (`type == 0`) participate; full-screen spaces
    ///   appear and disappear with their window and are not numbered.
    /// - Windows with no readable membership are omitted rather than assumed
    ///   to belong to the current desktop.
    static func buildSnapshot(
        displays: [RawDisplaySpaces],
        windows: [WindowInfo],
        memberships: [CGWindowID: [UInt64]],
        activeDisplay: String? = nil,
        capturedAt: Date
    ) -> DesktopSpaceSnapshot {
        guard let selection = ordinarySpaces(in: displays, activeDisplay: activeDisplay) else {
            return DesktopSpaceSnapshot(
                desktops: [],
                availability: .unavailable(reason: "no_display_with_spaces"),
                capturedAt: capturedAt
            )
        }
        let maxDisplayDesktopCount = displays
            .map { $0.spaces.filter { $0.type == 0 }.count }
            .max() ?? 0

        let spaces = selection.spaces
        let currentID = selection.currentSpaceID

        var windowsBySpace: [UInt64: [WindowInfo]] = [:]
        for window in windows {
            for spaceID in memberships[window.id] ?? [] {
                windowsBySpace[spaceID, default: []].append(window)
            }
        }

        let desktops = spaces.enumerated().map { index, space in
            Desktop(
                id: space.id,
                number: index + 1,
                isCurrent: space.id == currentID,
                windows: windowsBySpace[space.id] ?? []
            )
        }

        return DesktopSpaceSnapshot(
            desktops: desktops,
            availability: .available,
            capturedAt: capturedAt,
            maxDisplayDesktopCount: maxDisplayDesktopCount
        )
    }

    /// UUID of the display under the pointer, matching SkyLight's
    /// "Display Identifier". CoreGraphics only, so it is safe off the main
    /// thread. With "Displays have separate Spaces" off the snapshot has a
    /// single "Main" entry, which no UUID matches, so selection falls back.
    static func pointerDisplayUUID() -> String? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success, count > 0,
              let created = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }
        return CFUUIDCreateString(nil, created.takeRetainedValue()) as String
    }

    // MARK: - Global order (read-only)

    /// Ordinary Space IDs across every display, display by display, in the
    /// order the system numbers them. The system "switch to desktop N" hotkey
    /// counts in this order, which spans displays, so the overview's
    /// main-display numbering is not enough to address it
    /// (docs/desktop-grid-evaluation-2026-10-21.md §10.2 note 1).
    func globalOrdinarySpaceOrder() async -> [UInt64] {
        let bridge = self.bridge
        let queue = self.queue
        return await withCheckedContinuation { continuation in
            queue.async {
                guard bridge.isAvailable, let displays = bridge.readSpaces() else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(
                    returning: displays.flatMap { display in
                        display.spaces.filter { $0.type == 0 }.map(\.id)
                    }
                )
            }
        }
    }

    // MARK: - Window enumeration

    /// Layer-zero, non-zero-size windows owned by other processes.
    ///
    /// This is metadata only (`kCGWindowListOptionAll`), not a screenshot, so
    /// it works without Screen Recording. Titles are read but never logged.
    static func readOnscreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            AppLogger.warning("Desktop space window list unavailable")
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { entry -> WindowInfo? in
            guard let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ownPID,
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 1,
                  bounds.height > 1 else {
                return nil
            }

            return WindowInfo(
                id: windowID,
                ownerPID: ownerPID,
                ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                windowTitle: entry[kCGWindowName as String] as? String ?? "",
                bounds: bounds,
                isOnCurrentSpace: false,
                windowNumber: Int(windowID)
            )
        }
    }
}
