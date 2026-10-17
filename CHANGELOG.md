# Changelog

All notable changes to Portkeep are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Portkeep uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- A website on GitHub Pages, with an eleven-page user guide. (#13, #14)
- Issue forms for bugs and feature requests, a pull request template and `CONTRIBUTING.md`. (#13)

### Changed

- New "Port" app icon and menu bar glyph: two brackets around a dot. (#11)
- The Settings sidebar lists tunnels by name only; search still matches port numbers. (#11)

## [0.3.0] - 2026-10-17

### Added

- Tunnels that share a local port: turning one on stops the other Portkeep tunnel holding that port. (#9)
- A switch on each group header in the menu, and Start All / Stop All on a group in Settings. (#9)
- Group tabs in the menu, each with its colour and a connected/total count. (#9)
- On-demand tunnels: Portkeep listens on the port, starts the tunnel on the first connection and stops it after a set idle time. (#9)
- Notifications when a tunnel drops, needs action or comes back; they can be turned off in General. (#9)
- `portkeep://` URLs and a bundled `portkeep` command line tool, installable from General. (#9)
- Duplicate a tunnel. (#9)
- Export and import tunnels as JSON, and import `LocalForward` / `DynamicForward` lines from `~/.ssh/config`. (#9)
- Install with Homebrew: `brew install --cask rattamnoon/tap/portkeep`. (#7)

### Changed

- The menu no longer shows tag chips; README screenshots recaptured for 0.3. (#10)

### Fixed

- Clicking anywhere on the Advanced Options row in the tunnel editor opens or closes it, not only the chevron. (#8)

## [0.2.0] - 2026-10-17

### Added

- MIT license. (#6)

### Changed

- Each tunnel has at most one tag, picked or typed in a single Tag field. Older files still load. (#5)
- Planning docs and the design folder are no longer tracked in git. (#4)

### Fixed

- Tunnel names in the menu use the row's full width instead of being cut short. (#5)

## [0.1.0] - 2026-10-17

### Added

- A macOS menu bar app that keeps named port forwards up and explains why one isn't: SSH (`-L`/`-R`/`-D`), AWS SSM, `kubectl port-forward`, GCP IAP, `cloudflared access tcp` and custom commands. (#1)
- Per-tunnel supervision: readiness by TCP connect, health checks, backoff from 1 to 60 seconds, pausing while offline and restarting on wake. (#1)
- English, Thai, Simplified Chinese and Japanese, with an in-app language switch. (#1)
- A switch on every tunnel row, Change Local Port…, groups and tags with colours, starter groups and tags, and a Groups & Tags page. (#2)
- Settings opens when the app is opened again, since the menu bar icon can sit under the notch. (#2)
- Tunnels that were on when Portkeep quit are reopened at launch; a switch in General turns this off. (#3)

### Changed

- Monochrome app icon and matching menu bar glyph. (#3)
- Tags get their own line under a tunnel's status; the tag filter bar is removed. (#3)

[Unreleased]: https://github.com/rattamnoon/portkeep/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/rattamnoon/portkeep/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/rattamnoon/portkeep/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/rattamnoon/portkeep/releases/tag/v0.1.0
