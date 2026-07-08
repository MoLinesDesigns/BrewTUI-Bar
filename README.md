# BrewTUI-Bar

Native macOS menu bar companion for BrewTUI. It watches Homebrew updates, surfaces service status, shows security notifications, and provides quick actions from the menu bar.

## Requirements

- macOS 14+
- Xcode with Swift 6 support
- Tuist
- Homebrew and `brew-tui` installed on the target machine

## Development

```bash
npm run generate
npm run build
npm test
```

The app version is read from `package.json` by `Project.swift` during `tuist generate`.

## Release

```bash
NOTARY_PROFILE=brewbar-notary ./scripts/release.sh
```

Use `./scripts/notarize.sh` to notarize and upload an already exported archive.
