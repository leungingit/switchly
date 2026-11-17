# 1.4.0 图文展示与发布核验

## REL-D01：范围与版本

用户授权审查未提交文件、提交、增加 README／GitHub Pages 富媒体展示、提升一位小版本、创建并合并 PR，最后发布 Pages。

初始 `git status --short` 无输出；分支 `main`，HEAD `3820adf`，无待提交变更。使用 `make bump-minor` 将 `1.3.0 (build 1)` 提升为 `1.4.0 (build 1)`。版本唯一来源仍为 `Resources/Info.plist`。本次是版本与官网更新，不创建应用发行标签，不触发应用 Release 打包。

## REL-D02：先看图，再看说明

README 和官网共用活动时间线原生合成样例、窗口截图和独立插件预览流程图。优先显示图片，仅保留用途、开启方式与必要权限／数据边界；详细实现链接回既有合同。素材来源见 [图片资产说明](../assets/images/README.md)。

活动图使用既有 `SwitchlyActivityProbe`，只渲染内存样例，不操作真实历史、采集或权限。流程图是示意，不能冒充产品截图。保留旧系统、Intel、跨屏和后台路线的未验范围。

## REL-D03：Pages 配置与发布

此前 Pages 工作流 `42946200376` 在 `actions/configure-pages` 失败，错误为 `Get Pages site failed / Not Found`；仓库 Pages API 同样返回 404。仓库管理权限可用。已运行现有 `Scripts/pages.sh enable`，API 返回 `build_type=workflow`、`https_enforced=true`，站点为 `https://leungingit.github.io/switchly/`；主干合并后再部署；不通过修改检查或提升工作流权限绕过失败。

## 验证记录

- `make verify-plugin-release`：退出 0，外仓 revision 与制品不可变校验通过。
- `make build`：退出 0；预装制品校验 5 个插件，MediaRemote 离线校验 30 个文件。首次沙箱内执行因 SwiftPM 缓存写入权限失败，使用正常构建权限重跑成功。
- `make test-unit`：退出 0，`TEST SUCCEEDED`；941 项测试，9 项跳过，0 失败。跳过项不视为通过；未执行完整系统 UI 测试。
- `./verify.sh --release`：`PASS 0 check(s) failed, 2 warning(s)`。警告是提交前的脏工作区和既有超 500 行文件，没有降低检查标准。
- `Scripts/pages.sh build`：`built _site: 13 files`；`Scripts/pages.sh check`：`links ok`。
- `xmllint --noout` 检查两个新增 SVG：退出 0。
- `git diff --check`：无输出。
- ego-browser 实际核验：桌面浅色／深色和 390px 手机深色，图片全部加载，无横向溢出（390 / 390、1352 / 1352）；减少动态效果时 `scrollBehavior=auto`。已实际查看活动图、两个流程图及页面截图；流程图与活动图提供原图入口。

复用项目 AGENTS 第 8 节交付清单：范围与既有工作区保护、共享资产及主题、必要构建与测试、视觉看图、文档和隐私边界、临时文件卫生均按本次适用项检查。本次不修改原生界面／服务逻辑，相关运行态验收不扩充结论。临时截图和日志仅在系统临时目录，交付前清理。PR 和 Pages 的最终远端状态以交付链接为准。
