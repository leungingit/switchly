import SwiftUI

/// 模拟 Dock 浮层的可调项：与本体「偏好设置」里 Dock 预览/玻璃外观同名同范围，
/// 默认值取 `AppSettings.default`，因此未调整时与本体出厂外观一致。
///
/// 只影响启动器右栏的展示：不进入场景文件、不导出、不影响 `run`/`dev` 的截图与基线。
struct PreviewMockDockOptions: Equatable {
    /// 本体窗口卡片宽度的可选范围（点）。
    static let cardWidthRange: ClosedRange<Double> = 100...320

    var windowCount = PreviewMockWindows.defaultWindowCount
    var layout: DockPreviewLayout = AppSettings.default.dockPreviewLayout
    var cardWidth: Double = AppSettings.default.dockPreviewCardWidth
    /// nil 跟随场景的 glass 开关；默认场景 glass 关闭，其下的玻璃项要先在这里打开才看得到效果。
    var glassEnabled: Bool?
    /// 材质（清透/磨砂）。
    var glassStyle: GlassStyle = AppSettings.default.crystalMaterial.glassStyle == .opaque
        ? .frosted : AppSettings.default.crystalMaterial.glassStyle
    /// nil 保持本体默认（按设置里的旧密度），与本体「玻璃密度」滑块语义一致。
    var density: Double?
    var tintColor: Color = AppSettings.default.crystalMaterial.tintColor
    var tintStrength: Double = AppSettings.default.crystalMaterial.panelTintCap
    /// nil 跟随系统卡片底色。
    var windowCardBackdrop: WindowCardBackdrop = .followingSystem

    /// 在场景环境给出的材质上叠加这里的覆盖项。
    func material(base: CrystalMaterial) -> CrystalMaterial {
        var material = base
        material.glassStyle = glassStyle
        material.sharedDensity = density
        material.tintColor = tintColor
        material.panelTintCap = tintStrength
        return material.clamped()
    }
}
