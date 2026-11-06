import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 无参数启动器窗口：左栏控制区 + 右栏模拟 Dock 工作台舞台。
///
/// 工作台默认使用舞台背景；玻璃检查时只清空右栏底色，让实时桌面透射。
/// 左栏保持不透明面板背景。窗口宽度小于 900 pt 时纵向堆叠（控制区在上）。
struct PreviewLauncherView: View {
    @ObservedObject var model: PreviewLauncherModel
    @ObservedObject var state: PluginPreviewState
    @State private var isDropTarget = false

    /// 低于该宽度改为一列：契约 §3.3 的纵向堆叠阈值。
    static let stackedWidthThreshold = PreviewLauncherLayout.stackedWidthThreshold

    /// 仅用于离屏渲染/测试注入浮层状态；正常启动为 nil。
    private let hoverController: PreviewDockHoverController?
    /// 最右侧调试面板的数据；nil（离屏渲染、测试）时不显示面板与入口。
    private let debug: PreviewDebugModel?

    init(model: PreviewLauncherModel,
         state: PluginPreviewState,
         hoverController: PreviewDockHoverController? = nil,
         debug: PreviewDebugModel? = nil) {
        self.model = model
        self.state = state
        self.hoverController = hoverController
        self.debug = debug
    }

    var body: some View {
        HStack(spacing: 0) {
            layout
            if let debug { DebugPanelHost(model: debug) }
        }
        .overlay(alignment: .topTrailing) {
            if let debug {
                DebugToggleHost(model: debug)
                    .padding(.top, 104)
                    .padding(.trailing, DesignTokens.Spacing.md)
            }
        }
    }

    private var layout: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.width < Self.stackedWidthThreshold {
                    VStack(spacing: 0) {
                        sidebar
                        // 堆叠时给模拟 Dock 留出足够上方空间，浮层才能完整落在右栏内；
                        // 控制区仍可滚动，窗口变高时优先扩大左侧。
                        rightColumn
                            .frame(height: min(max(proxy.size.height * 0.68, 360),
                                               max(proxy.size.height - 170, 240)))
                    }
                } else {
                    HStack(spacing: 0) {
                        sidebar
                            .frame(width: sidebarWidth(for: proxy.size.width))
                        rightColumn
                    }
                }
            }
        }
        .background(Color.clear)
        .preferredColorScheme(preferredScheme)
        .environment(\.locale, Locale(identifier: model.uiLanguage.rawValue))
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { handleDrop($0) }
    }

    private var sidebar: some View {
        PreviewLauncherSidebarView(model: model, state: state, isDropTarget: isDropTarget)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rightColumn: some View {
        PreviewLauncherStageView(model: model, state: state, hoverController: hoverController)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
    }

    /// 控制区约占 34%，并保证舞台至少 460 pt；堆叠阈值以下不调用。
    private func sidebarWidth(for totalWidth: CGFloat) -> CGFloat {
        PreviewLauncherLayout.controlWidth(for: totalWidth)
    }

    private var preferredScheme: ColorScheme? {
        switch model.displayedDraft?.appearance {
        case .dark: return .dark
        case .light: return .light
        case nil: return nil
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var candidate: URL?
            if let data = item as? Data {
                candidate = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                candidate = url
            }
            guard let url = candidate else { return }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }
            Task { @MainActor in model.openPlugin(url) }
        }
        return true
    }
}

/// 右栏工作台舞台：标题、实时桌面检查入口、中心提示与模拟 Dock 共用一层背景。
private struct PreviewLauncherStageView: View {
    @ObservedObject var model: PreviewLauncherModel
    @ObservedObject var state: PluginPreviewState
    let hoverController: PreviewDockHoverController?

