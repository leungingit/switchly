import AppKit
import Combine

enum PluginPreviewStatus: String, Equatable {
    case idle
    case rendering
    case ready
    case stale
    case failed

    var localizationKey: String {
        switch self {
        case .idle: return "Waiting for a plugin render"
        case .rendering: return "Rendering"
        case .ready: return "Ready"
        case .stale: return "Stale render"
        case .failed: return "Failed"
        }
    }
}

enum PluginPreviewDiagnosticLevel: String, Equatable {
    case info
    case warning
    case error

    var localizationKey: String {
        switch self {
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }
}

struct PluginPreviewDiagnostic: Identifiable, Equatable {
    let id: String
    let level: PluginPreviewDiagnosticLevel
    let message: String

    init(id: String = UUID().uuidString, level: PluginPreviewDiagnosticLevel, message: String) {
        self.id = id
        self.level = level
        self.message = message
    }
}

struct PluginPreviewEnvironment: Equatable {
    /// 与覆盖项/草稿共用同一范围，避免参数校验与 GUI 出现两套常量。
    static let minimumContentWidth = CGFloat(PreviewScenarioDraft.contentWidthRange.lowerBound)
    static let maximumContentWidth = CGFloat(PreviewScenarioDraft.contentWidthRange.upperBound)

    var theme: AppTheme = .dark
    var language: AppLanguage = .simplifiedChinese
    var glassEnabled = true
    var contentWidth: CGFloat = 420
    var material: CrystalMaterial = .legacyDefault
}

/// State and action boundary injected by the preview session controller. The
/// view owns no Runtime, worker process or host service; it only renders the
/// published generation and forwards native actions through these closures.
@MainActor
final class PluginPreviewState: ObservableObject {
    @Published var pluginID = ""
    @Published var pluginVersion = ""
    @Published var renderScope: PluginRenderScope = .app
    @Published var generation = 0
    @Published var status: PluginPreviewStatus = .idle
    @Published var slots: [PluginSlot: [PluginSlotSurface.Entry]] = [:]
    @Published var artwork: NSImage?
    @Published var diagnostics: [PluginPreviewDiagnostic] = []
    @Published var environment = PluginPreviewEnvironment()
    /// 场景声明 `clock` 时的虚拟当前时刻（Unix 秒），供 Scene 绘制；nil 表示使用系统时间。
    @Published var virtualNowSeconds: Double?

    var capturedSlots: [PluginSlot] {
        if slots[.panel] != nil { return [.panel] }
        return renderScope == .window ? [.titleAccessory, .topTrailing, .bottomBar] : [.center, .bottomBar]
    }

    var reloadHandler: (() -> Void)?
    var resetHandler: (() -> Void)?
    var actionHandler: ((_ pluginID: String, _ actionID: String, _ value: Double?) -> Void)?

    func perform(pluginID: String, actionID: String, value: Double?) {
        actionHandler?(pluginID, actionID, value)
    }

    func reload() {
        reloadHandler?()
    }

    func reset() {
        resetHandler?()
    }
}
