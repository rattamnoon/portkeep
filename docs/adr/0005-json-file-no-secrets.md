# ADR-0005: Tunnel definitions in a JSON file; no secrets stored

Status: Accepted · 2026-10-17

## Context

Definitions are small (tens of records), must survive reinstalls, and users will want to back them up, diff them, or later share them. Credentials already live in ssh-agent, the keychain, `~/.aws` and kubeconfig.

## Decision

Store everything in `~/Library/Application Support/Portkeep/tunnels.json` with a `schemaVersion`, written atomically (temp file + rename). Unknown keys are preserved. The app stores no passwords, keys or tokens.

## Consequences

- Plain-text, diffable, easy to export later; no Core Data/SwiftData migration machinery.
- Hand edits while the app runs are overwritten on next save unless the file watcher reloads first (v1 reloads on external change when no edit is pending).
- Anything that would need a secret (passphrases, OTP) waits for askpass (ADR-0006) and the keychain, not this file.
