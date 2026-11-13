# 活动时间线原生验证工具

只使用外仓插件脚本和内存合成区间/样例图片，复用正式 PluginHost、JavaScriptCore、面板 ViewModel、声明式解码器和渲染器。不会开启真实活动记录、读取个人使用历史或捕获其他应用窗口；不修改偏好设置或权限。样例界面不是用户最终视觉批准。

从宿主根目录构建：

```sh
make generate
xcodebuild -project Switchly.xcodeproj -scheme SwitchlyActivityProbe -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath DerivedData -quiet build
open DerivedData/Build/Products/Debug/SwitchlyActivityProbe.app --args --plugins /绝对路径/switchly-plugins/dist-v2/Plugins
```

可加 `--dark` 检查深色，加 `--english` 使用英文插件文案；退出使用 Command-Q。验证上午/下午/日/月/年/自定义、日期两端、分组、长应用名、图片尺寸、键盘与面板边界。

`--ungranted` 使用未授权的合成插件元数据，检查正式宿主的待授权提示和「检查权限」入口；不撤销或授予真实插件权限。普通模式对合成 Host 显式注入两项活动授权，仍不读取个人历史。

真实锁屏、睡眠、会话切换、录屏撤权、多屏与macOS12/Intel仍需主App单独验收；本工具不将合成行为当作系统证据。存储、权限和图片引用清除回归在 Tests/UnitTests/ActivityIntegrationTests.swift，均使用系统临时目录。

需要真实前台区间、撤权／恢复及 600 秒冷却时，使用独立的[连续实机验收窗口](../ActivityTrackingAcceptance/README.md)配合正式主 App；该工具只控制自身测试窗口，不改变本合成探针的职责。


锁屏或不希望激活窗口时，可仅渲染自有合成视图（输出必须是系统临时目录）：

```sh
DerivedData/Build/Products/Debug/SwitchlyActivityProbe.app/Contents/MacOS/SwitchlyActivityProbe --plugins /绝对路径/switchly-plugins/dist-v2/Plugins --render-panel "$TMPDIR/activity-panel.png" --dark --english --opaque
DerivedData/Build/Products/Debug/SwitchlyActivityProbe.app/Contents/MacOS/SwitchlyActivityProbe --plugins /绝对路径/switchly-plugins/dist-v2/Plugins --render-settings "$TMPDIR/activity-settings.png" --dark --screenshots-settings
```

`--screenshots-settings`只初始化合成设置状态，不开启真实采集；`--system`跟随系统主题。隐藏渲染使用正式原生视图的位图缓存，不排序窗口、不激活应用、不请求录屏权限，不代替真实桌面材质/输入验收。看图后清理本次输出。


纵向时间线可单独做隐藏原生布局核验（仅合成会话及图片，不操作桌面、不代替正式实机）：

```sh
timeline_dir=$(mktemp -d "${TMPDIR:-/tmp}/switchly-timeline.XXXXXX")
DerivedData/Build/Products/Debug/SwitchlyActivityProbe.app/Contents/MacOS/SwitchlyActivityProbe --plugins /绝对路径/switchly-plugins/dist-v2/Plugins --render-timeline "$timeline_dir/timeline.png" --opaque
```

`--compact` 将输出宽度设为 400pt，检查最小面板宽度；可与 `--dark` 或 `--english` 组合。左侧时间轴复用正式 timeline 渲染器，图片归入明确匹配的合成会话。请实际查看图片，并在核验完成后清理临时输出。

`--many-apps` 追加 5 个仅存在于内存的样例应用，用于覆盖汇总加 6 条应用线的完整图例及“汇总包含全部应用”提示；仍不启动真实采集、不修改偏好或活动库。与 `--render-panel`、`--compact`、`--dark` 组合检查满数量图例和滚动边界，不能只以两个样例应用通过便认为完整图例实机通过。


确认内容可通过 `--render-consent "$TMPDIR/consent.png"` 做隐藏原生布局核验；默认显示清除确认，确认词为空且清除按钮禁用。可加 `--recording-consent` 或 `--screenshots-consent`，以及 `--dark`／`--english`。复用正式 `ActivityConsentView`，不触发确认动作、不构造真实采集器，也不修改偏好或历史；这些图是组件证据，不是正式弹窗交互通过。
