import Foundation

enum ActivityQuery {
    static func summary(
        sessions: [ActivitySession],
        from: Date,
        to: Date,
        groupBy: String,
        timeZone: TimeZone
    ) -> [[String: Any]] {
        guard from < to, let grouping = Grouping(rawValue: groupBy) else {
            return []
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        var aggregates: [AggregateKey: Aggregate] = [:]
        for session in sessions {
            let sessionStart = session.start
            let sessionEnd = session.end
            guard sessionStart < sessionEnd else { continue }
            let clippedStart = maxDate(from, sessionStart)
            let clippedEnd = minDate(to, sessionEnd)
            guard clippedStart < clippedEnd else { continue }

            let wallSeconds = sessionEnd.timeIntervalSince(sessionStart)
            guard wallSeconds.isFinite, wallSeconds > 0 else { continue }
            let sessionSeconds = session.seconds.isFinite
                ? max(0, session.seconds)
                : 0

            if grouping == .app {
                add(
                    session: session,
                    from: clippedStart,
                    to: clippedEnd,
                    allocatedSeconds: sessionSeconds
                        * clippedEnd.timeIntervalSince(clippedStart) / wallSeconds,
                    key: AggregateKey(bundleID: session.bundleID),
                    to: &aggregates
                )
                continue
            }

            var cursor = clippedStart
            while cursor < clippedEnd {
                guard let interval = calendar.dateInterval(
                    of: grouping.calendarComponent,
                    for: cursor
                ),
                      interval.end > cursor else {
                    break
                }
                let sliceEnd = minDate(interval.end, clippedEnd)
                add(
                    session: session,
                    from: cursor,
                    to: sliceEnd,
                    allocatedSeconds: sessionSeconds
                        * sliceEnd.timeIntervalSince(cursor) / wallSeconds,
                    key: AggregateKey(
                        bucketStart: interval.start,
                        bucketEnd: interval.end,
                        bundleID: session.bundleID
                    ),
                    to: &aggregates
                )
                cursor = sliceEnd
            }
        }

        return aggregates.map { key, aggregate in
            var row: [String: Any] = [
                "bundleID": key.bundleID,
                "name": aggregate.name,
                "seconds": aggregate.seconds,
                "sessions": aggregate.sessions
            ]
            if let bucketStart = key.bucketStart,
               let bucketEnd = key.bucketEnd {
                row["bucketStart"] = Int(bucketStart.timeIntervalSince1970)
                row["bucketEnd"] = Int(bucketEnd.timeIntervalSince1970)
            }
            return (key: key, row: row)
        }
        .sorted { lhs, rhs in
            let lhsStart = lhs.key.bucketStart ?? .distantPast
            let rhsStart = rhs.key.bucketStart ?? .distantPast
            if lhsStart != rhsStart {
                return lhsStart < rhsStart
            }
            if lhs.key.bundleID != rhs.key.bundleID {
                return lhs.key.bundleID < rhs.key.bundleID
            }
            return lhs.row["name"] as? String ?? "" < rhs.row["name"] as? String ?? ""
        }
        .map(\.row)
    }

    private enum Grouping: String {
        case app
        case hour
        case day
        case month

        var calendarComponent: Calendar.Component {
            switch self {
            case .app:
                return .day
            case .hour:
                return .hour
            case .day:
                return .day
            case .month:
                return .month
            }
        }
    }

    private struct AggregateKey: Hashable {
        let bucketStart: Date?
        let bucketEnd: Date?
        let bundleID: String

        init(
            bucketStart: Date? = nil,
            bucketEnd: Date? = nil,
            bundleID: String
        ) {
            self.bucketStart = bucketStart
            self.bucketEnd = bucketEnd
            self.bundleID = bundleID
        }
    }

    private struct Aggregate {
        var name: String
        var seconds: Double
        var sessions: Int
        var latestStart: Date
    }

    private static func add(
        session: ActivitySession,
        from: Date,
        to: Date,
        allocatedSeconds: Double,
        key: AggregateKey,
        to aggregates: inout [AggregateKey: Aggregate]
    ) {
        guard from < to, allocatedSeconds.isFinite else { return }

        if var aggregate = aggregates[key] {
            aggregate.seconds += allocatedSeconds
            aggregate.sessions += 1
            if session.start > aggregate.latestStart
                || (session.start == aggregate.latestStart
                    && session.appName < aggregate.name) {
                aggregate.name = session.appName
                aggregate.latestStart = session.start
            }
            aggregates[key] = aggregate
        } else {
            aggregates[key] = Aggregate(
                name: session.appName,
                seconds: allocatedSeconds,
                sessions: 1,
                latestStart: session.start
            )
        }
    }

    private static func maxDate(_ lhs: Date, _ rhs: Date) -> Date {
        lhs >= rhs ? lhs : rhs
    }

    private static func minDate(_ lhs: Date, _ rhs: Date) -> Date {
        lhs <= rhs ? lhs : rhs
    }
}
