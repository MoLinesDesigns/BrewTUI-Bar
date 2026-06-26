# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Brew-TUI-Bar is a native macOS menu bar agent (SwiftUI, Swift 6) that companions the `brew-tui` CLI. It watches Homebrew for outdated packages, service status, CVE alerts, and cross-machine sync, surfacing them from a status-item popover. It is a `LSUIElement` app: no Dock icon, no main window — the entry point is `AppDelegate`, not the `App` scene.

## Build / test / run

The project is **Tuist-generated**. Never edit `*.xcodeproj`/`*.xcworkspace` by hand — they are regenerated from `Project.swift`. Always regenerate after touching `Project.swift` or `package.json`.

```bash
npm run generate   # tuist generate --no-open  (regenerate the workspace)
npm run build      # xcodebuild ... build       (Debug, signing disabled)
npm test           # xcodebuild ... test        (Debug, signing disabled)
```

Run a single test (after `npm run generate`):

```bash
xcodebuild test -workspace Brew-TUI-Bar.xcworkspace -scheme Brew-TUI-Bar \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -only-testing:Brew-TUI-BarTests/ServiceTests/<testName>
```

Tests use **Swift Testing** (`import Testing`, `@Test`/`#expect`), not XCTest. CI (`.github/workflows/ci.yml`) installs Tuist 4.39.0, then runs generate → build → test on `macos-latest`.

## Versioning & release

- **Single source of truth for the app version is `package.json` (`version`)**. `Project.swift`'s `readMarketingVersion()` reads it at generate time and feeds `MARKETING_VERSION`. Bump the version there, never in the Xcode project. Override per-build with `MARKETING_VERSION=x.y.z tuist generate`. `package.json` here is **not** an npm package — it only carries the version; do not add `bin`/`files` or `npm publish` this repo.
- App release: `NOTARY_PROFILE=brewbar-notary ./scripts/release.sh` (sign → archive → export → notarize → staple → SHA256). The script runs `tuist clean` first because Tuist caches the *compiled* manifest and would otherwise ship a stale version. It prints the `SHA256:` and writes `build/Brew-TUI-Bar.app.zip` + `.app.zip.sha256`. `scripts/notarize.sh` notarizes an already-exported archive.

### Coordinated two-repo release (read before any version bump)

This app ships in lockstep with the **`brew-tui` CLI**, a *separate* repo and the real npm package. `AppDelegate`'s `VersionChecker` warns when the two versions drift, so **both must be bumped to the same version together**.

- **`brew-tui` CLI** — `/Volumes/SSD/Projects/Brew-TUI`, repo `MoLinesDesigns/Brew-TUI`, npm package `brew-tui` (the one users `npm install -g`). This is the npm publish target — `brew-tui-bar` is not.
- **This app** — `/Volumes/SSD/xCode_Projects/Brew-TUI-Bar`, repo `MoLinesDesigns/Brew-TUI-Bar`.
- **The app's binary GitHub Release lives in the CLI repo `MoLinesDesigns/Brew-TUI`, not in `Brew-TUI-Bar`** — the cask's `url`/`homepage` point there. (`Brew-TUI-Bar` holds only source + the `vX.Y.Z` source tag.)
- **Cask**: `MoLinesDesigns/homebrew-tap`, cloned locally at `/opt/homebrew/Library/Taps/molinesdesigns/homebrew-tap/Casks/brew-tui-bar.rb`. Bump `version` + `sha256` (the SHA from `release.sh`), `brew style` it, commit, push `main` directly.
- **Ordering is enforced**: the CLI's `prepublishOnly` runs `scripts/check-brewtuibar-release.mjs`, which hits the GitHub API and fails unless the `vX.Y.Z` release in `MoLinesDesigns/Brew-TUI` already has both `Brew-TUI-Bar.app.zip` and `Brew-TUI-Bar.app.zip.sha256` assets. So the binary release must exist **before** publishing the CLI. Emergency bypass: `SKIP_BREWTUIBAR_CHECK=1`.
- `npm publish` requires a one-time password (the account enforces 2FA) unless you use an **Automation** token (the only token type that bypasses 2FA).

Full release sequence for version `X.Y.Z`:
1. App: bump `package.json` → X.Y.Z, commit, `git tag vX.Y.Z`, push `main` + tag (this repo).
2. App: `NOTARY_PROFILE=brewbar-notary ./scripts/release.sh` → notarized zip + SHA256.
3. App: `gh release create vX.Y.Z -R MoLinesDesigns/Brew-TUI --target main` uploading `build/Brew-TUI-Bar.app.zip` and `build/Brew-TUI-Bar.app.zip.sha256`.
4. Cask: bump `version` + `sha256` in the tap, commit, push.
5. CLI: bump `package.json` → X.Y.Z (`npm version X.Y.Z --no-git-tag-version`), commit, push `main`, then `npm publish --access public --otp=<code>` (its prepublish guard now passes because step 3 exists).

