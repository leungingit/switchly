//
//  DesktopSpaceServiceTests.swift
//  SwitchlyTests
//
//  Read-only desktop enumeration: ordering, full-screen exclusion, window
//  attribution and unavailable degradation. Uses fabricated Space layouts;
//  no private framework is touched by the tests.
//

import XCTest
import CoreGraphics
@testable import Switchly

private final class FakeSpaceBridge: SpaceReading {
    var isAvailable = true
    var displays: [RawDisplaySpaces]?
    var memberships: [CGWindowID: [UInt64]] = [:]

    func readSpaces() -> [RawDisplaySpaces]? { displays }

    func spaceIDs(forWindowIDs ids: [CGWindowID]) -> [CGWindowID: [UInt64]] {
        ids.reduce(into: [:]) { result, id in
            result[id] = memberships[id] ?? []
        }
    }
}

final class DesktopSpaceServiceTests: XCTestCase {

    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testOrdinarySpacesAreNumberedInSystemOrderAndFullScreenIsSkipped() {
        let displays = [
            RawDisplaySpaces(
                identifier: "main",
                isMain: true,
                currentSpaceID: 12,
                spaces: [RawSpace(id: 10, type: 0), RawSpace(id: 11, type: 4), RawSpace(id: 12, type: 0)]
            )
        ]

        let snapshot = DesktopSpaceService.buildSnapshot(
            displays: displays,
            windows: [],
            memberships: [:],
            capturedAt: capturedAt
        )

        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.desktops.map(\.number), [1, 2])
        XCTAssertEqual(snapshot.desktops.map(\.id), [10, 12])
        XCTAssertFalse(snapshot.desktops[0].isCurrent)
        XCTAssertTrue(snapshot.desktops[1].isCurrent)
        XCTAssertEqual(snapshot.currentDesktop?.number, 2)
    }

    func testWindowMembershipAttributesMultiSpaceWindowsAndSkipsUnmapped() {
        let displays = [
            RawDisplaySpaces(
                identifier: "main",
                isMain: true,
                currentSpaceID: 10,
                spaces: [RawSpace(id: 10, type: 0), RawSpace(id: 12, type: 0), RawSpace(id: 14, type: 0)]
            )
        ]
        let first = window(1, pid: 100, owner: "Mail")
        let multi = window(2, pid: 200, owner: "Safari")
        let unmapped = window(3, pid: 300, owner: "Notes")

        let snapshot = DesktopSpaceService.buildSnapshot(
            displays: displays,
            windows: [first, multi, unmapped],
            memberships: [1: [10], 2: [10, 12], 3: []],
            capturedAt: capturedAt
        )

        XCTAssertEqual(snapshot.slot(1)?.windows.map(\.id), [1, 2])
        XCTAssertEqual(snapshot.slot(2)?.windows.map(\.id), [2])
        XCTAssertTrue(snapshot.slot(3)?.isEmpty == true)
    }

    func testEmptyDesktopIsReportedAsEmptyNotMissing() {
        let displays = [
            RawDisplaySpaces(
                identifier: "main",
                isMain: true,
                currentSpaceID: 10,
                spaces: [RawSpace(id: 10, type: 0), RawSpace(id: 12, type: 0)]
            )
        ]

        let snapshot = DesktopSpaceService.buildSnapshot(
            displays: displays,
            windows: [],
            memberships: [:],
            capturedAt: capturedAt
        )

        XCTAssertEqual(snapshot.desktops.count, 2)
        XCTAssertTrue(snapshot.desktops.allSatisfy(\.isEmpty))
    }

    func testAppOwnersKeepFrontmostOrderAndDedupe() {
        let desktop = Desktop(
            id: 10,
            number: 1,
            isCurrent: true,
            windows: [
                window(1, pid: 10, owner: "Mail"),
                window(2, pid: 20, owner: "Safari"),
                window(3, pid: 10, owner: "Mail"),
                window(4, pid: 30, owner: "Notes"),
                window(5, pid: 40, owner: "Xcode"),
            ]
        )

        let owners = desktop.appOwners(limit: 3)
        XCTAssertEqual(owners.owners.map(\.pid), [10, 20, 30])
        XCTAssertEqual(owners.total, 4)
        XCTAssertEqual(owners.owners.first?.initial, "M")
    }

    func testMainDisplayWinsWhenSeveralDisplaysHaveSpaces() {
        let displays = [
            RawDisplaySpaces(
                identifier: "secondary",
                isMain: false,
                currentSpaceID: 20,
                spaces: [RawSpace(id: 20, type: 0)]
            ),
            RawDisplaySpaces(
                identifier: "main",
                isMain: true,
                currentSpaceID: 10,
                spaces: [RawSpace(id: 10, type: 0), RawSpace(id: 11, type: 0)]
            ),
        ]

        let snapshot = DesktopSpaceService.buildSnapshot(
            displays: displays,
            windows: [],
            memberships: [:],
            capturedAt: capturedAt
        )

        XCTAssertEqual(snapshot.desktops.map(\.id), [10, 11])
    }

    func testFirstOrdinaryDisplayIsUsedWhenNoMainFlagIsPresent() {
        let displays = [
            RawDisplaySpaces(
                identifier: "fullscreen-only",
                isMain: false,
                currentSpaceID: 30,
                spaces: [RawSpace(id: 30, type: 4)]
            ),
            RawDisplaySpaces(
                identifier: "first-ordinary",
                isMain: false,
                currentSpaceID: 40,
                spaces: [RawSpace(id: 40, type: 0)]
            ),
        ]

        let snapshot = DesktopSpaceService.buildSnapshot(
            displays: displays,
            windows: [],
            memberships: [:],
            capturedAt: capturedAt
        )

        XCTAssertEqual(snapshot.desktops.map(\.id), [40])
    }

    func testNoOrdinaryDisplayDegradesToUnavailable() {
        let displays = [
            RawDisplaySpaces(
                identifier: "main",
                isMain: true,
                currentSpaceID: 30,
                spaces: [RawSpace(id: 30, type: 4)]
            )
        ]

        let snapshot = DesktopSpaceService.buildSnapshot(
            displays: displays,
            windows: [],
            memberships: [:],
            capturedAt: capturedAt
        )

        XCTAssertTrue(snapshot.availability.isUnavailable)
        XCTAssertTrue(snapshot.desktops.isEmpty)
    }

    func testUnavailableBridgeReturnsUnavailableSnapshotWithoutCrashing() async {
        let bridge = FakeSpaceBridge()
        bridge.isAvailable = false
        let service = DesktopSpaceService(bridge: bridge, windowProvider: { [] })

        let snapshot = await service.loadSnapshot()

        XCTAssertTrue(snapshot.availability.isUnavailable)
        XCTAssertTrue(snapshot.desktops.isEmpty)
    }

    func testServiceWiresBridgeReadsIntoDomainSnapshot() async {
        let bridge = FakeSpaceBridge()
        bridge.displays = [
            RawDisplaySpaces(
                identifier: "main",
                isMain: true,
                currentSpaceID: 10,
                spaces: [RawSpace(id: 10, type: 0), RawSpace(id: 12, type: 0)]
            )
        ]
        let first = window(1, pid: 100, owner: "Mail")
        let second = window(2, pid: 200, owner: "Safari")
        bridge.memberships = [1: [10], 2: [12]]

        let service = DesktopSpaceService(bridge: bridge, windowProvider: { [first, second] })
        let snapshot = await service.loadSnapshot()

        XCTAssertEqual(snapshot.desktops.count, 2)
        XCTAssertEqual(snapshot.slot(1)?.windows.map(\.id), [1])
        XCTAssertEqual(snapshot.slot(2)?.windows.map(\.id), [2])
        XCTAssertEqual(snapshot.currentDesktop?.number, 1)
    }

    func testOrdinarySpacesSelectionPrefersTheMainDisplay() {
        let displays = [
            RawDisplaySpaces(
                identifier: "secondary",
                isMain: false,
                currentSpaceID: 20,
                spaces: [RawSpace(id: 20, type: 0), RawSpace(id: 21, type: 4)]
            ),
            RawDisplaySpaces(
                identifier: "main",
                isMain: true,
                currentSpaceID: 11,
                spaces: [RawSpace(id: 10, type: 0), RawSpace(id: 11, type: 0)]
            ),
        ]

        let selection = DesktopSpaceService.ordinarySpaces(in: displays)

        XCTAssertEqual(selection?.spaces.map(\.id), [10, 11])
        XCTAssertEqual(selection?.currentSpaceID, 11)
        XCTAssertNil(
            DesktopSpaceService.ordinarySpaces(in: [
                RawDisplaySpaces(identifier: "fs", isMain: true, currentSpaceID: 30, spaces: [RawSpace(id: 30, type: 4)])
            ]),
            "a display with only full-screen spaces has no ordinary desktop"
        )
    }

    func testCurrentDesktopNumberIsOneBasedInTheOrdinaryOrder() async {
        let bridge = FakeSpaceBridge()
        bridge.displays = [
            RawDisplaySpaces(
                identifier: "main",
                isMain: true,
                currentSpaceID: 12,
                spaces: [RawSpace(id: 10, type: 0), RawSpace(id: 11, type: 4), RawSpace(id: 12, type: 0)]
            )
        ]
        let service = DesktopSpaceService(bridge: bridge, windowProvider: { [] })

        let number = await service.currentDesktopNumber()
        XCTAssertEqual(number, 2, "the full-screen space must not take a number")
    }

    func testCurrentDesktopNumberIsNilWhenTheCurrentSpaceIsUnknown() async {
        let bridge = FakeSpaceBridge()
        bridge.displays = [
            RawDisplaySpaces(
                identifier: "main",
                isMain: true,
                currentSpaceID: 99,
                spaces: [RawSpace(id: 10, type: 0)]
            )
        ]
        let service = DesktopSpaceService(bridge: bridge, windowProvider: { [] })

        let number = await service.currentDesktopNumber()
        XCTAssertNil(number)
    }

    // MARK: - Helpers

    private func window(_ id: CGWindowID, pid: pid_t, owner: String) -> WindowInfo {
        WindowInfo(
            id: id,
            ownerPID: pid,
            ownerName: owner,
            windowTitle: "title-\(id)",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnCurrentSpace: false,
            windowNumber: Int(id)
        )
    }
}
