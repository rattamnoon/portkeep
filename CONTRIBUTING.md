# Contributing to Portkeep

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

Open a [bug report](https://github.com/rattamnoon/portkeep/issues/new?template=bug_report.yml). The form asks for:

- your Portkeep and macOS versions;
- the tunnel's connection method;
- what the menu said, word for word if you can;
- the lines from **Show Log** (open **⋯** on the tunnel's row), around the failure;
- the steps that make it happen.

Remove hostnames, account ids and anything else you'd rather not post. Questions and half-formed ideas fit better in [Discussions](https://github.com/rattamnoon/portkeep/discussions); a concrete request goes in a [feature request](https://github.com/rattamnoon/portkeep/issues/new?template=feature_request.yml).

## Building and testing

You need macOS 14 or later, Xcode, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```
swift test                                   # TunnelKit unit tests
xcodegen generate                            # Portkeep.xcodeproj (not committed)
xcodebuild build -scheme Portkeep -destination 'platform=macOS'
xcodebuild test -scheme Portkeep -destination 'platform=macOS'   # UI smoke tests
swift scripts/make-icon.swift                # redraw the app icon
```

UI smoke tests drive real windows, so run them on a Mac you aren't using or rely on CI. For demo data and screenshots, run:

```
PORTKEEP_DEMO=1 PORTKEEP_SHOW=menu,settings,add,labels PORTKEEP_DATA_DIR=$(mktemp -d) Portkeep.app/Contents/MacOS/Portkeep
```

The tunnel logic lives in `Sources/TunnelKit` and is covered by `swift test`; the SwiftUI app is in `App/`. The website is the static page in `site/`, deployed to GitHub Pages when it changes on `main`.

## Pull requests

- **One change per pull request.** A fix and a refactor are two PRs. Small is easier to review and to revert.
- **It passes `swift test` and builds** with `xcodebuild`. CI runs both, plus the UI smoke tests.
- **New strings are localized** in all four languages: `en`, `th`, `zh-Hans` and `ja` (`App/Resources/*.lproj` and `Sources/TunnelKit/Resources/*.lproj`). If you can't translate one, say so in the PR.
- **It behaves like a Mac app.** System font, native controls, light and dark appearance, and status that never relies on colour alone. Include screenshots for UI changes.
- **No secrets.** Portkeep never stores passwords, keys or tokens; changes keep it that way.

PRs are squash-merged, so the title becomes the commit on `main`: write it as what the change does.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
