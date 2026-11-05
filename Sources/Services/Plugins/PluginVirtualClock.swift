import Foundation

/// 预览用的确定性时间源：虚拟毫秒时钟、可复现随机数与显式推进的定时器。
/// 仅在注入 `PluginRuntime` 时启用；正式宿主默认不创建，仍使用系统时间与 `DispatchQueue`。
/// 所有成员只能在所属 Runtime 的串行队列上访问（与 `PluginRuntime` 同样的 `@unchecked Sendable` 约定）。
final class PluginVirtualClock: @unchecked Sendable {
    /// 单次推进最多触发的定时器回调数，防止回调自我重排造成无界循环。
    static let maxFiresPerAdvance = 10_000
    static let maxTimers = 32

    private struct Entry {
        let id: Int
        let due: Double
        let sequence: Int
        let fire: () -> Void
    }

    private(set) var nowMilliseconds: Double
    private var randomState: UInt32
    private var entries: [Int: Entry] = [:]
    private var nextID = 1
    private var nextSequence = 0

    init(startMilliseconds: Double, seed: UInt32) {
        self.nowMilliseconds = startMilliseconds
        self.randomState = seed
    }

    var pendingTimerCount: Int { entries.count }

    /// 返回 0 表示超出定时器上限，与系统定时器路径一致。
    func schedule(afterMilliseconds delay: Double, fire: @escaping () -> Void) -> Int {
        guard entries.count < Self.maxTimers else { return 0 }
        let id = nextID
        nextID += 1
        let safeDelay = max(0, delay.isFinite ? delay : 0)
        entries[id] = Entry(id: id, due: nowMilliseconds + safeDelay, sequence: nextSequence, fire: fire)
        nextSequence += 1
        return id
    }

    func cancel(_ id: Int) {
        entries.removeValue(forKey: id)
    }

    func cancelAll() {
        entries.removeAll()
    }

    /// 按到期时间、再按创建顺序依次触发；回调内新建的定时器若仍在窗口内也会触发。
    /// 返回实际触发数；超过上限时停止并返回 `nil`，时钟停在已处理到的时刻。
    @discardableResult
    func advance(byMilliseconds delta: Double) -> Int? {
        let target = nowMilliseconds + max(0, delta.isFinite ? delta : 0)
        var fired = 0
        while let next = entries.values
            .filter({ $0.due <= target })
            .min(by: { ($0.due, $0.sequence) < ($1.due, $1.sequence) }) {
            guard fired < Self.maxFiresPerAdvance else { return nil }
            entries.removeValue(forKey: next.id)
            nowMilliseconds = max(nowMilliseconds, next.due)
            fired += 1
            next.fire()
        }
        nowMilliseconds = target
        return fired
    }

    /// mulberry32：相同种子得到相同序列，范围 [0, 1)。
    func nextRandom() -> Double {
        randomState = randomState &+ 0x6D2B79F5
        var t = randomState
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296.0
    }
}
