import Foundation

struct ActivityMutation {
    var sessions: [ActivitySession] = []
    var truncateAfter: Date?
}

struct ActivityTrackingMachine {
    private static let idleTimeout: TimeInterval = 5 * 60
    private static let wallClockTolerance: TimeInterval = 5

    private(set) var current: ActivitySession?
    private var sessionStartUptime: TimeInterval = 0
    private var observedAt: Date?
    private var observedUptime: TimeInterval = 0
    private var idleEpisodeReported = false
    private var closedThrough: Date?

    mutating func update(
        app: ActivityApp?,
        at: Date,
        uptime: TimeInterval,
        idleSeconds: TimeInterval,
        blockers: Set<ActivityBlocker>,
        enabled: Bool
    ) -> ActivityMutation {
        let monotonicUptime = normalized(uptime, fallback: observedUptime)
        let monotonicIdle = normalized(idleSeconds, fallback: 0)
        let uptimeDelta = max(0, monotonicUptime - observedUptime)
        let wallDelta = observedAt.map { at.timeIntervalSince($0) } ?? uptimeDelta
        let clockChanged = current != nil
            && observedAt != nil
            && (!wallDelta.isFinite
                || abs(wallDelta - uptimeDelta) >= Self.wallClockTolerance)
        if monotonicIdle < Self.idleTimeout {
            idleEpisodeReported = false
        }
        let safeWallEnd = safeWallEnd(
            at: at,
            uptimeDelta: uptimeDelta,
            monotonicUptime: monotonicUptime
        )

        var mutation = ActivityMutation()

        if let active = current {
            if !enabled {
                mutation.sessions.append(
                    close(active, reason: .disabled, end: safeWallEnd,
                          uptime: monotonicUptime)
                )
            } else if !blockers.isEmpty {
                mutation.sessions.append(
                    close(active, reason: .blocked, end: safeWallEnd,
                          uptime: monotonicUptime)
                )
            } else if app == nil {
                mutation.sessions.append(
                    close(active, reason: .terminated, end: safeWallEnd,
                          uptime: monotonicUptime)
                )
            } else if clockChanged {
                let end = clockSafeEnd(
                    from: observedAt,
                    uptimeDelta: uptimeDelta,
                    notBefore: active.start
                )
                mutation.sessions.append(
                    close(active, reason: .clockChanged, end: end,
                          uptime: monotonicUptime)
                )

                if let app, monotonicIdle < Self.idleTimeout {
                    mutation.sessions.append(
                        open(
                            app: app,
                            start: maxDate(at, closedThrough ?? at),
                            uptime: monotonicUptime
                        )
                    )
                } else if monotonicIdle >= Self.idleTimeout,
                          !idleEpisodeReported,
                          app != nil {
                    idleEpisodeReported = true
                    mutation.truncateAfter = lastInputAfter(
                        at: at,
                        idleSeconds: monotonicIdle
                    )
                }
            } else if monotonicIdle >= Self.idleTimeout {
                let lastInput = lastInputAfter(
                    at: at,
                    idleSeconds: monotonicIdle
                )
                let activeUptime = max(
                    sessionStartUptime,
                    monotonicUptime - monotonicIdle
                )
                mutation.sessions.append(
                    close(active, reason: .idle, end: maxDate(active.start, lastInput),
                          uptime: activeUptime)
                )
                idleEpisodeReported = true
                mutation.truncateAfter = lastInput
            } else {
                guard let app else {
                    return mutation
                }

                if app.bundleID != active.bundleID {
                    mutation.sessions.append(
                        close(active, reason: .switched, end: safeWallEnd,
                              uptime: monotonicUptime)
                    )
                    mutation.sessions.append(
                        open(
                            app: app,
                            start: maxDate(at, closedThrough ?? at),
                            uptime: monotonicUptime
                        )
                    )
                } else {
                    let checkpoint = checkpoint(
                        active,
                        end: maxDate(active.start, at),
                        uptime: monotonicUptime
                    )
                    current = checkpoint
                    closedThrough = maxDate(closedThrough ?? checkpoint.end, checkpoint.end)
                    mutation.sessions.append(checkpoint)
                }
            }
        } else if let app, enabled, blockers.isEmpty {
            if monotonicIdle >= Self.idleTimeout {
                if !idleEpisodeReported {
                    idleEpisodeReported = true
                    mutation.truncateAfter = lastInputAfter(
                        at: at,
                        idleSeconds: monotonicIdle
                    )
                }
            } else {
                mutation.sessions.append(
                    open(
                        app: app,
                        start: maxDate(at, closedThrough ?? at),
                        uptime: monotonicUptime
                    )
                )
            }
        }

        if current == nil,
           monotonicIdle >= Self.idleTimeout,
           !idleEpisodeReported {
            idleEpisodeReported = true
            mutation.truncateAfter = lastInputAfter(
                at: at,
                idleSeconds: monotonicIdle
            )
        }

        observedAt = at
        observedUptime = monotonicUptime
        return mutation
    }

