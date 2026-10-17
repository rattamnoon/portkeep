# ADR-0003: SwiftUI MenuBarExtra, macOS 14+, Swift 6

Status: Accepted · 2026-10-17

## Context

The UI is a menu bar popover, a Settings window and an Add Tunnel sheet, designed to look first-party. `MenuBarExtra` with `.window` style exists from macOS 13; the Observation framework (`@Observable`) needs macOS 14.

## Decision

- App: SwiftUI `App` with `MenuBarExtra(.window)` and a `Settings` scene; `LSUIElement`. AppKit only where SwiftUI has no API (submenus in the popover via `NSMenu`, `NSWorkspace` sleep/wake notifications).
- Minimum macOS 14. Swift 6 language mode with strict concurrency.
- Code split into a SwiftPM package `TunnelKit` (model, command building, supervision, parsing; no UI, fully unit-tested with `swift test`) and an app target `Burrow` generated from `project.yml` by XcodeGen, so the Xcode project is not hand-edited or committed.

## Consequences

- Users on macOS 13 or older are not supported.
- Logic is testable without launching the app; UI is verified by running it.
- XcodeGen becomes a build-time dependency (`brew install xcodegen`).
