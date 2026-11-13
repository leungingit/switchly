import Foundation

struct ActivityConsentState {
    enum Intent: String { case recording, screenshots, clear }
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let intent: Intent
    }

    static let requiredClearText = "CLEAR"
    private(set) var request: Request?
    var clearText = ""
    var canClear: Bool { request?.intent == .clear && clearText == Self.requiredClearText }

    mutating func present(_ intent: Intent) {
        guard request == nil else { return }
        clearText = ""
        request = Request(intent: intent)
    }
    mutating func cancel() {
        request = nil
        clearText = ""
    }
    mutating func consume(_ expected: Request) -> Intent? {
        guard request == expected, expected.intent != .clear || canClear else { return nil }
        cancel()
        return expected.intent
    }
}
