# Versioning & Releases

How Switchly's version numbers work, and the exact steps that turn a commit on
`main` into a published GitHub Release.

Everything below is executable as written — the commands are the same ones CI
runs, and `Scripts/version.sh` is the single implementation behind all of them.

---

## 1. The two version numbers

Switchly carries two numbers, both stored in **`Resources/Info.plist`**, which is
the single source of truth:

| plist key | Example | Meaning | Visible to users |
|---|---|---|---|
| `CFBundleShortVersionString` | `1.4.0` | **Marketing version** — the one in the release tag, the download filename, and the CHANGELOG heading | About box, GitHub release title, `Switchly-1.4.0.zip` |
| `CFBundleVersion` | `7` | **Build number** — a monotonically increasing integer, reset to `1` on every version bump | Finder's *Get Info* |

Nothing else may hold a version. `Makefile`, `Scripts/version.sh`,
`verify.sh`, the release workflow and the app itself all *read* the plist; no
file duplicates the number, so they cannot drift apart.

### Why the plist is kept alphabetically sorted

`PlistBuddy` and `plutil` re-serialise a plist with its keys sorted. By keeping
`Info.plist` in that canonical order, a version bump is a **one-line diff**
instead of an unrelated reshuffle of every key. Add new keys in sorted position.

### Semantic Versioning

