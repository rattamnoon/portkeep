# ADR-0001: Distribute outside the Mac App Store

Status: Accepted · 2026-10-17

## Context

The app must start the user's own `ssh`, `aws`, `kubectl`, `gcloud` and `cloudflared`, read `~/.ssh/config`, `~/.aws/config` and kubeconfig, and use the user's ssh-agent. App Store apps must be sandboxed, and a sandboxed app can do none of this without per-file user grants and an embedded protocol stack. Core Tunnel shows the cost: from 3.8.6 its App Store build dropped its helper, losing the agent, `~/.ssh/config` and `ProxyCommand`, and sends users to a separately sold build.

## Decision

Ship one build, unsandboxed, Developer ID signed with hardened runtime, notarized and stapled. Distribute a `.dmg` on GitHub Releases and a Homebrew cask. Update in-app with Sparkle 2 (EdDSA-signed appcast).

## Consequences

- Every connection method in the spec works, using the user's existing config and credentials.
- No App Store discovery, reviews or payments. Pricing, if any, needs its own channel.
- Needs an Apple Developer Program membership, notarization in CI, and a Sparkle signing key kept out of the repo.
- An App Store "lite" build stays possible later as a separate target; nothing here blocks it.
