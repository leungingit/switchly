//
//  Desktop.swift
//  Switchly
//
//  Domain model for the 3×3 desktop (Space) overview.
//  See docs/desktop-grid-design-spec.md §3.1 and §10.
//

import Foundation
import CoreGraphics

/// One ordinary desktop (Space) on the display the overview targets.
///
/// `id` is the private SkyLight Space identifier. It is stable for the current
/// session but must not be persisted: the evaluation report (§9.3) found Space
/// UUIDs can be empty and the system may renumber desktops after a restart.
struct Desktop: Identifiable, Hashable {
    /// SkyLight Space ID, session-scoped only.
    let id: UInt64
    /// 1-based position, matching the order Mission Control shows.
    let number: Int
    /// Whether this desktop is the current one.
    let isCurrent: Bool
    /// Windows whose Space membership includes this desktop, front to back.
    let windows: [WindowInfo]

    var isEmpty: Bool { windows.isEmpty }
    var windowCount: Int { windows.count }

    /// Distinct applications, preserving the first (frontmost) appearance.
    /// At most `limit` owners are returned; `total` keeps the uncapped count
    /// so a cell can render "+N".
    func appOwners(limit: Int = 4) -> (owners: [DesktopAppOwner], total: Int) {
        var seen = Set<pid_t>()
        var owners: [DesktopAppOwner] = []
        for window in windows {
            guard seen.insert(window.ownerPID).inserted else { continue }
            if owners.count < limit {
                owners.append(DesktopAppOwner(pid: window.ownerPID, name: window.ownerName))
            }
        }
        return (owners, seen.count)
    }
}

/// An application that owns at least one window on a desktop.
struct DesktopAppOwner: Identifiable, Hashable {
    let pid: pid_t
    let name: String

    var id: pid_t { pid }

    /// First visible character used by the letter-block fallback.
    var initial: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }
}

/// Result of one read-only desktop enumeration.
struct DesktopSpaceSnapshot: Equatable {
    let desktops: [Desktop]
    let availability: DesktopSpaceAvailability
    let capturedAt: Date
    /// Most ordinary desktops on any one display. The grid targets the
    /// display in use, but "at least two desktops" is met by any display.
    var maxDisplayDesktopCount: Int = 0

    /// The overview always has nine slots. Missing desktops are "not created".
    func slot(_ number: Int) -> Desktop? {
        desktops.first { $0.number == number }
    }

    var currentDesktop: Desktop? {
        desktops.first(where: \.isCurrent)
    }

    static let empty = DesktopSpaceSnapshot(
        desktops: [],
        availability: .available,
        capturedAt: .distantPast
    )

    static func unavailable(reason: String) -> DesktopSpaceSnapshot {
        DesktopSpaceSnapshot(
            desktops: [],
            availability: .unavailable(reason: reason),
            capturedAt: Date()
        )
    }
}

/// Why the enumeration produced no desktops.
///
/// The reason is for logs only; the UI derives its copy from the state, not
/// from a private framework's error string.
enum DesktopSpaceAvailability: Equatable {
    case available
    case unavailable(reason: String)

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// One of the nine fixed overview slots.
struct DesktopGridSlot: Identifiable, Equatable {
    /// 1...9, left-to-right then top-to-bottom.
    let number: Int
    let desktop: Desktop?

    var id: Int { number }
    var isCreated: Bool { desktop != nil }
    var isCurrent: Bool { desktop?.isCurrent == true }

    static func makeSlots(from snapshot: DesktopSpaceSnapshot) -> [DesktopGridSlot] {
        (1...9).map { number in
            DesktopGridSlot(number: number, desktop: snapshot.slot(number))
        }
    }
}
