import Foundation

/// 启动器纯逻辑回归：最近列表去重/上限与防抖取消。
enum LauncherLogicTests {
    @MainActor
    static func run() async {
        recentList()
        controlWidthKeepsStageUsable()
        await debouncerCollapsesSchedules()
        await debouncerCancelDropsAction()
        print("GUI 启动器逻辑测试通过")
    }

    private static func controlWidthKeepsStageUsable() {
        precondition(PreviewLauncherLayout.controlWidth(for: 900) == 340)
        precondition(abs(PreviewLauncherLayout.controlWidth(for: 1_080) - 367.2) < 0.001)
        precondition(PreviewLauncherLayout.controlWidth(for: 1_400) == 380)
        precondition(PreviewLauncherLayout.controlWidth(for: 900) + PreviewLauncherLayout.minimumStageWidth <= 900)
    }

    private static func recentList() {
        let a = URL(fileURLWithPath: "/tmp/plugin-a", isDirectory: true)
        let b = URL(fileURLWithPath: "/tmp/plugin-b", isDirectory: true)
        let c = URL(fileURLWithPath: "/tmp/plugin-c", isDirectory: true)

        precondition(PreviewRecentPluginList.adding(a, to: []) == [a])
        precondition(PreviewRecentPluginList.adding(c, to: [a, b]) == [c, a, b])
        // 重复选择会置顶而不是再插一条。
        precondition(PreviewRecentPluginList.adding(b, to: [a, b, c]) == [b, a, c])

        let many = (0..<12).map { URL(fileURLWithPath: "/tmp/p\($0)", isDirectory: true) }
        var accumulated: [URL] = []
        for url in many {
            accumulated = PreviewRecentPluginList.adding(url, to: accumulated)
        }
        precondition(accumulated.count == PreviewRecentPluginList.maximumCount)
        precondition(accumulated.first == many.last)
        precondition(accumulated.last == many[4])

        let encoded = PreviewRecentPluginList.encoding(accumulated)
        precondition(PreviewRecentPluginList.decoding(encoded) == accumulated)
        // 损坏/重复路径被再次去重并截断。
        precondition(PreviewRecentPluginList.decoding(["/tmp/p1", "/tmp/p1", "", "/tmp/p2"]) ==
            [URL(fileURLWithPath: "/tmp/p1", isDirectory: true),
             URL(fileURLWithPath: "/tmp/p2", isDirectory: true)])
        precondition(PreviewRecentPluginList.decoding(Array(repeating: "/tmp/p3", count: 12)).count == 1)
    }

    @MainActor
    private static func debouncerCollapsesSchedules() async {
        var count = 0
        let debouncer = PreviewRenderDebouncer(delayNanoseconds: 0) { count += 1 }
        debouncer.schedule()
        debouncer.schedule()
        debouncer.schedule()
        await debouncer.waitUntilFinished()
        precondition(count == 1, "only the latest schedule should render, got \(count)")
    }

    @MainActor
    private static func debouncerCancelDropsAction() async {
        var count = 0
        let debouncer = PreviewRenderDebouncer(delayNanoseconds: 0) { count += 1 }
        debouncer.schedule()
        debouncer.cancel()
        await debouncer.waitUntilFinished()
        precondition(count == 0, "a cancelled schedule must not render, got \(count)")
    }
}
