import XCTest
@testable import Switchly

final class ActivityQueryTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_699_999_200)

    private func session(
        bundleID: String,
        name: String,
        start: TimeInterval,
        end: TimeInterval,
        seconds: TimeInterval
    ) -> ActivitySession {
        ActivitySession(
            id: UUID(),
            bundleID: bundleID,
            appName: name,
            start: baseDate.addingTimeInterval(start),
            end: baseDate.addingTimeInterval(end),
            seconds: seconds,
            endReason: .checkpoint
        )
    }

    private func newYorkCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    func testAppGroupingUsesHalfOpenClippingAndProportionalSeconds() {
        let sessions = [
            session(
                bundleID: "com.z",
                name: "Zeta",
                start: 10,
                end: 30,
                seconds: 20
            ),
            session(
                bundleID: "com.a",
                name: "Alpha",
                start: 25,
                end: 35,
                seconds: 5
            ),
            session(
                bundleID: "com.ends-at-from",
                name: "Excluded End",
                start: 0,
                end: 20,
                seconds: 20
            ),
            session(
                bundleID: "com.starts-at-to",
                name: "Excluded Start",
                start: 30,
                end: 40,
                seconds: 10
            )
        ]

        let rows = ActivityQuery.summary(
            sessions: sessions,
            from: baseDate.addingTimeInterval(20),
            to: baseDate.addingTimeInterval(30),
            groupBy: "app",
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0["bundleID"] as? String }, ["com.a", "com.z"])
        XCTAssertEqual(rows[0]["name"] as? String, "Alpha")
        XCTAssertEqual(rows[0]["seconds"] as? Double, 2.5)
        XCTAssertEqual(rows[0]["sessions"] as? Int, 1)
        XCTAssertEqual(rows[1]["name"] as? String, "Zeta")
        XCTAssertEqual(rows[1]["seconds"] as? Double, 10)
        XCTAssertEqual(rows[1]["sessions"] as? Int, 1)
        XCTAssertNil(rows[0]["bucketStart"])
        XCTAssertNil(rows[0]["bucketEnd"])
    }

    func testHourGroupingMergesBucketsPerAppAndSortsStably() {
        let sessions = [
            session(
                bundleID: "com.z",
                name: "Zeta",
                start: 30 * 60,
                end: 90 * 60,
                seconds: 3_600
            ),
            session(
                bundleID: "com.a",
                name: "Alpha",
                start: 45 * 60,
                end: 75 * 60,
                seconds: 1_800
            )
        ]

        let rows = ActivityQuery.summary(
            sessions: sessions,
            from: baseDate,
            to: baseDate.addingTimeInterval(2 * 3_600),
            groupBy: "hour",
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(
            rows.map { $0["bundleID"] as? String },
            ["com.a", "com.z", "com.a", "com.z"]
        )
        XCTAssertEqual(rows[0]["seconds"] as? Double, 900)
        XCTAssertEqual(rows[1]["seconds"] as? Double, 1_800)
        XCTAssertEqual(rows[2]["seconds"] as? Double, 900)
        XCTAssertEqual(rows[3]["seconds"] as? Double, 1_800)
        XCTAssertEqual(rows[0]["name"] as? String, "Alpha")
        XCTAssertEqual(rows[0]["sessions"] as? Int, 1)
        XCTAssertEqual(rows[1]["bucketStart"] as? Int, 1_699_999_200)
        XCTAssertEqual(rows[1]["bucketEnd"] as? Int, 1_700_002_800)
        XCTAssertEqual(rows[2]["bucketStart"] as? Int, 1_700_002_800)
        XCTAssertEqual(rows[2]["bucketEnd"] as? Int, 1_700_006_400)
    }

    func testHourBucketsFollowDSTCalendarBoundaries() {
        let calendar = newYorkCalendar()
        let start = date(2026, 3, 8, 1, 30, calendar: calendar)
        let end = date(2026, 3, 8, 3, 30, calendar: calendar)
        let sessions = [
            ActivitySession(
                id: UUID(),
                bundleID: "com.example",
                appName: "Example",
                start: start,
                end: end,
                seconds: 3_600,
                endReason: .checkpoint
            )
        ]

        let rows = ActivityQuery.summary(
            sessions: sessions,
            from: start,
            to: end,
            groupBy: "hour",
            timeZone: calendar.timeZone
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0["seconds"] as? Double }, [1_800, 1_800])

        let firstStart = Date(timeIntervalSince1970: TimeInterval(rows[0]["bucketStart"] as! Int))
        let firstEnd = Date(timeIntervalSince1970: TimeInterval(rows[0]["bucketEnd"] as! Int))
        let secondStart = Date(timeIntervalSince1970: TimeInterval(rows[1]["bucketStart"] as! Int))
        let secondEnd = Date(timeIntervalSince1970: TimeInterval(rows[1]["bucketEnd"] as! Int))

        XCTAssertEqual(firstStart, calendar.dateInterval(of: .hour, for: start)!.start)
        XCTAssertEqual(firstEnd, secondStart)
        XCTAssertEqual(secondStart, calendar.dateInterval(of: .hour, for: end)!.start)
        XCTAssertEqual(secondEnd.timeIntervalSince(secondStart), 3_600)
        XCTAssertEqual(firstEnd.timeIntervalSince(firstStart), 3_600)
    }

    func testHourBucketsKeepBothRepeatedHoursAtFallBack() {
        let calendar = newYorkCalendar()
        let firstHalfHour = date(2026, 11, 1, 1, 30, calendar: calendar)
        let secondHalfHour = firstHalfHour.addingTimeInterval(3_600)
        let end = secondHalfHour.addingTimeInterval(30 * 60)
        let sessions = [
            ActivitySession(
                id: UUID(),
                bundleID: "com.example",
                appName: "Example",
                start: firstHalfHour,
                end: end,
                seconds: 3_600,
                endReason: .checkpoint
            )
        ]

        let rows = ActivityQuery.summary(
            sessions: sessions,
            from: firstHalfHour,
            to: end,
            groupBy: "hour",
            timeZone: calendar.timeZone
        )

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["seconds"] as? Double, 1_200)
        XCTAssertEqual(rows[1]["seconds"] as? Double, 2_400)
        XCTAssertLessThan(
            rows[0]["bucketStart"] as! Int,
            rows[1]["bucketStart"] as! Int
        )
        XCTAssertEqual(
            rows[0]["bucketEnd"] as? Int,
            rows[1]["bucketStart"] as? Int
        )
    }

    func testDayAndMonthGroupingUseCalendarBoundaries() {
        let calendar = newYorkCalendar()
        let februaryEnd = date(2026, 2, 28, 12, 0, calendar: calendar)
        let marchEnd = date(2026, 3, 2, 12, 0, calendar: calendar)
        let sessions = [
            ActivitySession(
                id: UUID(),
                bundleID: "com.example",
                appName: "Example",
                start: februaryEnd,
                end: marchEnd,
                seconds: marchEnd.timeIntervalSince(februaryEnd),
                endReason: .checkpoint
            )
        ]

        let days = ActivityQuery.summary(
            sessions: sessions,
            from: februaryEnd,
            to: marchEnd,
            groupBy: "day",
            timeZone: calendar.timeZone
        )
        let months = ActivityQuery.summary(
            sessions: sessions,
            from: februaryEnd,
            to: marchEnd,
            groupBy: "month",
            timeZone: calendar.timeZone
        )

        XCTAssertEqual(
            days.compactMap { $0["bucketStart"] as? Int },
            days.compactMap { $0["bucketStart"] as? Int }.sorted()
        )
        XCTAssertTrue(days.allSatisfy { row in
            let start = Date(timeIntervalSince1970: TimeInterval(row["bucketStart"] as! Int))
            let end = Date(timeIntervalSince1970: TimeInterval(row["bucketEnd"] as! Int))
            return calendar.dateInterval(of: .day, for: start)?.start == start
                && calendar.dateInterval(of: .day, for: start)?.end == end
        })
        XCTAssertEqual(months.count, 2)
        XCTAssertEqual(months[0]["name"] as? String, "Example")
        XCTAssertEqual(months[1]["name"] as? String, "Example")
    }
}
