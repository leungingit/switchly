import CoreGraphics
import Foundation

/// Limits physical work independently of the caller's timeout or cancellation.
final class WindowCaptureWorkPool: @unchecked Sendable {
    static let shared = WindowCaptureWorkPool()
    private let lock = NSLock()
    private let limit: Int
    private var active = 0
    private static let deadlines = DispatchQueue(label: "com.switchly.capture-deadlines", attributes: .concurrent)

    init(limit: Int = 6) { self.limit = max(1, limit) }

    func run(timeout: TimeInterval,
             start: @escaping (@escaping (Result<CGImage, Error>) -> Void) -> Void) async throws -> CGImage {
        try await runCancellable(timeout: timeout) { _, done in start(done) }
    }

    /// Multi-stage system work checks this predicate before starting its next stage.
    func runCancellable(timeout: TimeInterval,
                        start: @escaping (@escaping () -> Bool, @escaping (Result<CGImage, Error>) -> Void) -> Void) async throws -> CGImage {
        let job = Job(pool: self)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                job.launch(continuation, timeout: timeout) { done in start({ job.isActive }, done) }
            }
        }, onCancel: { job.deliver(.failure(CancellationError())) })
    }

    private func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active < limit else { return false }
        active += 1; return true
    }

    private func release() { lock.lock(); active -= 1; lock.unlock() }

    private final class Job: @unchecked Sendable {
        let pool: WindowCaptureWorkPool
        let lock = NSLock()
        var continuation: CheckedContinuation<CGImage, Error>?
        var result: Result<CGImage, Error>?
        var physicallyFinished = false
        var timer: DispatchWorkItem?
        init(pool: WindowCaptureWorkPool) { self.pool = pool }
        var isActive: Bool { lock.lock(); defer { lock.unlock() }; return result == nil }

        func launch(_ continuation: CheckedContinuation<CGImage, Error>, timeout: TimeInterval,
                    start: (@escaping (Result<CGImage, Error>) -> Void) -> Void) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result); return }
            self.continuation = continuation
            lock.unlock()
            guard timeout.isFinite, timeout > 0 else { deliver(.failure(WindowCaptureFailure.invalidRequest)); return }
            guard pool.claim() else { deliver(.failure(WindowCaptureFailure.busy)); return }
            lock.lock()
            if result != nil { lock.unlock(); pool.release(); return }
            let timer = DispatchWorkItem { [weak self] in self?.deliver(.failure(WindowCaptureFailure.timeout)) }
            self.timer = timer
            lock.unlock()
            WindowCaptureWorkPool.deadlines.asyncAfter(deadline: .now() + timeout, execute: timer)
            start { [self] outcome in
                lock.lock()
                guard !physicallyFinished else { lock.unlock(); return }
                physicallyFinished = true
                lock.unlock()
                pool.release()
                deliver(outcome)
            }
        }

        func deliver(_ result: Result<CGImage, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = continuation; self.continuation = nil
            let timer = timer; self.timer = nil
            lock.unlock()
            timer?.cancel()
            continuation?.resume(with: result)
        }
    }
}
