# 后台预览提交候选与主干复验（2026-11-10）

## PV-D15：提交范围与历史证据

提交候选基于 `origin/main` 的 `fb4a85f`，重放尚未进入主干的 SceneKit 3D 基础提交，再接入后台视觉与原生输入。原工作区混合的 MediaRemote、窗口服务、外仓资产及其余文档整理没有纳入；使用独立检出验证，原工作区与外仓均保留。

主干已经包含旧预览 PR，不能重复重放其全部历史。旧分支的基础 3D 提交 `2542218` 重放为 `a146f8e`；其他已合并预览历史由主干提供。六份预览文档迁入 preview 子目录，并只修正相关引用。

共享 Renderer 必须包含本机验证所用的布局、主题、动态表面刷新与转盘扇区支持，否则不能复现本轮实际图像与输入。保留旧宿主未提供 artworkToken 时按图像对象身份失效的兼容路径，未将其他任务的媒体桥一并纳入。当前 rendererRevision 为 `sha256:f727aebcb34d2b64b7e1a48c18a4b518bd417328c947a9bd2382d73c7045eca1`；契约哈希仍为 `sha256:23e48934daf60d04e7f5029b24b89fe2c3dfba998afc6ee89bd1adc226f73d51`。

[正式接入记录](plugin-preview-background-integration-2026-11-10.md)中的 804 项测试与像素指纹是原混合工作区的历史证据；本文件记录真正提交候选的独立复验，不能混为同一源码版本。

## 固定依赖与真实执行

插件锁文件保持不可变 `33f8b9c2bf0d6ea98f44ef27a15416b77ec4647a`，没有提交 sourceRevision=null，也没有提交外仓未提交的 GLB／JS。将该 revision 从本地 Git 对象导出到系统临时目录，用提交候选打出的离线 CLI 包准备校验器，在导出目录执行 npm test、npm run build，再通过 SWITCHLY_PLUGIN_SOURCE 指定其 dist-v2/Plugins 进行构建。

| 验证 | 结果 |
| --- | --- |
| 固定 revision 外仓 npm test／npm run build | 通过，制品与宿主锁文件匹配 |
| make plugin-preview-build | 通过 |
| make build（指定固定 revision 制品） | 通过 |
| make test-unit（相同固定制品） | TEST SUCCEEDED；732 项，8 跳过，0 失败 |
| 场景／步骤、worker 测试 | 通过 |
| npm --prefix Plugins/cli test | 67 项，0 失败 |
| make plugin-preview-contract-check | 契约、渲染指纹与共享源码守卫通过 |
| 后台 2D 视觉基线回归 | 通过，重复图像一致、差异检出、玻璃拒绝均按原零容差规则 |
| 本机新版 wheel_ring 扇区夹具的后台回归 | 全部 17 个进程通过；上屏、目标前台、激活事件为 0。存在其他前台变化采样，来源未归因，不能宣称系统前台全程不变 |
| 固定旧 revision 的后台回归 | 2D 正负向、增长、环境错误、SIGTERM 和旧 iPod 初始截图通过；完整脚本退出 77，明确 NOT_TESTED 新版 iPod 坐标交互 |

已实际查看提交候选捕获的锁定旧 iPod 原生图，完整模型和合成媒体内容可见。旧版使用倾斜相机与 mesh_wheel_* 命中节点，新版坐标夹具使用正视相机与 wheel_ring 扇区，两者不能直接套用同一组坐标。最初盲套时得到 no-action-routed；现已加入对实际 ui-tree 声明的夹具兼容性检查，不再把截图成功当作交互通过。

## 发布边界

本 PR 作为草稿供代码审查：通用后台路径和本机新版资产的交互闭环已验证，但固定旧资产的新版坐标交互没有通过。需要外仓将适配资产提交为不可变 revision 后，另行审核并更新宿主锁文件，再完成相应矩阵；本轮不代替该授权和资产审查。macOS 12、原生 Intel、跨 Space、压力、完整输入、玻璃逐像素等价和多时钟确定性等边界继续保留。

临时检出、离线包、固定 revision 导出、截图和日志均放系统临时目录，交付后清理；Git 分支与 PR 保留。原工作区已有修改未重置、未暂存或提交到本 PR。

## CI 首轮失败与修复

首轮云端静态／Node 通过，但 macOS 两条检查失败：独立协议、监听、会话及进程监督脚本缺少 scene3d 数据类型的编译闭包；另一路在插件 checkout 报 not our ref，证明固定 revision 只有本地对象，尚不能作为云端来源。

现已补齐四个脚本的 PluginScene3DDescriptor、PluginSurfaceRequest 与 GLBPreflight 源文件，没有更改断言或降低标准。本机完整运行输出：协议 8/8、整包监听通过、会话 5/5、进程监督 7/7。外仓仅把已提交的 33f8b9c 发布到独立依赖分支 feat/scene3d-preview-base，未推送未提交资产，未更新外仓主干，宿主锁文件保持同一 SHA。GitHub commit API 已确认该 revision 可读取。
