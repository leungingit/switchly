# Changelog

All notable changes to Switchly are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- CI could not build the project: `xcodegen` 2.46 defaults to the `xcode16_0`
  project format (`objectVersion = 77`), which the `macos-14` runner's Xcode 15.4
  refuses to open. `project.yml` now pins `projectFormat: xcode15_0`
  (`objectVersion = 60`), so the generated project matches the Xcode 15.0
  minimum the README advertises — and can be opened by Xcode 15.x again, which
  the committed project could not.
- Documentation corrected against the shipped build. `README.md` and
  `docs/RELEASING.md` both claimed published builds were Apple Silicon
  (arm64) only; a `Release` build is in fact **universal** (`ARCHS = arm64
  x86_64`, `ONLY_ACTIVE_ARCH = NO`) and runs on Intel Macs too. The README
  feature list also conflated the workspace bar with the Dock preview, and was
  missing pointer triggers, workspaces, Dock preview, preview interaction modes,
  window controls, appearance options, launch at login and localization.

## [1.1.0] - 2026-10-10

### Added

- Usage statistics. The menu bar gains a **Statistics…** item (and the popover a
  matching button) that opens a local-only panel: it charts how often the preview
  panel and the panel-less quick switch are used, split into keyboard and mouse,
  and estimates the time saved versus doing the same actions with the mouse. The
  counters are written off the main thread (coalesced, atomic whole-file replace),
  the efficiency baseline is editable in place, and nothing is uploaded — the
  "no third-party analytics" promise is unchanged, see `PRIVACY_POLICY.md`.
- Window controls — close / minimize / zoom, the real macOS buttons, backed by the
  Accessibility API — are now available on every preview surface: the enlarged
  preview's info bar (always visible, for the window you are about to switch to),
  the window list rows and the grid cards (on hover or selection), and the Dock
  preview cards, which now share the same component instead of their own copy.
- The full-screen preview mode now puts the highlighted window across the whole
  screen behind the panel. The panel keeps its image + list layout and stays in
  front (a separate, click-through window at a lower level draws the image), so
  the parts of the window the panel covers are still visible while the panel
  keeps the keyboard and the pointer.
