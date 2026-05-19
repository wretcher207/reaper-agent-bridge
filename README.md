# REAPER Agent Bridge

Local file bridge for controlling REAPER from Claude Code, Hermes Agent, Codex,
or any other agent that can read and write files.

This project follows the design in:

```text
C:\Users\david\workspace\reaper-tools\REAPER_AGENT_BRIDGE_DESIGN_SPEC.md
```

## What Works In This First Build

- Bridge folder structure.
- REAPER deferred Lua script.
- Heartbeat at `bridge\heartbeat.json`.
- Atomic command/result files.
- `pcall` safety so a bad command should not kill the bridge loop.
- `get_context`.
- `play`.
- `stop`.
- `insert_midi_file`.
- `audition_groove`.
- `batch`.
- `solo_track`.
- `set_track_color`.
- `get_fx_parameters`.
- `set_fx_param`.
- `write_fx_param_automation`.
- PowerShell drum worker for shell-less agents.
- Double-click helper scripts.

Misha/Thall automation recipes are next-phase work.

## Install via ReaPack

1. In REAPER: `Extensions > ReaPack > Import repositories...`
2. Paste:

   ```text
   https://raw.githubusercontent.com/wretcher207/dead-pixel-design/main/index.xml
   ```

3. `Extensions > ReaPack > Browse packages`, search `REAPER Agent Bridge`,
   right-click > Install.
4. Run the installed action once: `Actions > Show action list`, find
   `REAPER Agent Bridge`, run it. It generates `bridge_config.json` and its
   working folders next to itself on first run.

ReaPack installs only the runnable bridge. The double-click `.bat` helpers and
the drum worker live in this repo; clone it if you want those.

## One-Time Setup (manual)

Double-click:

```text
C:\Users\david\workspace\reaper-agent-bridge\install_bridge_in_reaper.bat
```

Then in REAPER:

```text
Actions > Show action list > ReaScript: Load...
```

Pick:

```text
C:\Users\david\workspace\reaper-agent-bridge\bridge\reaper_agent_bridge.lua
```

Run it once. The bridge will keep running as a background deferred script.

For drum jobs from agents that cannot run shell commands, double-click:

```text
C:\Users\david\workspace\reaper-agent-bridge\start_worker.bat
```

## How Commands Work

Agents write command JSON files to:

```text
C:\Users\david\workspace\reaper-agent-bridge\inbox
```

The bridge writes result JSON files to:

```text
C:\Users\david\workspace\reaper-agent-bridge\outbox
```

All writes should be atomic: write `.tmp`, then rename to `.json`.

## Manual Test

After the bridge is running in REAPER, drag this file onto `send_reaper_command.bat`:

```text
C:\Users\david\workspace\reaper-agent-bridge\commands\examples\get_context.json
```

The command window should print a JSON result from REAPER.

## Important Paths

```text
Bridge root: C:\Users\david\workspace\reaper-agent-bridge
Lua bridge:  C:\Users\david\workspace\reaper-agent-bridge\bridge\reaper_agent_bridge.lua
Worker:      C:\Users\david\workspace\reaper-agent-bridge\worker\python_worker.ps1
Logs:        C:\Users\david\workspace\reaper-agent-bridge\logs
Drum tools:  C:\Users\david\workspace\reaper-tools
```
