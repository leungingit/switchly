import AppKit

/// 聚焦失败时不弹模态框（会锁住菜单栏与 Dock 预览），只写一条醒目日志，不把应用激活误报成切窗成功。
enum WindowSwitchFeedback {
    static func logFailure(source: String, window: WindowInfo? = nil) {
        let target = window.map { " pid=\($0.ownerPID) windowID=\($0.id)" } ?? ""
        AppLogger.error("!!!!! WINDOW FOCUS FAILED !!!!! source=\(source)\(target) action=ignored")
    }
}
