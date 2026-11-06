# Contributing to Switchly

Thanks for your interest in contributing. This document covers everything you
need to build the project, run the tests, and get a change merged.

By participating you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

---

## Ways to contribute

- **Report a bug** — use the bug report issue template. Include your macOS
  version, chip architecture, and which apps are affected.
- **Request a feature** — use the feature request template. Describe the problem
  first, then your proposed solution.
- **Send a pull request** — bug fixes, new features, docs, and tooling welcome.
- **Report a security issue** — do **not** open a public issue. Follow
  [SECURITY.md](SECURITY.md).

---

## Development setup

### Requirements

| Tool | Version | Notes |
|---|---|---|
| macOS | 12.0+ | The deployment target; build on 13+ recommended |
| Xcode | 26.0+ | Full Xcode, not just Command Line Tools |
| XcodeGen | latest | `brew install xcodegen` — the `.xcodeproj` is generated |

### Bootstrap and build

```bash
git clone https://github.com/leungingit/switchly.git
cd Switchly

brew install xcodegen

(cd ../switchly-plugins && npm run build) # 外仓需克隆到相邻目录
make bootstrap    # generate Switchly.xcodeproj from project.yml
make build        # Debug build
make test-unit    # unit tests only (fast, what CI runs)
make run          # build and launch the app
```

Run `make help` to list every target.

### Signing

Signing is **off by default** so a fresh clone builds with no Apple Developer
account: `Config/Base.xcconfig` (attached to every configuration via
`project.yml`) sets `CODE_SIGN_IDENTITY` to `-` (ad-hoc). Resolution order,
highest wins:

1. `make build SIGN_IDENTITY="…"` — explicit one-off override
2. your local `Config/Local.xcconfig` — git-ignored, never committed
3. `Config/Base.xcconfig` defaults — ad-hoc, what CI uses

#### Stable permissions while developing (recommended)

Ad-hoc signing has no stable code identity: the cdhash changes on every
rebuild, so macOS treats each build as a brand-new app and drops the
**Accessibility** / **Screen Recording** grants. To grant once and keep the
permissions across rebuilds:

1. Create a local self-signed code-signing certificate (no Apple Developer
   account needed):

   ```sh
   Scripts/create-dev-cert.sh   # creates "SwitchlyDev" in your login keychain
   ```

   Or create it manually in *Keychain Access → Certificate Assistant → Create
   a Certificate*: name `SwitchlyDev`, Identity Type *Self-Signed Root*,
   Certificate Type *Code Signing*.

2. Activate it locally (the file is git-ignored — your certificate name or
   Team ID never reach GitHub):

   ```sh
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   # enable Option A (self-signed) — or Option B with your own Team ID
   ```

3. Reset the two permissions one last time, then re-grant them in
   *System Settings → Privacy & Security*:

   ```sh
   tccutil reset Accessibility com.switchly.app
   tccutil reset ScreenCapture com.switchly.app
   ```

Every rebuild now keeps the same designated requirement
(`certificate leaf[subject.CN] = "SwitchlyDev"`), so the grants survive
indefinitely. Contributors who skip this keep the ad-hoc behaviour, and CI is
unaffected. Verify the identity of a built app with
`codesign -dr - <path to Switchly.app>`.

### Permissions while developing

Switchly cannot function without:

- **Accessibility** — to enumerate and focus other apps' windows (`AXUIElement`)
- **Screen Recording** — to capture window thumbnails (`CGWindowListCreateImage`)

Grant both in *System Settings → Privacy & Security*. If Screen Recording is
denied the app still works, falling back to app icons plus window titles.

> With the default ad-hoc signing, a rebuild loses these grants. Follow
> "Stable permissions while developing" above to fix that once and for all.

---

## Project layout

```
Sources/App/           app entry point (SwitchlyApp, AppDelegate)
Sources/Models/        data models and enums
Sources/ViewModels/    view models (MVVM)
Sources/Views/         SwiftUI / AppKit views
Sources/Services/      accessibility, window monitoring, thumbnails, shortcuts, settings
Sources/Utilities/     logging, theming, window-match rules
Resources/     Info.plist, asset catalog, localizations
Supporting/    entitlements
Tests/         UnitTests (real coverage) and UITests (skeleton)
Scripts/       one-off tooling
```

`project.yml` is the source of truth for the Xcode project. **Never edit
`Switchly.xcodeproj/project.pbxproj` by hand** — run `make bootstrap` instead.

---

## Coding guidelines

- Keep one type per file and keep files under ~500 lines.
- New services must define a `protocol` and take dependencies via `init` so they
  can be tested with fakes.
- Any change to a `Codable` model must decode new fields with
  `decodeIfPresent` plus a sensible default, so existing users' saved settings
  keep loading. Do not break `com.switchly.settings` compatibility.
- Log significant operations through `AppLogger` using `key=value` pairs.
  Do not remove existing log statements.
- Prefer explaining *why* in comments. The window-matching code in
  `Sources/Utilities/WindowMatchRules.swift` and `Sources/Services/AccessibilityService.swift`
  documents hard-won platform behaviour — keep those notes accurate.
- No new third-party dependencies unless there is a strong reason; discuss in an
  issue first.

### Things this project deliberately does not do

- **No networking.** The app must not gain a network entitlement. It is a
  fully local tool and the privacy policy depends on that.
- **No data collection or analytics SDKs.**
- **No store purchases / StoreKit.** Distribution is a paid download; there is
  no in-app purchase, no Pro tier, and no license check in the code.
- **Do not remove permission usage descriptions** from `Resources/Info.plist`.

---

## Testing

Unit tests live in `Tests/UnitTests/` and run against the real app target:

```bash
make test-unit     # what CI runs
make test          # full suite, including UI tests
```

