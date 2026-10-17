# Burrow

A macOS menu bar app that keeps port forwards up: SSH, AWS SSM, kubectl, Google Cloud IAP, Cloudflare Access, or any command.

Status: in development. See [docs/spec.md](docs/spec.md), [docs/adr/](docs/adr/) and the [v1 plan](docs/superpowers/plans/2026-10-17-tunnels-v1.md).

## Build

```
brew install xcodegen
swift test                 # TunnelKit unit tests
xcodegen generate          # writes Burrow.xcodeproj (not committed)
xcodebuild -scheme Burrow -destination 'platform=macOS' build
```

Requires macOS 14+, Xcode 16+.
