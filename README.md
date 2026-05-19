# REAPER Agent Bridge

A local file bridge for controlling REAPER from any AI agent — Claude Code,
Codex, a custom agent, anything that can read and write files. No network, no
socket, no MCP server: agents drop JSON command files in a folder, a Lua script
inside REAPER executes them and writes JSON results back.

The bridge is **plugin-agnostic**. It ships with no knowledge of any specific
synth, amp sim, or instrument. An agent discovers what a project contains with
`scan_fx`, acts on tracks/FX/parameters by name, and can save reusable setups
as **recipes**. Whatever plugins a user has, an agent can take over and wire up
the controls it needs.

## What it does

- **Project control** — transport, tempo, cursor, time selection, render.
- **Tracks** — add, delete, rename, select, volume, pan, mute, solo, arm, color.
- **FX** — add, remove, bypass, reorder, set parameters, write parameter
  automation envelopes.
- **Markers, regions, media items.**
- **MIDI** — insert and audition MIDI files.
- **Discovery** — `scan_fx` dumps every FX and parameter in the project so an
  agent can learn an unfamiliar setup.
- **Recipes** — agents save command sequences and replay them on any project.
- **Job worker** — a generic runner for external tools (MIDI generators,
  analyzers, renderers), registered in config. For agents that cannot run a
  shell.

Every mutating command runs inside a REAPER undo block.

## How it works

Two independent runtimes, each polling a folder:

1. **Lua bridge** (`bridge\reaper_agent_bridge.lua`) — loaded once in REAPER's
   Action List, runs forever as a deferred loop. Polls `inbox\`, executes one
   command per tick, writes results to `outbox\`, and a heartbeat to
   `bridge\heartbeat.json`. This is the only thing that touches the REAPER API.

2. **Job worker** (`worker\job_worker.ps1`) — a separate process that runs
   external programs registered as `tools` in `bridge_config.json`. Polls
   `jobs\`, writes results to `jobs_done\`. Optional; only needed for agents
   that cannot run a shell themselves.

All JSON writes are atomic (write `.tmp`, then rename). Command files move
`inbox\` → `processing\` → `archive\` (ok) or `failed\` (error).

## Setup

Double-click `install_bridge_in_reaper.bat`, then in REAPER:

```text
Actions > Show action list > ReaScript: Load...
```

Pick `bridge\reaper_agent_bridge.lua` and run it once. It runs as a background
deferred script and regenerates `bridge_config.json` and its working folders on
first run, so the repo works wherever it is cloned.

To use external tools (e.g. a MIDI generator), register them in
`bridge\bridge_config.json` under `tools` (see `bridge_config.example.json`),
then double-click `start_worker.bat`.

## Install via ReaPack

1. REAPER: `Extensions > ReaPack > Import repositories...`
2. Paste:
   ```text
   https://raw.githubusercontent.com/wretcher207/dead-pixel-design/main/index.xml
   ```
3. `Extensions > ReaPack > Browse packages`, search `REAPER Agent Bridge`,
   right-click > Install.
4. Run the installed action once. It creates its config and working folders.

ReaPack installs only the runnable bridge. The `.bat` helpers and the job
worker live in this repo; clone it for those.

## Test it

With the bridge running in REAPER, drag onto `send_reaper_command.bat`:

```text
commands\examples\get_context.json
```

The window prints a JSON result from REAPER.

## For agents

Read `AGENTS.md` for the workflow and `bridge\command_schema.md` for every
command. Working JSON examples are in `commands\examples\`.

## Layout

```text
bridge\reaper_agent_bridge.lua   the bridge (runs inside REAPER)
bridge\bridge_config.json        machine-specific config (regenerated)
bridge\command_schema.md         full command reference
worker\job_worker.ps1            generic external-tool runner
commands\examples\               one JSON example per command
recipes\                         saved, replayable command sequences
inbox\ outbox\ jobs\ jobs_done\  runtime folders
```
