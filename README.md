# Switchly

[![CI](https://github.com/leungingit/switchly/actions/workflows/ci.yml/badge.svg)](https://github.com/leungingit/switchly/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/leungingit/switchly?sort=semver)](https://github.com/leungingit/switchly/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2012%2B-lightgrey.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)

> A native macOS menu-bar app for fast window preview and switching.

Switchly lets you preview the open windows of your applications with a global
shortcut and switch to the one you clicked in a single step. **Fully local — no
network access, and nothing leaves your Mac.**

## Features

- **Window preview panel** — press a global shortcut to see live thumbnails of
  open windows and click through to any of them
- **Per-app shortcuts** — bind your own hotkeys to the apps you use most, with
  several apps allowed to share one shortcut
- **Workspace bar** — a dock-style hover strip for previewing and jumping
  between windows
- **Preview strategies** — "all windows" or "configured apps only"
- **Auto-switch** — when a targeted app has exactly one window, switch straight
  to it without showing the panel
- **Thumbnail pre-warming** — background monitoring keeps previews instant
- **Usage statistics** — a local-only chart of how often you use preview and
  quick switch, split by keyboard and mouse, with an estimate of the time saved
  versus mouse-only workflows; stored on this Mac, never uploaded, one-click clear
- **Menu-bar only** — no Dock icon (`LSUIElement`), minimal footprint

## Requirements

- macOS 12.0 or later
- Xcode 15.0 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — the Xcode project is
  generated from `project.yml`

## Install

Download the latest `Switchly-<version>.zip` from the
[Releases](https://github.com/leungingit/switchly/releases/latest) page, unzip it,
and move `Switchly.app` to `/Applications`.

Verify the download first:

```sh
shasum -a 256 -c Switchly-<version>.zip.sha256
```

> **Architecture:** published builds are **Apple Silicon (arm64) only** and will
> not launch on Intel Macs. Building from source on an Intel Mac still works —
> Xcode targets the host architecture by default.

> Unless the release notes say otherwise, published builds are **ad-hoc signed
> and not notarized**, so Gatekeeper warns on first launch. Right-click the app
> and choose *Open*, or run:
>
> ```sh
> xattr -dr com.apple.quarantine /Applications/Switchly.app
> ```

## Build from source

```sh
git clone https://github.com/leungingit/switchly.git
cd Switchly

brew install xcodegen

make bootstrap   # generate Switchly.xcodeproj from project.yml
make build       # Debug build
make test-unit   # unit tests (what CI runs)
make run         # build and launch
```

Run `make help` to see every target. `./build.sh` performs a Release build and
packages a zip without needing the Makefile.

## Permissions

Switchly needs two system permissions to work:

- **Accessibility** — required to enumerate and focus application windows via
  `AXUIElement`
- **Screen Recording** — required to capture window thumbnails; without it the
  app falls back to app icons plus window titles, and switching still works

Grant them in *System Settings → Privacy & Security*. All processing happens
locally in memory: thumbnails are never persisted or uploaded. See
[PRIVACY_POLICY.md](PRIVACY_POLICY.md) for the full statement.

> With ad-hoc signing every rebuild produces a new code signature, and macOS may
> ask you to re-grant these permissions. Signing with a stable certificate
> avoids that — see below.

## Signing

Signing is disabled by default so that a fresh clone builds with no Apple
Developer account: `Config/Base.xcconfig` (wired into every configuration via
`project.yml`) sets `CODE_SIGN_IDENTITY` to `-` (ad-hoc). Resolution order,
highest wins:

1. `make build SIGN_IDENTITY="…"` — explicit one-off override
2. your local, git-ignored `Config/Local.xcconfig`
3. `Config/Base.xcconfig` defaults (ad-hoc; what CI uses)

```sh
make build SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
make dist  SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

Developing on Switchly itself? You probably want a **stable** signing identity
so macOS stops resetting the Accessibility / Screen Recording permissions after
every rebuild: run `Scripts/create-dev-cert.sh` once, then copy
`Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored, so
your certificate name / Team ID never reach GitHub). The full recipe is in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Project structure

```
App/          → app entry point (SwitchlyApp, AppDelegate)
Models/       → data models and enums
ViewModels/   → view models (MVVM)
Views/        → SwiftUI and AppKit views
Services/     → accessibility, window monitoring, thumbnails, shortcuts, settings
Utilities/    → logging, theming, window-match rules
Resources/    → Info.plist, asset catalog, localizations
Supporting/   → entitlements
Tests/        → unit tests and UI tests (skeleton)
Scripts/      → one-off tooling
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for a per-directory breakdown and the
coding guidelines.

## Verifying the tree before you publish

`./verify.sh` runs a pre-flight check: toolchain, project layout, version
consistency, and — most importantly — that no build artifacts, credentials, or
personal data are tracked by git. `./verify.sh --release` is the same check
with the CHANGELOG requirement made fatal; `make release-*` and the release
workflow run it that way.

See [docs/RELEASING.md](docs/RELEASING.md) for the full versioning rules and the
step-by-step release procedure.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and
the [Code of Conduct](CODE_OF_CONDUCT.md) first. Report security issues
privately, following [SECURITY.md](SECURITY.md).

Release history is documented in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)
