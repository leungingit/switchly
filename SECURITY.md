# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Use GitHub's private reporting flow instead:

1. Go to the **Security** tab of the repository.
2. Click **Report a vulnerability**.
3. Describe the issue and, if possible, include a proof of concept.

If private reporting is unavailable to you, email
**liangkaijun52013@gmail.com**, or open a minimal public issue that says only
*"I would like to report a security issue privately"* — with no details — and a
maintainer will arrange a private channel.

### What to include

- Affected version or commit
- macOS version and chip architecture
- Impact: what an attacker gains, and under what preconditions
- Reproduction steps or a minimal proof of concept
- Any suggested fix

### What to expect

| Stage | Target |
|---|---|
| Acknowledgement of your report | within 3 business days |
| Initial assessment and severity triage | within 7 business days |
| Fix or documented mitigation | depends on severity, discussed with you |

We will credit you in the release notes unless you ask us not to.

---

## Supported versions

Only the latest release receives security fixes.

| Version | Supported |
|---|---|
| latest release | ✅ |
| `main` branch | ✅ (development) |
| older releases | ❌ |

---

## Threat model

Switchly is a **local-only** macOS utility. Understanding its design makes it
much easier to judge whether something is actually a vulnerability.

### What Switchly does

- Enumerates windows of other applications through the Accessibility API
  (`AXUIElement`) and the CoreGraphics window list (`CGWindowList*`).
- Captures window thumbnails with `CGWindowListCreateImage`.
- Registers global hotkeys (`HotKey`).
- Stores preferences in `UserDefaults` under `com.switchly.settings`.
- Writes operational logs to `~/Library/Logs/Switchly/Switchly.log`.

### Trust boundaries

- **The app has no network access.** There is no networking entitlement and no
  HTTP client. Any change that introduces network I/O is a design violation and
  should be reported as a security issue.
- **No data leaves the machine.** Thumbnails are held in memory and released;
  preferences and logs stay on local disk.
- **Enormous system privilege by design.** Accessibility and Screen Recording
  access mean a compromised Switchly binary is equivalent to a compromised
  session. Protecting the integrity of the release pipeline matters more here
  than in a typical app — this is why releases ship a SHA-256 checksum and,
  when the signing secrets are configured, a notarized Developer ID build.

### In scope

- Arbitrary code execution, privilege escalation, or sandbox escape
- Weaknesses in the build or release pipeline (workflow injection, credential
  leakage, unsigned artifact substitution)
- Leakage of user data off the machine
- Injection into window titles / app names causing the app to misbehave in a
  way that leads to the above
- Path traversal or symlink attacks in file handling

### Out of scope

- The fact that an app requesting Accessibility / Screen Recording permissions
  can read other apps' windows — that is its documented purpose.
- Vulnerabilities in macOS itself, in Xcode, or in the `HotKey` dependency
  (report those upstream; we will still bump the pinned version).
- An attacker who already has local code execution as the user.
- Denial of service from extremely large numbers of open windows.
- Issues requiring a jailbroken or already-compromised machine.

### A note on permissions and logs

The log file records application names and window titles from your machine.
It never records thumbnail image data or keystrokes, and it is never uploaded.
Review it before attaching it to a public issue.

---

## Verifying a release

Every release publishes `Switchly-<version>.zip` plus a `.sha256` file:

```sh
shasum -a 256 -c Switchly-<version>.zip.sha256
```

Then inspect the signature:

```sh
codesign --display --verbose=4 /Applications/Switchly.app
spctl --assess --type execute --verbose=4 /Applications/Switchly.app
```

If the release notes state that a build is ad-hoc signed rather than notarized,
Gatekeeper warnings for that build are expected and are not a vulnerability.

---

## Maintainer notes

- Secrets (`BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, `KEYCHAIN_PASSWORD`,
  `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`) live only in repository
  secrets. Never commit a certificate, `.p12`, provisioning profile, or `.env`.
- Workflows run with least privilege. `contents: write` is granted only to the
  release job; everything else is `contents: read`.
- Dependabot keeps the pinned GitHub Actions and the `HotKey` dependency current.