    var body: some View {
        ZStack {
            if model.showsRawDesktop {
                Color.clear
            } else {
                PreviewLauncherStageBackdrop()
            }

            VStack(spacing: 0) {
                header
                if !model.showsRawDesktop {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.55))
                        .frame(height: DesignTokens.hairline)
                }
                stage
            }
        }
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(t("Plugin workbench")))
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t("Plugin workbench"))
                    .font(.title3.weight(.semibold))
                Text(headerDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 7)
            .background(headerTextBackground)

            Spacer(minLength: DesignTokens.Spacing.sm)

            Toggle(isOn: $model.showsRawDesktop) {
                Label(t("Raw desktop"), systemImage: "rectangle.on.rectangle")
                    .font(.callout.weight(.medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(t("Show the live desktop behind the workbench to inspect glass."))
            .accessibilityLabel(Text(t("Raw desktop")))
        }
        .padding(.leading, DesignTokens.Spacing.lg)
        .padding(.trailing, DesignTokens.Spacing.md)
        .padding(.top, PreviewLauncherLayout.windowTitlebarInset)
        .padding(.bottom, DesignTokens.Spacing.sm)
        .background(model.showsRawDesktop ? Color.clear : Color(nsColor: .windowBackgroundColor).opacity(0.30))
    }

    private var stage: some View {
        ZStack {
            stageHint
            PreviewMockDockView(model: model, state: state, hoverController: hoverController)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var stageHint: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: model.hasPlugin ? "square.stack.3d.up" : "puzzlepiece.extension")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(Color.accentColor.opacity(0.78))
                .accessibilityHidden(true)
            Text(t(model.hasPlugin ? "Hover the target app icon to open its Dock panel." : "Choose a plugin to begin"))
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, DesignTokens.Spacing.xl)
        .offset(y: -44)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var headerDetail: String {
        if model.showsRawDesktop {
            return t("Live desktop transmission for glass inspection")
        }
        guard model.hasPlugin else { return t("Simulated Dock and plugin stage") }
        let target = model.displayedDraft?.target.appName ?? ""
        return target.isEmpty
            ? t("Simulated Dock and plugin stage")
            : "\(t("Simulated Dock")) · \(target)"
    }

    private var headerTextBackground: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.chip, style: .continuous)
            .fill(model.showsRawDesktop
                  ? Color(nsColor: .windowBackgroundColor).opacity(0.68)
                  : Color.clear)
    }

    private func t(_ key: String) -> String { model.t(key) }
}

/// 舞台默认背景：语义底色、中心柔光与低对比点阵，避免右栏在普通模式下看起来是空白窗口。
private struct PreviewLauncherStageBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor).opacity(0.96),
                    Color(nsColor: .underPageBackgroundColor).opacity(0.92),
                    Color(nsColor: .controlBackgroundColor).opacity(0.82),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            GeometryReader { proxy in
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: min(proxy.size.width, proxy.size.height) * 0.68)
                    .blur(radius: 72)
                    .position(x: proxy.size.width * 0.53, y: proxy.size.height * 0.42)
            }

            Canvas { context, size in
                let step: CGFloat = 28
                let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 1.5, height: 1.5))
                var y: CGFloat = 0
                while y <= size.height {
                    var x: CGFloat = 0
                    while x <= size.width {
                        context.fill(dot.offsetBy(dx: x, dy: y),
                                     with: .color(Color(nsColor: .separatorColor).opacity(0.22)))
                        x += step
                    }
                    y += step
                }
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.65))
                .frame(width: DesignTokens.hairline)
        }
        .ignoresSafeArea()
    }
}

/// 面板随 `isVisible` 出现；单独成视图，让 `PreviewLauncherView` 不必观察调试模型。
private struct DebugPanelHost: View {
    @ObservedObject var model: PreviewDebugModel
    var body: some View {
        if model.isVisible { PreviewDebugPanelView(model: model) }
    }
}

private struct DebugToggleHost: View {
    @ObservedObject var model: PreviewDebugModel
    var body: some View {
        if !model.isVisible { PreviewDebugToggleButton(model: model) }
    }
}
