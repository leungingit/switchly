# AT-I01 活动时间线提交前复核与整合

日期：2026-11-13，Asia/Singapore。范围是本轮宿主及插件外仓未提交改动，不包含发布、版本变更或系统权限修改。

## 文件处置与跨仓依赖

- 两个原工作区都在 `main`，检查开始时没有未合并 PR。宿主共 167 个候选路径，插件外仓 10 个；内容为活动追踪、插件面板、API／SDK／CLI、夹具、测试、文档及菜单栏主题修正。
- 在系统临时目录创建两个隔离 worktree 完成复核、构建与提交，不覆盖当前运行的正式应用。
- 外仓 [PR #4](https://github.com/leungingit/switchly-plugins/pull/4) 提交活动插件；后续代码复核发现问题后，由 [PR #5](https://github.com/leungingit/switchly-plugins/pull/5) 修正。两者均已合入外仓 `main`。
- 宿主锁定修正后的不可变外仓提交 `419a662b6b7ae4d040d2339b971ce4bd8a63c2cc`，5 个插件制品摘要通过校验；其余既有插件摘要不变。
- 8 张含真实应用使用历史的实机截图保留在本机私有恢复材料中，不上传公开仓库；文档将对应链接改为明确的本机证据说明。公开图证保留合成夹具、专用 A／B 测试窗口与设置界面。两份证据 JSON 的个人绝对路径改为可复用路径。

## 复核发现与修正

1. **单测宿主接触正式服务**：`applicationDidFinishLaunching` 原本也会在宿主单测中启动真实服务，包括默认 ActivityStore 及其清理路径。现于读取偏好和装配服务前检测已加载的 XCTest 宿主并返回；生产应用继续正常启动，测试使用自身注入的 fake 与可丢弃库。全量单测日志命中 `Skipping application services in unit test host` 一次，`Setting up services` 为零次。
2. **渲染器摘要未同步**：菜单栏主题修正改变了共享 `ThemeApplier`，导致 renderer revision 守卫失败。已同步为 `sha256:f4491a250602e1b1870427f77e9a8bc8ca1f489d84d7c18385db6940b5530dee` 并重新执行基线回归；公开 API 契约哈希仍为 `sha256:b748c257e61bf5c5a4439f775720ca215da30bdffd2ac933a579bc3922681c5a`。
3. **停止采样隐藏历史截图**：展示原本还受 `summary.screenshotsEnabled` 门控。现仅以截图读取授权和查询结果控制历史展示；停采只增加说明，历史图片及子分页继续可用。
4. **趋势失效被当作普通降级**：趋势请求返回 `activityInvalidated` 时，旧逻辑仍展示同批成功结果。现整批显示失败，既有图表、会话和截图均不输出，不自动重试；普通趋势查询失败仍可降级。
5. **默认状态文档不一致**：外仓 README 的“默认启用”修正为与 manifest 一致的“默认关闭，需用户明确授权”。活动设置属性与使用次数注释的归属也已整理。
6. **独立脚本编译依赖遗漏**：首轮远端 CI 的 JSC／协议任务失败，原因是手工列举编译输入的脚本漏掉 `PluginTimelineItem`、`ActivityTrackingSettings` 及活动 Worker 夹具依赖。已补齐六组脚本，并同步默认场景测试中新增活动夹具枚举及 inspect 的四类精确输出；新增检查确认活动能力只接受显式合成夹具，不回退内置样例。协议、场景、产物、监听、Worker、Session 和进程监管七组脚本逐项本机重跑。

第 3、4 项新增回归先在旧实现上执行：相应两项新用例及更新后的停采提示断言共 3 项失败；修正后外仓全部 82 项通过，没有跳过或降低断言。

## 验证与看图

| 检查 | 结果 |
| --- | --- |
| 外仓 `npm test`／`npm run build` | 82/82、0 失败、0 跳过；两条发行线构建通过 |
| SDK `npm test` | 14/14、0 失败；通过临时 TypeScript 5.9.3 环境补齐打包后类型解析，未增加仓库依赖 |
| CLI `npm test` | 73/73、0 失败 |
| 宿主 `make build`／`make test-unit` | 构建通过；941 项、9 个既有跳过、0 失败 |
| `make plugin-preview-build` | App／Worker 构建通过 |
| `make plugin-preview-contract-check` | 契约、渲染器摘要及 35 个共享核心类型守卫通过 |
| Worker 独立测试 | `PluginPreviewWorker tests passed` |
| CI 使用的七组 Swift 独立测试脚本 | 协议、场景、产物、监听、Worker、Session、进程监管全部通过 |
| `make mediaremote-adapter-test` | 13 项通过 |
| `Tests/PluginPreview/run-baseline-tests.sh` | 接受新基线、同场景零差异、修改检出及玻璃拒绝基线全部通过 |
| `make prepare-plugins`／`make verify-plugin-release` | 5 个插件摘要与不可变来源提交检查通过 |
| 签名／差异卫生 | `codesign --verify --deep --strict`、`git diff --check` 通过 |
| `./verify.sh` | 0 失败；提交前的未提交路径与既有超长文件提示属于警告 |

已实际查看最终外仓制品经同一套正式渲染器生成的[中文浅色](activity-timeline-assets/integration-light-fixture-2026-11-13.png)及[英文窄深色](activity-timeline-assets/integration-dark-fixture-2026-11-13.png)图片：趋势图例、纵向会话轴、停采说明及空截图提示均可读，没有看到裁切或重叠。两张均为隐藏原生合成夹具，不代表真实桌面采样或菜单栏配色验收。

## 已知限制保留

- AT-INC01／AT-INC02 记录的第 4 张原始 JPEG 与至少两条新增区间仍有恢复缺口。本轮整合不将这些问题标为已解决，恢复材料继续保留。
- 真实活动库的清除确认仍禁止用于补自动化截图；根因未完全复现，不能宣称真实清除安全验收通过。
- 菜单栏主题污染的代码与真实状态项回归已修正，但与相邻菜单栏图标的真实合成色截图对照仍未完成，见菜单栏专项记录。
- 本机检查不代替 macOS 12、Intel、多屏／跨 Space 或图形权限受限环境的完整验收。

## 提交前自检签署

按根 AGENTS.md 第 8 节及通用交付清单核对：范围、旧设置兼容、默认关闭、双语文案、权限与有效代次、隔离测试、制品来源、图证及发布卫生均有对应实现或上述验证。未覆盖原工作区的额外改动；私有活动库、恢复副本、凭据和派生产物不进入提交。正式引用图片保留为审阅资产，其余本轮临时目录在交付后清理。已知未验项及事故缺口不作为通过项签署。