The bug fixes worth writing tests for are the window-attribution ones: given a
CoreGraphics window list and an Accessibility window list, does the resolver
pick the window the user actually clicked? `WindowMatchRulesTests` is the model
to follow.

`Tests/UITests/` is still a skeleton — contributions welcome.

### Verifying UI behaviour

Some behaviour cannot be covered by unit tests (AX/CG layer ordering, overlay
surfaces, focus verification). For those, run the app and describe exactly what
you observed, including the concrete window IDs and titles. See
[`Sources/Utilities/WindowMatchRules.swift`](Sources/Utilities/WindowMatchRules.swift) for the
kind of evidence that is expected in a pull request.

---

## Submitting a pull request

1. Fork and branch off `main` (`fix/…`, `feat/…`, `docs/…`).
2. Keep commits focused; write [conventional](https://www.conventionalcommits.org/)
   messages where practical (`fix:`, `feat:`, `docs:`, `ci:`, `deps:`).
3. Make sure `make build` and `make test-unit` pass locally.
4. Fill in the pull request template — especially the verification section.
5. Make sure CI is green before requesting review.

### What reviewers look for

- Does it actually fix the stated problem?
- Is there evidence beyond "it compiles"? This project has a history of fixes
  that appeared to work but silently failed, so claim-by-claim verification
  matters.
- Any accidental commit of build artifacts, credentials, or personal data?
- Does it stay within the "local-only, no collection" boundary?

---

## Releasing (maintainers)

`Resources/Info.plist` is the single source of truth for the version. A release
is cut with `make release-*`, which is atomic: it validates the tree, promotes
the CHANGELOG's `[Unreleased]` section into a dated version section, bumps the
plist, commits, and tags `vX.Y.Z`. It never pushes.

The complete procedure — SemVer rules, every target, what the release workflow
does with a tag, signing secrets, and rollback — is in
[docs/engineering/RELEASING.md](docs/engineering/RELEASING.md).

```bash
# 1. Describe what changed under "## [Unreleased]" in CHANGELOG.md
$EDITOR CHANGELOG.md

# 2. Cut the release — one of:
make release-patch                    # 1.0.0 -> 1.0.1
make release-minor                    # 1.0.0 -> 1.1.0
make release-major                    # 1.0.0 -> 2.0.0

# 3. Publish
git push origin main --tags
```

`make release-*` refuses to run when the working tree is dirty, when the tag
already exists, or when `[Unreleased]` is empty. Before committing it runs
`./verify.sh --release`, which fails — rather than warns — when the CHANGELOG
has no section for the version being shipped. To release an empty section
anyway, call the script directly:
`Scripts/version.sh release <patch|minor|major> --allow-empty`.

Pushing a `vX.Y.Z` tag triggers `.github/workflows/release.yml`, which verifies
that `Resources/Info.plist` matches the tag, builds Release, packages
`Switchly-<version>.zip` with a SHA-256 checksum, and publishes a GitHub Release.
If the optional signing secrets are configured the build is also signed with a
Developer ID and notarized; otherwise the release notes say so explicitly.

To move the version *without* releasing, use `make bump-patch`, `bump-minor`,
`bump-major` or `bump-build` — those edit `Info.plist` and commit nothing.
`make zip` builds a local `build/Switchly-<version>.zip` + `.sha256`
(`make package` is an alias).

`make github-release TAG=vX.Y.Z` publishes with the `gh` CLI instead of waiting
for CI; it accepts a tag that `make release-*` has already created at `HEAD`.

---

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).

## 插件开发与跨仓验证

插件源码和业务测试只放在相邻的 `switchly-plugins` 仓库，宿主的公开能力以 [API 参考](docs/plugins/plugin-api-reference.md) 为准。构建需要 Node.js 20+ 和 Python 3；运行 App 不需要 Node 或 Python。外仓执行 `npm test && npm run build`，宿主执行 `make prepare-plugins`，按 `Plugins/bundled-plugins.lock.json` 校验每个文件的 SHA-256。自定义制品路径用 `SWITCHLY_PLUGIN_SOURCE`；构建不联网、不自动更新锁文件。

变更预装版本或增添插件时，先审核外仓源码与资产，再构建并显式执行 `make update-plugin-lock`，审查 lock 差异；发布构建要求来源是已提交且干净的外仓提交。开发期可使用未提交的本地制品，但不能据此发布。`make build PLUGIN_FLAGS=--empty` 用于无预装独立构建验证，验证后执行正常 `make build` 恢复制品。

本地 SDK：`npm --prefix Plugins/sdk test`；CLI：`npm --prefix Plugins/cli test`。使用 `node Plugins/cli/bin/switchly-plugin.js --help` 查看真实命令。CLI 的 `build` 校验后复制单入口 JS，不负责 TypeScript 转译。发布前的类型消费验证需要 TypeScript 编译器，包自身无运行依赖。

`make plugin-verifier` 构建独立真实 JSC 验证工具；CLI 的 `verify <插件目录> --host <工具路径>` 在单独可终止进程内验证入口与 render，使用假系统能力，不读取真实授权目录。

### 私有插件仓库的 CI 读取

当前 `leungingit/switchly-plugins` 是私有仓库。宿主 Actions 的默认 `GITHUB_TOKEN` 不能跨仓读取，需在宿主仓库配置 Actions secret `SWITCHLY_PLUGINS_READ_TOKEN`，使用仅对插件仓库授予 Contents 只读权限的令牌。令牌值只通过 GitHub 的 secret 界面保存，不写入代码或日志；checkout 完成后不保留凭据。来自 fork 且拿不到 secret 的工作流会明确停止，不能改用有写权限的 `pull_request_target` 绕过。
