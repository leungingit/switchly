# 菜单栏图标主题污染修正与验收记录

日期：2026-11-13，Asia/Singapore。对应设计决策 MB-D01；未提交、推送或发布。

## 问题与根因

用户观察到跟随系统为白色线条，亮色为黑色线条，暗色为白色线条，与其他菜单栏图标不一致。设置的亮暗标签和 `AppTheme` 映射没有反置；缺陷在于 `ThemeApplier.apply` 遍历 `NSApp.windows`，将应用主题同时施加给系统管理的状态项窗口及其内容视图。仅使用模板图和清除 `contentTintColor` 无法阻止这个覆盖。

使用独立临时 AppKit 进程创建真实 `NSStatusItem`，只读取其外观、不读取活动数据或偏好设置。本机实测：

| 操作 | 状态窗口显式外观 | 按钮有效外观 |
| --- | --- | --- |
| 初始 | nil | NSAppearanceNameVibrantDark |
| 只设 NSApp 为亮色 | nil | NSAppearanceNameVibrantDark |
| 只设 NSApp 为暗色 | nil | NSAppearanceNameVibrantDark |
| 复现旧的全窗口暗色覆盖 | NSAppearanceNameDarkAqua | NSAppearanceNameDarkAqua |
| 清除窗口及内容视图覆盖 | nil | NSAppearanceNameVibrantDark |

状态窗口确实包含在 `NSApp.windows` 中；公开视图树中 `NSStatusBarButton` 在内容视图的第二层。以上是本机隔离验证结果，不代表所有显示器背景的颜色结果。

## 修正与回归

`ThemeApplier` 通过公开 `NSStatusBarButton` 类型识别其窗口，清除该窗口和内容视图的显式外观，让 AppKit 继续按菜单栏背景着色。应用级主题和普通窗口的主题应用保留，无固定黑白色、私有窗口类名、额外设置或依赖。

新增 `GlassAppearanceTests.testThemePreservesSystemStatusItemAppearanceAndRepairsOldOverride`：创建真实状态项，先施加旧的错误覆盖，再切换暗色、亮色、跟随系统、暗色，逐次断言窗口及内容视图没有显式覆盖，按钮有效外观保持系统值。现有普通窗口三主题回归同样通过。

实际命令结果：

```text
make build
✅ Build complete!

make test-unit
Executed 941 tests, with 9 tests skipped and 0 failures
** TEST SUCCEEDED **

codesign --verify --deep --strict DerivedData/Build/Products/Debug/Switchly.app
退出码 0，无错误输出

git diff --check
退出码 0，无输出
```

## 正式应用看图与限制

验收固定路径为工作区 `DerivedData/Build/Products/Debug/Switchly.app`，重启后 PID 39583。先正常退出旧进程再构建及测试，测试完成后再启动同一路径，不在实机验收期间覆盖运行副本。

通过原生工具自行切换并实际查看[亮色](menu-bar-appearance-assets/preferences-light-2026-11-13.png)、[暗色](menu-bar-appearance-assets/preferences-dark-2026-11-13.png)、[跟随系统](menu-bar-appearance-assets/preferences-system-2026-11-13.png)的正式设置窗口。亮色采用深色文字，暗色采用浅色文字；最后恢复原来的跟随系统。这些图片只证明正式设置界面的主题切换，没有冒充菜单栏图标的实色对照。

本机菜单栏宿主为 `MenuBarAgent`。已通过原生工具枚举到 `Description: Switchly, ID: switchly.status-menu`；但原生菜单栏截图缺少有效背景，系统屏幕区域截图没有呈现目标图标，后续坐标操作明确返回 `Computer Use server error -10005: noWindowsAvailable`。因此**与相邻图标的真实合成色对照仍未完成**，不能宣称全屏／多屏菜单栏视觉验收通过。没有为取得截图更改系统主题、菜单栏隐藏设置或系统权限。

## 数据保全与自检签署

本次未触碰活动清除确认、采集设置和插件授权。重建前保全活动库；重启后只读核对 506 条基线会话 ID 全部保留，当前 514 条；9 张基线 JPEG 字节全部一致。增加来自正常采集，不代表此前事故缺失的原图已经恢复。必要基线和命令日志继续保留在原私有恢复目录的 `menu-appearance-2026-11-13` 子目录，不进入仓库。

对照项目 AGENTS.md 第 8 节及通用交付清单签署：

- 范围与契约：通过。仅修改主题应用、相关回归、设计合同、变更记录及本次审阅证据；保留既有修改。
- 验证与证据：构建、941 项单测、签名和差异检查通过；正式设置已看图。菜单栏真实合成色对照未通过，原因及工具原始错误见上文。
- 文档与台账：通过。MB-D01 明确图标与应用主题边界，本记录区分隔离验证、正式看图与未验项。
- 环境与卫生：本次调试脚本和无效菜单栏截图清理；正式引用的三张截图归档，必要私有恢复材料保留。未读取密钥或进程内存，未变更系统权限。

**问题 → 方案 → 后续**：应用主题覆盖菜单栏窗口 → 保留系统状态项外观继承，回归覆盖旧覆盖修复和三主题切换 → 仍需补有效菜单栏合成截图与相邻图标对照。