    private mutating func open(
        app: ActivityApp,
        start: Date,
        uptime: TimeInterval
    ) -> ActivitySession {
        let sessionStart = maxDate(start, closedThrough ?? start)
        let session = ActivitySession(
            id: UUID(),
            bundleID: app.bundleID,
            appName: app.name,
            start: sessionStart,
            end: sessionStart,
            seconds: 0,
            endReason: .checkpoint
        )
        current = session
        sessionStartUptime = uptime
        closedThrough = maxDate(closedThrough ?? sessionStart, sessionStart)
        return session
    }

    private mutating func checkpoint(
        _ active: ActivitySession,
        end: Date,
        uptime: TimeInterval
    ) -> ActivitySession {
        ActivitySession(
            id: active.id,
            bundleID: active.bundleID,
            appName: active.appName,
            start: active.start,
            end: maxDate(active.start, end),
            seconds: elapsedSeconds(until: uptime),
            endReason: .checkpoint
        )
    }

    private mutating func close(
        _ active: ActivitySession,
        reason: ActivityEndReason,
        end: Date,
        uptime: TimeInterval
    ) -> ActivitySession {
        let closed = ActivitySession(
            id: active.id,
            bundleID: active.bundleID,
            appName: active.appName,
            start: active.start,
            end: maxDate(active.start, end),
            seconds: elapsedSeconds(until: uptime),
            endReason: reason
        )
        current = nil
        closedThrough = maxDate(closedThrough ?? closed.end, closed.end)
        observedAt = closed.end
        return closed
    }

    private func elapsedSeconds(until uptime: TimeInterval) -> TimeInterval {
        max(0, uptime - sessionStartUptime)
    }

    private func safeWallEnd(
        at: Date,
        uptimeDelta: TimeInterval,
        monotonicUptime: TimeInterval
    ) -> Date {
        guard let observedAt else { return at }
        let expected = observedAt.addingTimeInterval(uptimeDelta)
        let wallEnd = minimumDate(at, expected)
        return maxDate(current?.start ?? wallEnd, wallEnd)
    }

    private func clockSafeEnd(
        from observedAt: Date?,
        uptimeDelta: TimeInterval,
        notBefore start: Date
    ) -> Date {
        guard let observedAt else { return start }
        return maxDate(start, observedAt.addingTimeInterval(uptimeDelta))
    }

    private func lastInputAfter(
        at: Date,
        idleSeconds: TimeInterval
    ) -> Date {
        at.addingTimeInterval(-idleSeconds)
    }

    private func normalized(
        _ value: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else { return fallback }
        return max(0, value)
    }

    private func maxDate(_ lhs: Date, _ rhs: Date) -> Date {
        lhs >= rhs ? lhs : rhs
    }

    private func minimumDate(_ lhs: Date, _ rhs: Date) -> Date {
        lhs <= rhs ? lhs : rhs
    }
}
