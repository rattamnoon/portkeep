# Portkeep for agents

**Managing the user's tunnels** (add, edit, start, stop, test, remove, diagnose): follow [`skills/portkeep/SKILL.md`](skills/portkeep/SKILL.md). Drive the running app with the `portkeep` CLI (`--json` on every read) or the MCP server (`portkeep mcp`); never edit `tunnels.json` directly, and never put credentials in a tunnel.

**Working on this repository**: build and test steps are in [`CONTRIBUTING.md`](CONTRIBUTING.md) (`swift test`, then `xcodegen generate` and `xcodebuild`). The control protocol, its validation and the MCP server live in `Sources/TunnelKit/Control/`, with unit tests beside the others; the CLI is `Sources/PortkeepCLI/`. Try a build against a throwaway data folder (`PORTKEEP_DATA_DIR=$(mktemp -d)`) so the installed Portkeep and its tunnels are left alone.
