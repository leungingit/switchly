import AppKit

enum AXWindowEnumeration {
    case windows([AXUIElement])
    case failed(AXError)
    case invalidResponse

    var elements: [AXUIElement] {
        if case let .windows(elements) = self { return elements }
        return []
    }

    var succeeded: Bool {
        if case .windows = self { return true }
        return false
    }

    var diagnosticValue: String {
        switch self {
        case let .windows(elements): return "windows:\(elements.count)"
        case let .failed(error): return "error:\(error.rawValue)"
        case .invalidResponse: return "invalidResponse"
        }
    }
}

struct WindowFocusFailure {
    enum Stage: String {
        case axEnumerationFailed
        case targetNotFound
        case otherSpaceTargetNotFound
        case frontRequestFailed
        case focusVerificationFailed
    }

    enum RemoteLookup: String {
        case notRun
        case hit
        case miss
    }

    let stage: Stage
    let initialAX: String
    var fallbackAX = "notRun"
    var remoteLookup: RemoteLookup = .notRun
    var focusAttempts = 0

    var logFields: String {
        "stage=\(stage.rawValue), initialAX=\(initialAX), fallbackAX=\(fallbackAX), remoteLookup=\(remoteLookup.rawValue), focusAttempts=\(focusAttempts)"
    }
}

struct WindowFocusResolver {
    private static let maxFocusAttempts = 5

    let enumerate: (pid_t) -> AXWindowEnumeration
    let candidates: (WindowInfo, [AXUIElement]) -> [WindowFocusCandidate]
    let remoteWindow: (WindowInfo) -> AXUIElement?
    let requestFront: (WindowInfo) -> Bool
    let forgetRemoteWindow: (WindowInfo) -> Void
    let ensureFrontmost: (pid_t) -> Void
    let focus: (WindowFocusCandidate, WindowInfo) -> Bool
    let awaitLateFront: (WindowInfo) -> Bool

    func resolveAndFocus(_ window: WindowInfo) -> WindowFocusFailure? {
        let initial = enumerate(window.ownerPID)
        let candidates = candidates(window, initial.elements)
        if window.isOnOtherSpace {
            return focusOtherSpace(window, candidate: candidates.first, initial: initial)
        }
        AppLogger.info("Resolved focus candidates. windowID=\(window.id), count=\(candidates.count), order=\(candidates.map { $0.reason }.joined(separator: ","))")

        var tried: [AXUIElement] = []
        for candidate in candidates where !tried.contains(where: { CFEqual($0, candidate.element) }) {
            guard tried.count < Self.maxFocusAttempts else { break }
            tried.append(candidate.element)
            ensureFrontmost(window.ownerPID)
            if focus(candidate, window) { return nil }
            Thread.sleep(forTimeInterval: 0.04)
        }

        // Fallback: every window of the app we have not raised yet. Bounded, and
        // only reached when identification could not be trusted.
        let fallback = enumerate(window.ownerPID)
        let remaining = fallback.elements.filter { element in !tried.contains(where: { CFEqual($0, element) }) }
        if !remaining.isEmpty, tried.count < Self.maxFocusAttempts {
            AppLogger.info("Heuristic candidates did not match; probing remaining AX windows. windowID=\(window.id), remaining=\(remaining.count)")
        }
        for element in remaining {
            guard tried.count < Self.maxFocusAttempts else { break }
            tried.append(element)
            ensureFrontmost(window.ownerPID)
            if focus(WindowFocusCandidate(element: element, reason: "probe", needsUnminimize: false), window) {
                AppLogger.info("Focused window by probing AX windows. windowID=\(window.id), attempt=\(tried.count)")
                return nil
            }
        }
        if awaitLateFront(window) { return nil }

        let stage: WindowFocusFailure.Stage
        if tried.isEmpty {
            stage = fallback.succeeded ? .targetNotFound : .axEnumerationFailed
        } else {
            stage = .focusVerificationFailed
        }
        return WindowFocusFailure(
            stage: stage,
            initialAX: initial.diagnosticValue,
            fallbackAX: fallback.diagnosticValue,
            focusAttempts: tried.count
        )
    }

    private func focusOtherSpace(
        _ window: WindowInfo,
        candidate: WindowFocusCandidate?,
        initial: AXWindowEnumeration
    ) -> WindowFocusFailure? {
        let remote = candidate == nil ? remoteWindow(window) : nil
        let lookup: WindowFocusFailure.RemoteLookup = candidate != nil ? .notRun : (remote == nil ? .miss : .hit)
        guard let exact = candidate?.element ?? remote else {
            return WindowFocusFailure(
                stage: initial.succeeded ? .otherSpaceTargetNotFound : .axEnumerationFailed,
                initialAX: initial.diagnosticValue,
                remoteLookup: lookup
            )
        }
        guard requestFront(window) else {
            return WindowFocusFailure(stage: .frontRequestFailed, initialAX: initial.diagnosticValue, remoteLookup: lookup)
        }
        var attempts = 1
        if focus(WindowFocusCandidate(element: exact, reason: "exactOtherSpace", needsUnminimize: window.isMinimized), window) { return nil }
        if awaitLateFront(window) { return nil }

        // Re-sending the request alone comes first: activation jumps to the
        // app's last-active desktop, which is the flash this path avoids.
        for (reason, activate) in [("exactOtherSpaceRetry", false), ("exactOtherSpaceActivated", true)] {
            AppLogger.info("Other-space front request did not take; retrying. windowID=\(window.id), activate=\(activate)")
            if activate { ensureFrontmost(window.ownerPID) }
            if requestFront(window) {
                attempts += 1
                if focus(WindowFocusCandidate(element: exact, reason: reason, needsUnminimize: window.isMinimized), window) { return nil }
            }
            if awaitLateFront(window) { return nil }
        }
        forgetRemoteWindow(window)
        return WindowFocusFailure(
            stage: .focusVerificationFailed,
            initialAX: initial.diagnosticValue,
            remoteLookup: lookup,
            focusAttempts: attempts
        )
    }
}
