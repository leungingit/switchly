# MediaRemote Adapter 固定离线源码

- 上游：<https://github.com/ungive/mediaremote-adapter>
- revision：`0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd`
- 许可证：BSD-3-Clause，原文保留在 `upstream/LICENSE`。
- `upstream/` 是该 revision 的 `src/`、`include/`、`bin/`、`CMakeLists.txt` 与 LICENSE 原样副本。没有修改上游源码；没有引入 Git 元数据、构建输出或网络更新逻辑。
- `source.json` 记录来源、下载归档 SHA-256 与每个源文件 SHA-256。更新依赖须显式审查新来源与清单，普通构建不刷新清单。

在仓库根目录执行：

```sh
make mediaremote-adapter-verify
make mediaremote-adapter-build MEDIAREMOTE_OUTPUT="$TMPDIR/switchly-mediaremote-output"
```

输出目录应使用新的任务目录；若已存在同名产物则拒绝覆盖。只需要项目已有的 Python 3 和 Xcode 工具链，构建使用系统 `xcrun clang`，无需 CMake、Homebrew 或网络。产物包括 framework、脚本、许可证和来源清单；同时编译 arm64／x86_64，声明最低 macOS 12。

独立 build 子命令不调用个人证书签名、公证或修改 App 包。系统链接器可能给本地二进制添加 ad-hoc 签名；发行包签名、Hardened Runtime 加载与旧系统运行尚待 MR-T06 验证。不生成上游可选的 TestClient；普通组件测试使用本地 Perl 夹具，真实播放器验收单独记录。

主 App 正常 build／test-unit 在 Xcode 构建阶段离线校验输入、编译双架构框架并打包至 `Contents/Resources/MediaRemoteAdapter`，在 App 最终签名前按当前构建身份签名框架；不下载依赖或更新清单。共享 Host 通过独立装配入口默认使用组合桥，只有可见且获授权的媒体消费者才启动采集。Preview App／Worker 不包含或执行本依赖。


可选候选 App 验证：`make mediaremote-adapter-stage MEDIAREMOTE_APP=".../Switchly.app" MEDIAREMOTE_OUTPUT=".../Candidate.app"` 只创建新副本，将依赖置于 `Contents/Resources/MediaRemoteAdapter`；复用同一打包实现，可替换候选副本内已有依赖；不写回输入、不签名。拒绝 Preview／Worker、既有输出和资源路径符号链接；候选必须另行签名公证验收后才可分发。候选命令不替代发行签名验收。
