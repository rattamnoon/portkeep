# ADR-0002: Drive the user's own CLIs, don't embed protocol libraries

Status: Accepted · 2026-10-17

## Context

Embedding SSH (SwiftNIO SSH, libssh2) and re-implementing the SSM data channel would let the app run without external tools, but would have to re-create everything users already configured: `~/.ssh/config` semantics, ProxyJump/ProxyCommand, agents, certificates, smart cards, AWS SSO, kube auth plugins. Kubernetes, IAP and Cloudflare tunnels have no practical library path at all.

## Decision

Each tunnel is one child process of the matching CLI, built as an argv (never a shell string, except the Custom method) and supervised by the app. The app owns lifecycle, readiness, retries and failure classification; the CLI owns the protocol and auth.

## Consequences

- Behaviour matches what the user gets in Terminal, which is also how they debug it.
- The app depends on tools being installed and on their stderr wording for failure reasons; the classifier (spec §6) needs updating when tools change messages. Unknown output degrades to "Exited, see log", never to a wrong reason.
- Tools are found through the login shell's PATH (spec §5.6), because GUI apps don't inherit it.
