---
name: portkeep
description: Port forwards and tunnels on the user's Mac through Portkeep (menu bar app, `portkeep` CLI and MCP server). Use when the user asks to add, change, start, stop, test, list or remove a tunnel or port forward (SSH -L/-R/-D or ProxyJump, AWS SSM, kubectl port-forward, Google Cloud IAP, Cloudflare Access, a custom command), or asks why one is down.
---

# Portkeep

Portkeep keeps named tunnels running from the macOS menu bar and reconnects them. The running app owns `tunnels.json`; you change it only through the `portkeep` tool (or the same operations as MCP tools, e.g. `add_tunnel`, when the `portkeep` MCP server is connected). Never edit `tunnels.json` by hand.

`portkeep` is on PATH after Homebrew or Settings › General › Install Command Line Tool…; otherwise use `/Applications/Portkeep.app/Contents/Resources/bin/portkeep`. Every command that changes something starts Portkeep in the background when it isn't running. Pass `--json` to every read so you parse JSON, not tables.

## Adding a tunnel

1. **Discover.** `portkeep discover --json`: SSH host aliases, AWS profiles with regions, kube contexts, installed and missing tools, and the local ports tunnels already use. Use these real names; ask the user for anything missing (instance ID, RDS endpoint, namespace) rather than guessing. Done when every field the method needs has a value from discover or from the user.
2. **Describe.** `portkeep methods <method> --json` gives each field's meaning, default and an example. Done when the JSON you will send has only fields it lists.
3. **Add.** `portkeep add --json '<tunnel>'`. Read `warnings` (a shared or busy local port). A validation error names the field (`data.field`); fix that field and add again.
4. **Test, then start.** `portkeep test <name> --json` connects once and stops; `portkeep start <name> --wait --json` switches it on and waits. Done when `state` is `connected` (or `standing-by` for on-demand). Otherwise read `reason` and `hint`, and `portkeep logs <name> -n 50 --json`, then go to **When it fails**.
5. Tell the user the name, the local address (`127.0.0.1:<localPort>`) and the state.

Changing one: `portkeep edit <name> --json '<patch>'` with only the fields to change (JSON merge patch; a `method` with a different key replaces the method; `null` removes an optional field). Copying one for another environment: `portkeep duplicate <name> --name "<new>"`, then edit.

## Rules

- **Credentials stay out.** A tunnel never holds a password, token or key material. Portkeep runs SSH in BatchMode with the user's agent and `~/.ssh/config`, and the user's AWS SSO / gcloud / kubectl sign-in. If something needs a password, tell the user to set up a key or sign in.
- **Ask before removing.** Confirm with the user by name, then `portkeep remove <name> --yes`.
- **Commands from a hint are the user's to run** when they sign in or change trust (`aws sso login`, `ssh-add`, `ssh-keygen -R`): show the command and let the user run it.
- **Names are unique** (ignoring case) and address the tunnel everywhere; an id also works.
- Tunnels may share a local port on purpose (prod and dev MySQL both on 3306): switching one on switches the other off.

## Tunnel JSON

Fields every tunnel has: `name`, `localPort` (on 127.0.0.1), `method` (an object with exactly one key), and optional `group` (default `Other`), `tags` (at most one), `connectAtLogin`, `startsOnConnect` (on demand), `idleMinutes`. `portkeep methods --json` is the full reference, with a JSON Schema.

SSH local forward through a jump host (`ssh -J bastion -L 3306:mysql.internal:3306 app-server`):

```json
{"name": "Orders MySQL", "group": "Staging", "localPort": 3306, "tags": ["db"],
 "method": {"ssh": {"mode": "local", "host": "app-server", "jump": "bastion",
                    "destination": {"host": "mysql.internal", "port": 3306}}}}
```

`mode` is `local` (-L), `remote` (-R: `localPort` opens on the server) or `dynamic` (-D SOCKS proxy, no `destination`).

AWS SSM to a host the instance can reach, such as RDS:

```json
{"name": "Prod MySQL", "group": "Production", "localPort": 3307,
 "method": {"ssm": {"profile": "prod", "region": "ap-southeast-1", "target": "i-0a3f5c9e2b7d41f08",
                    "forwardTo": {"remoteHost": {"host": "orders.cluster-ro.abc123.ap-southeast-1.rds.amazonaws.com", "port": 3306}}}}}
```

To a port on the instance itself: `"forwardTo": {"instance": {"port": 22}}`.

kubectl port-forward to a service:

```json
{"name": "Grafana", "group": "Production", "localPort": 3000,
 "method": {"kubernetes": {"context": "prod", "namespace": "monitoring", "resource": "svc/grafana", "remotePort": 3000}}}
```

Custom command (`{port}` becomes `localPort`; run with zsh; Portkeep restarts it when it exits):

```json
{"name": "Teleport DB", "group": "Development", "localPort": 15432,
 "method": {"custom": {"command": "tsh proxy db --port {port} mydb"}}}
```

## When it fails

Each failed or blocked tunnel in `--json` output carries `reason` and `hint`:

| reason | What to do |
|---|---|
| `ssoExpired` | The user runs `aws sso login --profile <profile>`, then `portkeep start <name>`. |
| `portInUse` (state `blocked`) | `blockedBy` names the process. Ask the user whether to stop it, or move the tunnel: `portkeep edit <name> --json '{"localPort": <free port>}'` (the hint suggests one). |
| `hostKeyChanged` | Treat as a possible attack. The user confirms the change with whoever runs the server before `ssh-keygen -R <host>`. |
| `authFailed` | The key isn't in the agent: `ssh-add --apple-use-keychain ~/.ssh/id_ed25519`, or set `method.ssh.identityFile`. |
| `hostUnreachable` | VPN, host name or network. Portkeep keeps retrying on its own. |
| `toolMissing`, `pluginMissing` | Install what the hint names (e.g. `brew install --cask session-manager-plugin`). |
| `forwardRefused` | The server disallows forwarding, or for `remote` mode the port is taken there. |
| `readinessTimeout`, `exited` | Read `portkeep logs <name> -n 50 --json`. |

`portkeep list --json` shows every tunnel's `state` (off, connecting, connected, standing-by, reconnecting, blocked, failed); `portkeep status --json` is the compact form.
