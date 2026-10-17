# ADR-0006: Non-interactive authentication only in v1

Status: Accepted · 2026-10-17

## Context

A child process with no terminal can't answer a password, passphrase or OTP prompt; without precautions `ssh` hangs waiting for one. Supporting prompts properly means an `SSH_ASKPASS` helper, a prompt UI, keychain storage and OTP flows.

## Decision

v1 runs `ssh` with `-o BatchMode=yes`, so a prompt becomes an immediate "Permission denied" (spec §6 authFailed) instead of a hang. Auth must already work without typing: keys in ssh-agent or the keychain, certificates, SSO caches. AWS SSO is the exception: an expired SSO session offers "Sign In", which runs `aws sso login --profile <p>` and opens the browser.

## Consequences

- Users with passphrase-only keys must add them to the agent (`ssh-add --apple-use-keychain`) first; the failure text says so.
- Password/OTP hosts are unsupported in v1. Revisit with an askpass helper in v1.1.
