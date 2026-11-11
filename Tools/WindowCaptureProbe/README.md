# 窗口截图原生验收工具

此工具复用正式 Dock 卡片、插件 Runtime、原始截图、选区、文件服务与截图窗口，只创建和操作自身 A/B/C 样例窗口；不读取用户偏好，不启动媒体采集，不安装插件到用户目录。

测试提交器显式确认传入插件的 window.capture 授权，并注入“仅自身进程”的抓取边界。其权限函数只用于自有样例窗口，不能替代主 App 的屏幕录制权限门禁，也不能用于宣称跨应用或真实 Dock 验收通过。正式 Preview / Worker 仍只模拟 accepted，不使用此工具的真实截图路径。

先在隔离外仓执行 npm test、npm run build，显式更新宿主候选锁，并 make generate。构建命令：

```sh
Scripts/xcodebuild-no-warnings.sh -project Switchly.xcodeproj \
  -scheme SwitchlyCaptureProbe -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$TMPDIR/capture-probe-derived" -quiet build
```

使用系统临时目录的已有任务子目录作为输出目录，将待验证插件包目录作为第二参数启动生成的 App。工具按 A/B/C 展示正式卡片；快速截图应显示相应字母的完整窗口，region 在同一冻结图像裁剪。可切换工具自己的浅色、深色和跟随系统主题；不会改变 macOS 系统主题。

“保存当前窗口验证图”菜单将当前工具窗口的原生截图保存到输出目录。外部编辑会在输出目录下的 editing 子目录建立私有会话；必须在系统预览保存、关闭后显式读取，再验证保存、复制与清理。系统分享只打开选择器检查，不向任何接收方发送测试图片。

验收结束退出工具，清理本次系统临时目录；需长期保留的合成证据转入 docs/reviews 并标明范围。Mac 锁屏时应等待用户手动解锁，不通过后台抓屏替代交互验收。
