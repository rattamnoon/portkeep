# Portkeep

**Keep your port forwards up, from the menu bar.**

Portkeep is a macOS menu bar app for the tunnels you open every day: databases, caches, dashboards and SOCKS proxies behind SSH jump hosts, AWS Session Manager, Kubernetes and more. Name each tunnel once, switch it on with a click, and Portkeep keeps it alive. When one drops it tells you which, why, and that it is already reconnecting.

[ภาษาไทย](README.th.md)

<p align="center">
  <img src="docs/images/menu-en-light.png" width="320" alt="Portkeep menu with tunnels grouped by environment">
  &nbsp;&nbsp;
  <img src="docs/images/menu-en-dark.png" width="320" alt="The same menu in dark mode">
</p>

## Why

A terminal tab running `ssh -N -L 5432:db:5432 bastion` works until the laptop sleeps, the Wi-Fi changes or the session times out, and then your database client is the first to find out. Portkeep replaces those tabs with:

- **One switch per tunnel.** Grouped by environment (UAT, Production, …), with the local port next to each.
- **Honest status.** A tunnel is *Connected* only when its local port actually accepts connections, not just because a process is alive.
- **Automatic reconnect.** After sleep, a network change or a dropped session, with backoff (1 s → 60 s) and no retries burned while you're offline.
- **Failures that explain themselves.** "Host key changed for bastion", "AWS sign-in expired for profile prod", "Port 8123 is in use by clickhouse-server", each with the fix one click away.
- **No port clashes.** Portkeep checks the port before starting, names the process holding it, and offers a free one.

## Connection methods

| Method | Runs | You need |
|---|---|---|
| SSH (local `-L`, remote `-R`, SOCKS `-D`, ProxyJump) | `ssh` | Keys in your agent or keychain, hosts in `~/.ssh/config` |
| AWS Session Manager (to a remote host through an instance, or to the instance) | `aws ssm start-session` | AWS CLI + `session-manager-plugin`; SSO profiles sign in when they expire |
| Kubernetes | `kubectl port-forward` | `kubectl` and a kubeconfig context |
| Google Cloud IAP | `gcloud compute start-iap-tunnel` | `gcloud`, signed in |
| Cloudflare Access | `cloudflared access tcp` | `cloudflared` |
| Custom command | anything that holds a port open (`{port}` is replaced) | — |

Portkeep drives the tools you already use, with your existing config and credentials, and shows the exact command it runs. It never stores passwords, keys or tokens.

<p align="center">
  <img src="docs/images/add-en-light.png" width="720" alt="Add Tunnel window with the list of connection methods">
</p>

## Install

Requires macOS 14 Sonoma or later (Apple silicon or Intel).

**Download** — notarized builds will be published on the [Releases](https://github.com/rattamnoon/portkeep/releases) page. *(Not available yet.)*

**Homebrew** — once the first release is out:

```
brew install --cask rattamnoon/tap/portkeep
```

**Build from source**

```
brew install xcodegen
git clone https://github.com/rattamnoon/portkeep.git && cd portkeep
xcodegen generate
xcodebuild -scheme Portkeep -configuration Release -derivedDataPath build build
open build/Build/Products/Release/Portkeep.app
```

Install the CLIs for the methods you use, for example `brew install awscli kubectl cloudflared` and `brew install --cask session-manager-plugin google-cloud-sdk`.

## Use

1. Click the archway icon in the menu bar, then **Add Tunnel…**
2. Pick a method, fill in the fields (hosts, AWS profiles and kube contexts you already have are offered in the pickers), and choose a local port. The **Runs** box shows the command Portkeep will run.
3. Press **Test Connection** to check it, then **Add Tunnel**.
4. Click a tunnel in the menu to switch it on or off. The switch at the top starts or stops them all.
5. Turn on **Connect at login** for tunnels you always want; Portkeep then opens at login and starts them.

When a tunnel needs you, the menu bar icon shows a dot and the row shows a warning. Hover it and open **⋯** for the fix (use another port, sign in to AWS, retry), **Copy Address**, **Edit Tunnel…** or **Show Log**.

<p align="center">
  <img src="docs/images/settings-en-light.png" width="720" alt="Settings window with tunnels in the sidebar and the selected tunnel's details">
</p>

**Settings** lists every tunnel by group with search. Pick one to see its live status, edit it, or open its log. **Tools** shows where each CLI was found (from your login shell's `PATH`) and lets you override it. **General** sets the language.

## Languages

English, ไทย, 简体中文 and 日本語. Portkeep follows your macOS language; change it under **Settings › General › Language** (Portkeep relaunches) or per app in **System Settings › General › Language & Region**.

<p align="center">
  <img src="docs/images/menu-th-light.png" width="240" alt="Menu in Thai">
  <img src="docs/images/menu-zh-Hans-light.png" width="240" alt="Menu in Simplified Chinese">
  <img src="docs/images/menu-ja-light.png" width="240" alt="Menu in Japanese">
</p>

## Where things live

| What | Where |
|---|---|
| Tunnel definitions | `~/Library/Application Support/Portkeep/tunnels.json` (plain JSON, safe to back up) |
| Running children (for cleanup after a crash) | `~/Library/Application Support/Portkeep/running.json` |

If `tunnels.json` can't be read, Portkeep moves it aside to `tunnels.json.broken-<date>` instead of overwriting it.

## Limits in this version

- Authentication must already work without typing: passwords, passphrase prompts and OTP aren't supported yet. Add passphrase keys with `ssh-add --apple-use-keychain`.
- No sync between Macs, import/export, or Shortcuts yet.
- Not on the Mac App Store: the sandbox would stop Portkeep from running your CLIs and reading your config ([ADR-0001](docs/adr/0001-distribute-outside-app-store.md)).

## Development

```
swift test                                   # TunnelKit unit tests
xcodegen generate                            # Portkeep.xcodeproj (not committed)
xcodebuild test -scheme Portkeep -destination 'platform=macOS'   # UI smoke tests
```

UI smoke tests drive real windows; run them on a Mac you aren't using, or rely on CI. Demo data and screenshots: `PORTKEEP_DEMO=1 PORTKEEP_SHOW=menu,settings,add PORTKEEP_DATA_DIR=$(mktemp -d) Portkeep.app/Contents/MacOS/Portkeep`.

Design and decisions: [spec](docs/spec.md) · [ADRs](docs/adr/) · [v1 plan](docs/superpowers/plans/2026-10-17-tunnels-v1.md). 

### Releases

Push a tag (`git tag v0.2.0 && git push origin v0.2.0`) or run **Actions › Release › Run workflow** with a version. The [Release workflow](.github/workflows/release.yml) builds `Portkeep-<version>.dmg`, creates the tag if needed, and publishes a GitHub Release with notes and a SHA-256. It signs and notarizes when the Developer ID secrets listed at the top of the workflow are set, and otherwise publishes an unsigned build labelled as such. Locally: `scripts/release.sh <version>` (or `UNSIGNED=1 scripts/release.sh <version>`).

## License

Not decided yet.
