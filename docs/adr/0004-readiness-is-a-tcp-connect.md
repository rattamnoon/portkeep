# ADR-0004: Readiness and health are a TCP connect to the local port

Status: Accepted · 2026-10-17

## Context

A live child process does not mean a working tunnel: `aws ssm start-session` and `kubectl port-forward` stay running after the remote side is gone, and `ssh` can sit in a half-open TCP state for minutes after a network change. The user's actual question is "can my DB client connect to 127.0.0.1:{port} right now?".

## Decision

Connected means a TCP connect to `127.0.0.1:{localPort}` succeeds. Probe every 250 ms for up to 20 s after launch; then every 10 s; two consecutive failures restart the tunnel. SSH `-R` tunnels have no local port and fall back to process liveness.

## Consequences

- Status reflects what the user's clients see, across all methods, with one mechanism.
- A probe opens and closes a connection through the tunnel every 10 s. For SSM and kubectl that reaches the remote service as an empty connection; acceptable for databases and HTTP services, noted for anything that logs every connect.
- A tunnel whose local listener is up but whose remote side is broken can still show Connected (ssh accepts locally before connecting onward). Deeper checks are out of scope for v1.
