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
| Xcode | 15.0+ | Full Xcode, not just Command Line Tools |
| XcodeGen | latest | `brew install xcodegen` — the `.xcodeproj` is generated |

### Bootstrap and build

```bash
git clone https://github.com/leungingit/switchly.git
cd Switchly

brew install xcodegen

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
App/           app entry point (SwitchlyApp, AppDelegate)
Models/        data models and enums
ViewModels/    view models (MVVM)
Views/         SwiftUI / AppKit views
Services/      accessibility, window monitoring, thumbnails, shortcuts, settings
Utilities/     logging, theming, window-match rules
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
  `Utilities/WindowMatchRules.swift` and `Services/AccessibilityService.swift`
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
[`Utilities/WindowMatchRules.swift`](Utilities/WindowMatchRules.swift) for the
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
[docs/RELEASING.md](docs/RELEASING.md).

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