## Signing config (in `Project.swift`)

Debug deliberately relaxes signing (Automatic / Apple Development / Hardened Runtime OFF) so Xcode Previews' JIT injection works. Release uses Manual / Developer ID Application / Hardened Runtime ON. `PRODUCT_NAME`/`EXECUTABLE_NAME` are forced to the hyphenated `Brew-TUI-Bar` (the cask + installer expect that bundle name) while `PRODUCT_MODULE_NAME` is the identifier-safe `Brew_TUI_Bar` — that underscore form is the module name you `@testable import`.

## Architecture

```
Sources/App/      AppDelegate (real entry point), status item, popover lifecycle, badge
Sources/Models/   AppState (central store) + value types (OutdatedPackage, BrewService, …)
Sources/Services/ brew subprocess layer, license, scheduler, cross-process monitors
Sources/Views/    PopoverView and friends (SwiftUI)
```

- **`AppState`** (`@MainActor @Observable`) is the single observable store. The whole UI reads from it. It owns refresh coalescing (`refreshTask` + `pendingCoalescedForce` serialize overlapping refreshes) and the streaming upgrade state machine (`runUpgradeStream` consumes `BrewUpgradeEvent`s into `installProgress`).
- **Dependency injection via `BrewChecking`**: `AppState` depends on the `BrewChecking` protocol, not the concrete `BrewChecker`. Production injects `BrewChecker`; tests inject `StubBrewChecker`. Keep `BrewChecking` minimal — only what `AppState`/`SchedulerService` consume. `streamUpgrade` has a protocol default that bridges non-streaming stubs to the event stream.
- **`BrewProcess`** is the one place that spawns `brew`. It resolves the brew path (Apple Silicon → Intel → Linuxbrew fallback), drains stdout incrementally via a `readabilityHandler` (filling the ~64KB kernel pipe buffer used to deadlock large `brew outdated --json`), enforces a timeout, and sets `HOMEBREW_NO_AUTO_UPDATE` by default. The `OnceGuard` ensures exactly-one continuation resume across the termination-handler thread and the timeout task.
- **`AppDelegate`** drives a careful NSPopover lifecycle: the `NSHostingController` is recreated on every show (reusing it breaks the responder chain after a sheet dismiss), `makeKey()` is deferred one runloop tick, and a global click-outside monitor backstops `.transient` auto-close. Touch this code carefully — the comments document real bugs.

## Cross-process contract with `brew-tui`

The app shares state with the `brew-tui` CLI and its backend through files under `~/.brew-tui/`. **These are contracts — field names and semantics must stay in sync with the CLI/backend:**

- `license.json` — `LicenseChecker` reads it. v2 format: `LicenseData` payload + Ed25519 `sig`. Legacy v1 (encrypted/iv/tag) envelopes are **rejected** (forgeable). Degradation thresholds mirror the backend's `src/lib/license/license-manager.ts`. App runs Free/Pro/expired based on this; expiry degrades gracefully (no terminate).
- `last-action.json` — `LastActionMonitor` watches it (DispatchSource on a util queue, debounced); when the CLI runs an action it pushes a banner into `AppState` and forces a refresh. Mirror field names with the CLI's `src/lib/data-dir.ts`.
- `cve-cache.json` — `SecurityMonitor`. Sync state — `SyncMonitor`.
- `brew-tui --version` — `VersionChecker` warns (non-blocking) when CLI and app versions drift, because version skew has broken license decryption before. At launch, missing `brew-tui` shows a required-install alert and quits.
- **Self-cask filtering**: `brew outdated` lists `brew-tui-bar`/`brewbar` (the app itself); `BrewChecker` strips these from the user-facing outdated count and surfaces them separately as `selfUpdateVersion`.

## Conventions

- Swift 6 with `SWIFT_STRICT_CONCURRENCY=complete`. Respect actor isolation; `AppState`/`AppDelegate`/scheduler are `@MainActor`. Cross-boundary mutable boxes use `@unchecked Sendable` + an `NSLock` (see `BrewProcess`).
- All user-facing strings go through `String(localized:)`; catalog is `Resources/Localizable.xcstrings` (regions: en, es).
- Logging via `os.Logger(subsystem: "com.molinesdesigns.brewtuibar", category: …)`.
- `Sources/DesignExploration/` is excluded from the build in `Project.swift` (design scratch code that must not ship in the signed binary).
