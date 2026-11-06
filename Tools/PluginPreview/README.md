# Plugin Preview T01 可行性探针

本目录只保存可演进的探针源码，不接入正式工程。`run-t01.sh` 在系统临时目录编译并运行独立 AppKit 进程，直接编译仓库现有的 `PluginOverlayView`、`PluginSceneView`、`SceneDrawing`、`SceneAssets`、`GlassEffect`、`NativeCrystalContainer`、`DesignTokens`、`MotionTokens` 与真实 `CrystalMaterial`，没有另写渲染器。

## 运行

```sh
./Tools/PluginPreview/run-t01.sh
```

脚本不会修改或停止已运行的 Switchly，也不会调用 `make run`。所有可执行文件、合成 fixture 与 PNG 均写入 `mktemp` 创建的临时目录。

探针依次运行：

1. `offscreen`：使用 SwiftUI `ImageRenderer` 渲染 plain 内容。
2. `plain`：创建独立 borderless 窗口，用 `screencapture -l <windowID>` 捕获普通材质窗口。
3. `glass`：同一窗口路径启用共享 `panelGlass`；在 macOS 26+ 走 `NSGlassEffectView`，再用 `screencapture -l` 捕获真实 WindowServer 结果。

每次截图都会解码为像素并检查尺寸、色彩变化、真实 artwork、插件资产与 Scene 图片。程序化像素检查只用于发现空白或漏层，最终仍需人工打开 PNG 检查布局、图片和材质。

当前探针实测中，`ImageRenderer` 能保留普通图片与 Scene Canvas，但线性 `ProgressView` 的外观与真实窗口不一致；因此 plain 稳定截图应以真实窗口路径为主，`ImageRenderer` 只作为离屏能力探针。

## 已知边界

- 本探针只验证当前机器实际运行的系统与架构；部署目标为 macOS 12 仅表示可编译，不表示已在 macOS 12 运行。
- 截图使用已存在的 Screen Recording 权限；探针只做 `CGPreflightScreenCaptureAccess()` 检查，不主动弹出授权。
- 不验证 Dock 悬停、AX 切窗、真实媒体/天气服务、签名或公证。
- 正式 Preview target、资源接线和命令行入口由工程所有者集成，本目录不修改 `project.yml` 或 `Makefile`。

## 2026-11-03 实测

- 环境：arm64、macOS 27.0.1（build 26A434）、Xcode 27.2、Swift 6.4.2；部署目标按 macOS 12 编译。
- GUI：2 个屏幕、主屏 2x；Screen Recording 预检为 true；Reduce Motion 为 false。
- 独立编译与运行：`./Tools/PluginPreview/run-t01.sh` 退出 0；offscreen、plain、glass 三个模式均退出 0。
- 截图尺寸与像素检查：ImageRenderer 1120x1520；plain 与 glass 真实窗口均为 1212x1612。三张图均检出 artwork、插件资产与 Scene 图片颜色。
- 实际读图：三类内容完整可见，无裁切；plain 与 glass 的真实窗口均显示原生按钮、toggle、slider、progress、Scene Canvas、artwork 与插件资产。玻璃模式出现独立蓝灰半透明材质层，未静默丢失图片或 Scene。
- 离屏限制：`ImageRenderer` 保留图片和 Canvas，但线性 `ProgressView` 显示为黄色条并带禁止符号，与真实窗口不一致；不得把它作为最终视觉基线。
- 宿主回归：`make build` 通过；`make test-unit` 执行 543 tests、8 skipped、0 failures。
- 未完成：执行时用户本体仍在运行，为避免中断使用而未停止，因此没有做“宿主进程关闭后启动探针”的字面验收；macOS 12 与 x86_64 只完成部署目标编译/静态结论的范围内检查，未实机运行。
- 补充验证：同日临时退出本体后再次运行探针，三种模式状态均为 0、`core_window_capture=PASS`；实际查看了 plain 与 glass 窗口图，随后重新启动原路径本体并清理临时图片。其他平台与权限限制仍未验证。


## PV-T01 后台遮挡捕获

运行 `./Tools/PluginPreview/run-t01.sh --background`。普通与玻璃窗口复用原 T01 内容，不激活、不获取 key，以 normal 层后置；蓝色合成窗口在浮动层完全覆盖目标。测试用 WindowServer 列表及 frame 检查覆盖关系，比较捕获前后的前台应用 PID，并检查截图中的 artwork、插件资产与 Scene 颜色。失败返回非零，不回退前台截图。此探针会短暂显示合成遮挡窗口，不等于无桌面干扰模式。

产物仍放系统临时目录，脚本输出 evidence_root；需实际读图后清理该目录。默认不带参数的旧 T01 行为保留。后台验证只覆盖当前 GUI 会话，不证明无 WindowServer、旧系统、其他 Space 或正式自动化 run 已通过。
