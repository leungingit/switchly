import Combine
import Foundation

/// 模拟 Dock 的悬停驱动：把纯状态机 `PreviewDockHoverState` 接到主线程一次性计时上。
///
/// 只安排 `nextDeadline` 时刻的一次唤醒，不做轮询；每次状态变化都会取消旧计时。
/// 视图必须在消失、目标应用变化或窗口关闭时调用 `cancel()`，避免浮层在后台继续计时。
@MainActor
final class PreviewDockHoverController: ObservableObject {
    @Published private(set) var state = PreviewDockHoverState()

    private var pending: DispatchWorkItem?
    private let now: () -> TimeInterval

    init(initialState: PreviewDockHoverState = PreviewDockHoverState(),
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.state = initialState
        self.now = now
    }

    var isVisible: Bool { state.isVisible }
    var visibleIconID: String? { state.visibleIconID }

    func hoverEnter(iconID: String, isTrigger: Bool) {
        mutate { $0.hoverEnter(iconID: iconID, isTrigger: isTrigger, now: now()) }
    }

    func hoverExit(iconID: String) {
        mutate { $0.hoverExit(iconID: iconID, now: now()) }
    }

    func panelEnter() {
        mutate { $0.panelEnter(now: now()) }
    }

    func panelExit() {
        mutate { $0.panelExit(now: now()) }
    }

    /// 停止所有计时并复位。重复调用安全。
    func cancel() {
        pending?.cancel()
        pending = nil
        guard state != PreviewDockHoverState() else { return }
        state = PreviewDockHoverState()
    }

    private func mutate(_ change: (inout PreviewDockHoverState) -> Void) {
        var next = state
        change(&next)
        if next != state {
            state = next
        }
        scheduleTick()
    }

    private func scheduleTick() {
        pending?.cancel()
        pending = nil
        guard let deadline = state.nextDeadline else { return }
        let delay = max(deadline - now(), 0)
        let item = DispatchWorkItem { [weak self] in
            self?.tick()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func tick() {
        pending = nil
        var next = state
        next.tick(now: now())
        if next != state {
            state = next
        }
        scheduleTick()
    }
}