Switchly follows [SemVer](https://semver.org/spec/v2.0.0.html): `MAJOR.MINOR.PATCH`.

| Change | Bump | Example |
|---|---|---|
| A new user-visible feature, or a backwards-compatible behaviour change | **MINOR** | Usage statistics panel → `1.0.0` → `1.1.0` |
| A backwards-compatible bug fix only | **PATCH** | Dock preview stayed on screen → `1.1.0` → `1.1.1` |
| A change that breaks existing settings, shortcuts, or the supported macOS floor | **MAJOR** | Dropping macOS 12 support → `1.x.y` → `2.0.0` |

Because this is an app rather than a library, "breaking" means **user-visible
breakage**: an upgrade that silently loses a user's configured shortcuts or
requires re-granting permissions is a MAJOR change, not a MINOR one.

Pre-release suffixes (`1.2.0-beta.1`) are **not supported** by the tooling:
`version.sh` rejects anything that is not a plain `X.Y.Z` rather than silently
dropping the suffix and producing `1.2.1`. To ship a pre-release, tag a normal
version and mark the GitHub Release as a pre-release instead (a tag containing a
`-` is published as a pre-release automatically).

---

## 2. The CHANGELOG contract

`CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
It has exactly one open section at all times:

```markdown
## [Unreleased]

### Added
- …
### Changed
- …
### Fixed
- …
```

**Every pull request adds a line under `[Unreleased]`.** That section is the
release notes' only input — nothing else is harvested — so a change that is not
written down there will not appear in the GitHub Release.

`make release-*` rewrites the file for you:

1. inserts `## [X.Y.Z] - YYYY-MM-DD` immediately below the `[Unreleased]` heading,
2. leaves the (now empty) `[Unreleased]` heading in place as the next cycle's inbox,
3. rewrites the trailing link definitions so `[Unreleased]` compares the new tag
   against `HEAD`.

The section headings are the conventional set: **Added**, **Changed**,
**Deprecated**, **Removed**, **Fixed**, **Security**. Write for a user, not for a
reviewer: say what changed in behaviour, not which file was touched.

---

## 3. Command reference

Run `make help` for the live list. Every target below is a thin wrapper over
`Scripts/version.sh`.

### Inspect

| Command | Effect |
|---|---|
| `make version` | Print `v1.4.0 (build 7)` from the plist |

### Move the number without releasing

These edit `Info.plist` **and nothing else** — they do not touch the CHANGELOG,
do not commit, and do not tag. Use them when you just need the number to move.

| Command | Effect |
|---|---|
| `make bump-patch` | `1.4.0` → `1.4.1` |
| `make bump-minor` | `1.4.0` → `1.5.0` |
| `make bump-major` | `1.4.0` → `2.0.0` |
| `make bump-build` | build `7` → `8` (marketing version untouched) |

### Cut a release

These are **atomic**: validate, promote the CHANGELOG, bump the plist, commit,
and create an annotated tag — all or nothing. They **never push**.

| Command | Effect |
|---|---|
| `make release-patch` | `1.4.0` → `1.4.1`, commit `chore: release 1.4.1`, tag `v1.4.1` |
| `make release-minor` | `1.4.0` → `1.5.0`, commit, tag |
| `make release-major` | `1.4.0` → `2.0.0`, commit, tag |

`release-*` refuses to run when:

- the working tree is dirty — **including untracked files**, so a release can
  never tag a commit that is missing files the working tree still has;
- the tag already exists (a version is released once);
- `[Unreleased]` is empty — unless you pass `--allow-empty` directly to
  `Scripts/version.sh`;
- `./verify.sh --release` fails, which it does when the CHANGELOG has no section
  for the version being shipped.

Useful flags on the script itself:

```sh
Scripts/version.sh release minor --dry-run       # run every check, change nothing
Scripts/version.sh release minor --allow-empty   # release an empty [Unreleased]
SKIP_VERIFY=1 Scripts/version.sh release minor   # skip the pre-flight gate
```

### Package and publish

| Command | Effect |
|---|---|
| `make dist` | Release build, copy `Switchly.app` into `build/` |
| `make zip` | `make dist` + deterministic `build/Switchly-<version>.zip` and `.sha256` |
| `make package` | Alias for `make zip` — local and CI artifacts share one name |
| `make release-build` | `bump-build` + `zip` (build numbers are never tagged) |
| `make github-release TAG=v1.4.0` | Create/push the tag and let CI publish (requires `gh`) |

---

## 4. Cutting a release, step by step

### 0. Preconditions

- You are on `main`, up to date with the remote.
- CI is green on the commit you are about to ship.
- You have push access to the repository.

### 1. Land everything

```sh
git switch main
git pull --ff-only
git status            # must be clean, untracked files included
```

### 2. Write the release notes

```sh
$EDITOR CHANGELOG.md  # add what changed under "## [Unreleased]"
```

### 3. Pre-flight

```sh
./verify.sh --release     # toolchain, layout, version, and the publication checks
make bootstrap && make build && make test-unit
```

`verify.sh` is the gate that stops credentials, build artifacts or personal data
from being published. `--release` additionally makes a missing CHANGELOG section
fatal instead of a warning.

### 4. Cut the release

Pick **one** bump:

```sh
make release-minor        # 1.0.0 -> 1.1.0
```

The tree is now committed and tagged locally. Nothing has been pushed.

### 5. Publish

```sh
git push origin main --tags
```

The tag is the trigger: `.github/workflows/release.yml` builds, packages,
checksums and publishes the GitHub Release. Do not also create a Release by hand.

### 6. Watch it

```sh
gh run watch --repo leungingit/switchly
gh release view v1.1.0 --repo leungingit/switchly
```

### 7. Verify the published artifact

```sh
gh release download v1.1.0 --repo leungingit/switchly
shasum -a 256 -c Switchly-1.1.0.zip.sha256
```

### 8. Post-release

- Confirm the README badges (CI, latest release) render.
- If the release changed permissions or settings, add a migration note to the
  release body.

---

## 5. What CI does with a tag

```
git push origin main --tags
        │
        ▼
Release workflow (macos-14, contents: write)
  1. Resolve tag            reject anything not matching vX.Y.Z
  2. Checkout the tag       fetch-depth: 0
  3. verify.sh --release    publication + CHANGELOG gate
  4. Install XcodeGen
  5. Info.plist == tag      refuses a tag that does not match the plist
  6. make bootstrap
  7. make test-unit         the tagged commit must pass its own tests
  8. Import certificate     only when BUILD_CERTIFICATE_BASE64 is set
  9. Check notarization     certificate without Apple ID credentials = hard fail
 10. make dist              Release build, ad-hoc unless a certificate was imported
 11. Notarize               only when signed
 12. Package                Switchly-<version>.zip + .sha256
 13. Compose notes          awk-extract the CHANGELOG section for this version
 14. gh release create      --verify-tag, pre-release when the tag contains "-"
```

Two deliberate design choices:

- **The version is checked in three places** — the tag, `Info.plist`, and the
  CHANGELOG section — so a release cannot ship with mismatched numbers or empty
  notes. All three fail loudly rather than publishing something inconsistent.
- **A Developer ID build that is not notarized is a hard failure.** Such a build
  is worse than an ad-hoc one: Gatekeeper still blocks it, but it no longer looks
  like an ordinary unsigned local build.

Artifacts published per release:

| Asset | Contents |
|---|---|
| `Switchly-<version>.zip` | `Switchly.app`, ad-hoc or Developer ID signed |
| `Switchly-<version>.zip.sha256` | SHA-256 of the zip |

Published builds are **universal** — `xcodebuild -configuration Release` uses
Xcode's default `ARCHS` (`arm64 x86_64`) with `ONLY_ACTIVE_ARCH = NO`, so the
bundle carries both an Apple Silicon and an Intel slice. `Debug` builds only the
active architecture, because `ONLY_ACTIVE_ARCH = YES` there. To publish an
arm64-only build instead, set `ARCHS: arm64` in `project.yml`.

---

## 6. Signing and notarization secrets

All optional. With none of them set, the workflow publishes an ad-hoc, unnotarized
build and the release notes explain the Gatekeeper workaround.

| Secret | Purpose |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Base64 of a `.p12` containing a *Developer ID Application* certificate |
| `P12_PASSWORD` | Password of that `.p12` |
| `KEYCHAIN_PASSWORD` | Any password; used for the throwaway CI keychain |
| `APPLE_ID` | Apple ID used by `notarytool` |
| `APPLE_TEAM_ID` | Your 10-character Team ID |
| `APPLE_APP_PASSWORD` | An app-specific password for that Apple ID |

Producing the certificate blob:

```sh
# In Keychain Access: export the "Developer ID Application" identity as .p12
base64 -i DeveloperID.p12 | pbcopy     # paste into the BUILD_CERTIFICATE_BASE64 secret
```

The set is **all-or-nothing**: if `BUILD_CERTIFICATE_BASE64` is set but any
`APPLE_*` value is missing, the workflow fails before the expensive build
instead of silently skipping notarization.

> Secrets are never readable back out of GitHub. Rotate by re-uploading.

---

## 7. Verifying a downloaded release

```sh
shasum -a 256 -c Switchly-<version>.zip.sha256
unzip -q Switchly-<version>.zip
codesign --verify --deep --strict --verbose=2 Switchly.app
spctl --assess --type execute --verbose=4 Switchly.app    # expect "rejected" for ad-hoc
```

The release workflow prints the same `codesign`/`spctl` output into its log, so
the signature of a published build is auditable after the fact.

---

## 8. When something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `working tree has uncommitted changes` | Tracked edits **or untracked files** | Commit or stash them; `git status --short` shows both |
| `tag vX.Y.Z already exists` | The version was already released | Pick a new version; only delete the tag if it was never pushed |
| `CHANGELOG has no '## [X.Y.Z]' section` | Bump without a release, or a hand-edited CHANGELOG | `make release-*` writes it; if you bumped by hand, add the section yourself |
| Workflow fails at "Verify Info.plist version matches the tag" | Tag and plist disagree | Bump the plist, commit, move the tag: `git tag -f vX.Y.Z` then force-push the tag |
| Workflow fails at "Check notarization credentials" | Partial secret set | Add the missing `APPLE_*` secrets, or remove `BUILD_CERTIFICATE_BASE64` to go ad-hoc |
| Release body is one line ("Release vX.Y.Z.") | The CHANGELOG had no section for that version | Edit the release body; fix the CHANGELOG for next time |
| Release published with the wrong assets | Usually a tag pointing at an older commit | Delete the release and tag, fix, re-tag |

### Withdrawing a release

```sh
gh release delete v1.1.0 --yes --cleanup-tag    # deletes the Release and the tag
```

**Never re-use a version number.** If `v1.1.0` was ever public, ship `v1.1.1`
instead — clients and caches may already have seen the old one.

---

## 9. GitHub repository settings that a release depends on

These live in the repository's own settings, not in the code, and the docs link
to them:

| Setting | Why |
|---|---|
| **Discussions** enabled | `.github/ISSUE_TEMPLATE/config.yml` links to `/discussions`; otherwise that link 404s |
| **Private vulnerability reporting** enabled (Settings → Code security) | `SECURITY.md` and the issue-template link point at `/security/advisories/new` |
| **Actions** enabled with *Read and write* default workflow permissions, or the per-workflow `contents: write` used here | The release job needs to create the Release |
| **Description + topics** filled in | Discoverability for a public repository |

---

## 10. Release checklist

Copy this into the release pull request or issue.

```markdown
- [ ] Everything intended for this release is merged to `main`
- [ ] `CHANGELOG.md` — `[Unreleased]` describes every user-visible change
- [ ] Version bump chosen: patch / minor / major (and justified by SemVer)
- [ ] `./verify.sh --release` passes
- [ ] `make build` and `make test-unit` pass locally
- [ ] CI is green on the commit being shipped
- [ ] `make release-<part>` run (creates commit + tag, does not push)
- [ ] `git push origin main --tags`
- [ ] Release workflow green; assets present (`.zip` + `.sha256`)
- [ ] Release notes read correctly (not the one-line fallback)
- [ ] Checksum verified against the downloaded asset
- [ ] README badges render
```

---

## 11. Day-to-day version hygiene

- **One source of truth.** Never hard-code a version in Swift, the Makefile, or
  a workflow; read `Resources/Info.plist`.
- **Never hand-edit a released section of the CHANGELOG.** Corrections belong in
  a new release.
- **Build numbers are not versions.** `make release-build` exists for local
  iteration; it never tags.
- **Tags are immutable once pushed.** Move one only if the release has not been
  consumed, and delete the Release at the same time.
- **`verify.sh` runs in CI before anything is generated**, so the publication
  checks always describe the committed tree rather than a freshly generated one.