- Enlarged preview panel. Preferences → General → Preview → "Preview interaction"
  now offers **Large preview** (85% of the screen's visible frame) and **Full screen
  preview** (fills it, with a 24 pt margin): the highlighted window is shown as one
  large image beside the vertical window list, and minimized windows are labelled
  instead of showing a stale screenshot as if it were live. Hovering a row swaps the
  large image after a configurable delay (0.1–1.0 s, default 0.4 s); arrow keys and
  Tab swap it immediately. The default stays **Highlight only**, so an upgrade changes
  nothing until it is enabled.
- Tiered window-thumbnail cache. Thumbnails are now genuinely downsampled per use
  (grid, enlarged preview, full screen) instead of keeping a full-resolution window
  bitmap behind a small logical size, and each tier has its own byte and entry budget
  so a large preview can no longer evict the whole grid cache. A busy workspace's
  thumbnail memory drops from hundreds of megabytes to tens. The tier is part of the
  cache key, which is what let the enlarged preview be added without touching the
  other two preview surfaces.
- Local development signing support that survives rebuilds: `Config/Base.xcconfig`
  (ad-hoc by default) includes an optional git-ignored `Config/Local.xcconfig`
  where a stable identity — a local self-signed certificate via the new
  `Scripts/create-dev-cert.sh`, or your own Apple Developer Team ID — can be
  configured without ever committing it. Ends the per-rebuild loss of the
  Accessibility / Screen Recording grants on developer machines. CI and fresh
  clones are unaffected.
- Motion language for the whole app, centralized in `Utilities/MotionTokens.swift`:
  panels fade + rise in and zoom toward the activated card on dismiss; the dock
  preview grows out of the hovered Dock icon and springs between icons; window
  cards stagger in, lift on hover and keyboard selection; thumbnails cross-fade
  in with a pulsing loading skeleton; search filtering animates the grid with a
  numeric count roll; workspace switches slide the strip in the direction of
  travel; the onboarding permission checkmark draws itself with a progress bar.
  Every animation honors the system "Reduce motion" preference.
- Single-window auto-switch and the current-app window shortcut now pulse the
  menu-bar icon (with a brief checkmark) so an LSUIElement app still confirms
  that a background switch happened.
- `SECURITY.md` with the threat model, reporting process, and release
  verification steps.
- `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, issue forms, and a pull request
  template.
- Release workflow: pushing a `vX.Y.Z` tag now builds, packages, checksums, and
  publishes a GitHub Release. Optional Developer ID signing and notarization
  activate when the corresponding repository secrets are configured.
- Dependabot configuration for GitHub Actions and the `HotKey` dependency.
- `make test-unit`, `make zip`, and `make github-release` targets.
- `docs/RELEASING.md` — the complete versioning and release guide: SemVer rules
  for an app, every `make version` / `bump-*` / `release-*` target and what each
  one touches, what the release workflow does with a tag, the optional signing
  and notarization secrets, how to withdraw a release, and a copy-paste release
  checklist.

### Changed

- Cutting a release now treats **untracked files** as a dirty tree.
  `Scripts/version.sh` only looked at `git diff`, which sees tracked
  modifications alone, so a release cut after a partial `git add` could tag a
  commit that was missing files the working tree still had — publishing a tree
  without them. The guard also checks `git ls-files --others`.
- Repository links, badges and the privacy-policy contact now point at the
  project's public home, `github.com/leungingit/switchly`.
- Release tooling. `make release-patch|minor|major` is now atomic: it validates
  the tree, promotes this file's `[Unreleased]` section into a dated version
  section, bumps `Resources/Info.plist`, commits, and tags `vX.Y.Z` in one step
  (it still never pushes — `git push origin main --tags` hands the tag to CI).
  `make bump-*` keeps its old meaning, edit the numbers and commit nothing, but
  now rejects a version that is not plain `X.Y.Z` instead of silently dropping a
  pre-release suffix. `./verify.sh --release`, which the release workflow runs,
  fails rather than warns when there is no CHANGELOG section for the version
  being shipped, so a release can no longer publish with empty release notes.
  `make package` is now an alias for the deterministic `make zip`, so local and
  CI artifacts share one name: `Switchly-<version>.zip`. `Resources/Info.plist`
  is stored in the key order Apple's plist tools write, so a bump is a one-line
  diff rather than an unrelated reshuffle of every key.
- Workspace bar redesign. The panel now carries a header (workspace glyph, name,
  live window count, and an "n / N" position pill), a card strip, and a footer
  with one indicator pill per workspace plus the keyboard vocabulary
  (up/down switch workspace, left/right select window, return switch). Cards
  gained the same affordances as the other preview surfaces: traffic-light window
  controls and a selection checkmark on hover/selection, an accent glow under the
  selected card, an app-icon chip in the title row, and a dashed rim that marks a
  placeholder card as "app not running" rather than a failed preview. Switching
  workspaces now animates as one motion at a shared duration: the strip slides
  with a directional move + fade + slight scale, the header cross-fades, the
  position pill rolls its digits, the indicator pill travels, and the panel width
  morphs — all under the new MotionTokens.workspaceSwitchDuration. The indicator
  pills are also a control: tapping one jumps to that workspace with the same
  slide. The panel refreshes its cards when a window is closed from a card while
  it is open.
- The selected workspace card’s accent ring is no longer clipped. Scrolling the
  selected card into view used to align it to the strip edge, which pushed the
  card — and the 1.03 selection scale that grows it past its frame — into the
  ScrollView clip; it now centers (which clamps to the natural position for the
  first and last card), and the strip carries 12 pt of side padding so a resting
  card always has room for its scaled ring. The overflow edge fade is a fixed
  16 pt band instead of 4% of the panel, which used to swallow half of the first
  card and read as a cut-off border.
- The workspace bar’s placeholder and loading thumbnails no longer render as a
  solid block: a bare RoundedRectangle used as a view paints itself with the
  foreground style, which covered the intended translucent skeleton fill. They
  are filled explicitly now. (The Dock preview and the preview grid still carry
  the same pattern and need the same one-line fix.)
- The full-screen preview mode's panel is now 72% of the visible frame instead of
  filling it: with a full-screen image behind the panel, a panel that covered the
  screen would hide the very thing the mode exists for.
- Thumbnail capture no longer runs on the caller's thread. The CoreGraphics call
  can block for its 1.5 s timeout, which used to freeze the UI while a card asked
  for an image; captures now run on a dedicated work queue.
- The preview panel's size is derived from the target screen's visible frame instead
  of a fixed 800×500 pt, and the dismissal animation's zoom anchor is normalized
  against the panel's real size, so the panel collapses into the activated card at any
  panel size. The panel can no longer hang off a small display.
- Thumbnail captures are requested in display pixels per tier, with an
  aspect-preserving cap for the enlarged preview (2560×1600) so a 5K/6K display cannot
  push a single cached image past its tier's budget.
- Signing now defaults to ad-hoc across every target, so a fresh clone and CI
  build without an Apple Developer account. Pass
  `SIGN_IDENTITY="…"` to `make build` / `make dist` to sign for real.
- CI runs with least privilege (`contents: read`), cancels superseded runs,
  caches Swift Package Manager checkouts, and fails if build artifacts are
  tracked.
- Both workflows now run `./verify.sh` as a hard gate — CI before anything is
  generated, and the release job before the assets become public.
- The release job runs the unit test suite on the tagged commit before it
  builds, so a release can no longer ship an untested tree.
- The release tag filter is now the plain glob `v*`; the strict `vX.Y.Z`
  validation lives in the first step, where it produces a readable error.
- Homebrew bottles are cached in both workflows, so `brew install xcodegen` no
  longer re-downloads on every run.

### Fixed

- `CODE_OF_CONDUCT.md` pointed readers at "the contact address listed in
  SECURITY.md", but `SECURITY.md` carried no address at all. Both now name the
  maintainer address, so the enforcement path is reachable.
- `verify.sh` no longer flags that published contact address as a leak. Its
  personal-data heuristic matches consumer mail domains, which is exactly what
  the project now intends to publish; the one documented address is dropped by
  exact match, and every other address still fails the check.
- The Dock-hover preview could stay on screen until something else dismissed it
  (a card click, Escape) instead of disappearing when the pointer left the Dock.
  `DockPreviewPanel.show` refreshes the window list before it orders the panel
  on screen, and that Accessibility work can pump the run loop, so the monitor's
  50 ms poll tick could land while the panel was claimed but not yet visible. The
  tick read that in-flight presentation as a state desync and cleared
  `isShowing`/`currentIcon`, so the panel appeared with the monitor no longer
  tracking it and the "pointer left the Dock" path — gated on that flag — never
  scheduled a hide. The monitor now tracks the in-flight presentation explicitly
  and the panel reports when it has actually been ordered on screen, and
  dismissal follows the panel's real visibility instead of the flag, so a visible
  preview is always dismissed once the pointer leaves both the Dock and the
  panel. Both halves are covered by headless tests in `DockHoverMonitorTests`;
  the desync was caught twice in the 2026-10-09 logs.
- The workspace and preferences app pickers could not find most installed apps.
  Both lists were built from `NSWorkspace.shared.runningApplications` and dropped
  every `com.apple.*` bundle id, so an app that was installed but not running was
  simply absent, and no Apple app (Safari, Terminal, Xcode, Mail, …) could ever be
  added. A new `InstalledAppsService` enumerates the standard application
  directories (`/Applications`, `/System/Applications`, `~/Applications`, …), merges
  in anything running from elsewhere, and re-enumerates when apps launch or quit so
  the list cannot go stale behind an open window. On the development machine this
  goes from a couple of dozen running non-system apps to 427 installed apps, and
  both pickers now share one search predicate instead of carrying their own copy.
  Switchly itself is still never offered, and a `.app` with no bundle identifier —
  which cannot be launched by id — is still skipped. Display names that consist only
  of characters which render as nothing (Apple ships two such bundles,
  `com.apple.MediaRemoteUI` and its service, whose name is a single bidi mark) fall
  back to the next candidate instead of showing a blank row.
- A window whose CoreGraphics capture comes back blank — Electron apps such as
  Lark/Feishu do this — could never be previewed by the enlarged panel: the
  background preheat path had no ScreenCaptureKit fallback, so the cache never
  filled while the same window captured fine on demand, and the enlarged preview
  spun on its loading state forever. On-demand and background captures now share
  one pipeline (CoreGraphics with retries, then ScreenCaptureKit), and the
  enlarged preview reads the same cache the grid does. Verified against the
  running app: Feishu's window now captures through the fallback.
- A window that failed its first capture was never retried by the refresh timer.
  Window identity was recorded only when a capture succeeded, so the timer had
  nothing to rebuild it from and skipped that window indefinitely.
- An uncapturable window no longer reports "loading" forever. Views ask the
  service whether the entry is in its failure cooldown and show the app icon with
  "Preview unavailable" instead, then pick the window up again automatically once
  the cooldown expires.
- The exact same thumbnail interest was logged several times a second for every
  tier (about three lines per second of identical `count=0` entries). Only real
  changes are logged now.
- The thumbnail cache's byte limit now actually applies. Entries were stored without a
  cost, so `totalCostLimit` had no effect and only the entry count bounded memory —
  the documented 50 MB ceiling was inert.
- A failed thumbnail capture is reported to the UI, so a window that cannot be captured
  (no screen-recording grant, a blank/unrendered backing store, DRM content) falls back
  to the app icon instead of pulsing a loading skeleton forever.
- A partially configured signing setup (certificate without Apple ID
  credentials) now fails the release with an explicit message. Previously the
  notarization step was skipped silently, which produced a Developer ID signed
  but un-notarized build — blocked by Gatekeeper while no longer looking like
  an ordinary ad-hoc build.
- Window switching resolved the wrong window when several windows of an app
  share identical geometry. Resolution is now a closed loop: each candidate is
  raised and then verified against the CoreGraphics window order, falling back
  to the next candidate instead of silently failing.
- Z-order direction is now calibrated per application instead of assuming a
  single ordering. Chrome lists windows front-to-back while Feishu lists them
  back-to-front.
- Transparent same-size overlay surfaces (such as Electron apps' watermark
  widgets) are filtered out with a relative size threshold, so preview cards
  point at the real window.

## [1.0.0] - 2026-08-07

### Added

- Initial open-source release.
- Global shortcut that opens a preview panel with live thumbnails of open
  windows; click a card to switch to that window.
- Per-application shortcuts, with several apps allowed to share one shortcut.
- Dock-style workspace bar with hover preview and quick switching.
- Preview strategies: all windows, or configured apps only.
- Automatic switch when a targeted app exposes exactly one window.
- Background thumbnail pre-warming.
- Menu-bar-only app (`LSUIElement`); no Dock icon.
- Settings persisted to `UserDefaults` under `com.switchly.settings`, with
  backward-compatible reads of the legacy `com.windowsnap.settings` key.
- English and Simplified Chinese localizations.
- MIT license and privacy policy.

[Unreleased]: https://github.com/leungingit/switchly/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/leungingit/switchly/releases/tag/v1.1.0
[1.0.0]: https://github.com/leungingit/switchly/releases/tag/v1.0.0
