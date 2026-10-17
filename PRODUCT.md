# Product — Burrow

<!-- impeccable:product-schema 1 -->

## Platform

macos

(Not one of ios/android/adaptive/web: a native macOS menu bar app. Follow macOS Human Interface Guidelines and AppKit/SwiftUI controls.)

## Stack

SwiftUI `MenuBarExtra` (window style popover) plus a SwiftUI settings/editor window. Tunnels run through the system `ssh` binary and, where needed, `aws ssm start-session` port forwarding.

## Users

Developers and DevOps engineers on macOS who keep several port forwards open through a working day — databases, caches, analytics stores, internal dashboards — across more than one environment (UAT, prod) and often through a jump host or AWS SSM. Distributed publicly (GitHub / App Store), so the user is anyone in that situation, not one team.

## Product Purpose

Replace the pile of half-remembered `ssh -L` commands in terminal tabs with a menu bar icon that keeps named tunnels up, says the moment one drops, and brings it back without the user opening a terminal. Success: the user stops thinking about tunnels; when one fails they know which, why, and that it is already retrying.

## Positioning

Undecided. Known pains it must answer better than a terminal tab:

- tunnels drop silently (sleep, Wi-Fi change, idle timeout) and the user finds out from a client error;
- commands and port numbers are hard to remember across many tunnels and environments;
- local ports collide with something already listening;
- many targets are only reachable through a jump host or AWS SSM, not direct SSH;
- other likely failures: auth/key prompts, host-key changes, VPN required, remote side refusing the forward.

## Operating Context

Glanced at dozens of times a day from the menu bar while working in an IDE, DB client, or browser. Opened briefly, acted on, closed. Tunnels are grouped mentally by environment (UAT vs prod) and by project. Users already keep hosts in `~/.ssh/config` and AWS profiles in `~/.aws/config`.

## Capabilities and Constraints

- Connection methods: SSH (`-L`/`-R`/`-D`, ProxyJump), AWS SSM `start-session` (to the instance or to a remote host through it), `kubectl port-forward`, `gcloud compute start-iap-tunnel`, `cloudflared access tcp`, and a custom command that holds a port open.
- Reconnect on drop; detect and report port collisions before connecting.
- Import from `~/.ssh/config`.
- Undecided: pricing/licensing, sync between machines, team sharing of tunnel sets.

## Brand Commitments

Look like a first-party Apple menu (Wi-Fi / Control Center / System Settings): system font, native controls, monochrome menu bar glyph, colour only for the system accent and small warning glyphs. Chosen 2026-10-17 over five themed directions.

## Evidence on Hand

None. No users, testimonials, metrics, or name yet. Do not invent any.

## Product Principles

1. State is the product: a glance at the menu bar must be true.
2. Failure explains itself — which tunnel, what broke, what is being done about it.
3. Never make the user retype a command or a port.
4. Native first: behave like a Mac app, not a web page in a popover.

## Accessibility & Inclusion

Status must never be colour-only (VoiceOver labels, shape/text alongside colour). Respect system appearance (light/dark) and Reduce Motion.
