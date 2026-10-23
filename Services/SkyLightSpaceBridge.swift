//
//  SkyLightSpaceBridge.swift
//  Switchly
//
//  Read-only bridge to the private SkyLight symbols that describe Spaces.
//
//  Only read entry points are resolved: SLSMainConnectionID,
//  SLSCopyManagedDisplaySpaces, SLSManagedDisplayGetCurrentSpace and
//  SLSCopySpacesForWindows. No SetCurrentSpace / MoveWindowsToManagedSpace
//  symbol is looked up, let alone called (docs/desktop-grid-design-spec.md
//  §12; docs/desktop-grid-evaluation-2026-10-21.md §5.2).
//
//  The framework is opened at runtime with dlopen + dlsym. A missing symbol is
//  a normal "unavailable" state, never a crash and never a link-time
//  dependency.
//

import Foundation
import CoreGraphics
import ColorSync

/// Raw output of one Space enumeration, before domain mapping.
struct RawDisplaySpaces: Equatable {
    let identifier: String
    let isMain: Bool
    let currentSpaceID: UInt64
    let spaces: [RawSpace]
}

struct RawSpace: Equatable {
    let id: UInt64
    /// SkyLight Space type: 0 is an ordinary desktop, 4 is a full-screen
    /// space. Only 0 participates in the 3×3 overview.
    let type: Int
}

/// Abstraction over the private framework so the service can be tested with
/// fabricated Space layouts.
///
/// Sendable because the service hands the bridge to its serial
/// `com.switchly.desktopSpace` queue: the read-only contract (plus the
/// conformance note below) is what makes that hand-off safe.
protocol SpaceReading: AnyObject, Sendable {
    var isAvailable: Bool { get }
    /// Nil when the display snapshot cannot be read.
    func readSpaces() -> [RawDisplaySpaces]?
    func spaceIDs(forWindowIDs ids: [CGWindowID]) -> [CGWindowID: [UInt64]]
}

/// `@unchecked Sendable`: the class caches resolved private symbols at init and
/// lazily resolves the process-wide connection on first use. `DesktopSpaceService`
/// only touches it from its serial `com.switchly.desktopSpace` queue, so that
/// cache is never read and written concurrently; the protocol conformance lets
/// the service capture the bridge in the queue's `@Sendable` closure without
/// the non-Sendable-existential warning.
final class SkyLightSpaceBridge: SpaceReading, @unchecked Sendable {
    typealias MainConnectionID = @convention(c) () -> Int32
    typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias ManagedDisplayGetCurrentSpace = @convention(c) (Int32, CFString) -> UInt64
    typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    /// Mask used by the feasibility probe: all Spaces a window belongs to.
    private static let allSpaceMask: Int32 = 7

    private var handle: UnsafeMutableRawPointer?
    private var connectionID: MainConnectionID?
    private var copyDisplaySpaces: CopyManagedDisplaySpaces?
    private var currentSpace: ManagedDisplayGetCurrentSpace?
    private var spacesForWindows: CopySpacesForWindows?

    /// Cached because the connection is process-wide and does not change.
    private lazy var mainConnection: Int32? = connectionID?()

    let isAvailable: Bool

    init(frameworkPath: String = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight") {
        handle = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL)

        guard let handle else {
            isAvailable = false
            AppLogger.warning("Desktop space enumeration unavailable. reason=dlopen_failed")
            return
        }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: T.self)
        }

        connectionID = symbol("SLSMainConnectionID", as: MainConnectionID.self)
        copyDisplaySpaces = symbol("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
        currentSpace = symbol("SLSManagedDisplayGetCurrentSpace", as: ManagedDisplayGetCurrentSpace.self)
        spacesForWindows = symbol("SLSCopySpacesForWindows", as: CopySpacesForWindows.self)

        isAvailable = connectionID != nil
            && copyDisplaySpaces != nil
            && currentSpace != nil
            && spacesForWindows != nil

        if !isAvailable {
            AppLogger.warning("Desktop space enumeration unavailable. reason=missing_read_symbol")
        }
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    func readSpaces() -> [RawDisplaySpaces]? {
        guard isAvailable,
              let connection = mainConnection,
              let copyDisplaySpaces,
              let rawSnapshot = copyDisplaySpaces(connection)?.takeRetainedValue(),
              let snapshot = rawSnapshot as? [[String: Any]] else {
            return nil
        }

        let mainUUID = Self.mainDisplayUUID()
        var displays: [RawDisplaySpaces] = []

        for display in snapshot {
            let identifier = display["Display Identifier"] as? String ?? ""
            let currentID = identifier.isEmpty
                ? 0
                : currentSpace?(connection, identifier as CFString) ?? 0
            let rawSpaces = (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space -> RawSpace? in
                guard let id = (space["id64"] as? NSNumber)?.uint64Value else { return nil }
                let type = (space["type"] as? NSNumber)?.intValue ?? -1
                return RawSpace(id: id, type: type)
            }
            displays.append(
                RawDisplaySpaces(
                    identifier: identifier,
                    isMain: identifier == "Main" || (mainUUID != nil && identifier == mainUUID),
                    currentSpaceID: currentID,
                    spaces: rawSpaces
                )
            )
        }

        return displays.isEmpty ? nil : displays
    }

    func spaceIDs(forWindowIDs ids: [CGWindowID]) -> [CGWindowID: [UInt64]] {
        guard isAvailable,
              let connection = mainConnection,
              let spacesForWindows else {
            return [:]
        }

        var result: [CGWindowID: [UInt64]] = [:]
        for id in ids {
            let query = [NSNumber(value: id)] as CFArray
            guard let membership = spacesForWindows(connection, Self.allSpaceMask, query)?.takeRetainedValue() as? [NSNumber] else {
                continue
            }
            result[id] = membership.map(\.uint64Value)
        }
        return result
    }

    private static func mainDisplayUUID() -> String? {
        guard let created = CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID()) else {
            return nil
        }
        let uuid = created.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }
}
