# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A local **file bridge** that lets agents (Claude Code, Hermes, Codex) control REAPER without
any network protocol. Agents drop JSON command files into `inbox\`; a deferred Lua script
running inside REAPER executes them and writes JSON results to `outbox\`. There is no server,
no socket — just atomic file writes in shared folders.

Design spec: `C:\Users\david\workspace\reaper-tools\REAPER_AGENT_BRIDGE_DESIGN_SPEC.md`

## Architecture

Two independent runtimes, each polling a folder:

1. **REAPER Lua bridge** (`bridge\reaper_agent_bridge.lua`) — loaded once via REAPER's Action
   List, then runs forever as a `reaper.defer` loop. Polls `inbox\` every 0.25s, executes one
   command per tick, writes a heartbeat to `bridge\heartbeat.json`. This is the only thing
   that touches the REAPER API. All command handlers live here.

2. **PowerShell drum worker** (`worker\python_worker.ps1`) — separate process for agents that
   *can't* run a shell. Polls `jobs\` every 0.5s, shells out to `generate_drums.py` (in
   `reaper-tools\`), writes the `.mid` to `jobs_done\`. The Lua bridge never spawns processes;
   MIDI generation is fully decoupled from REAPER control.

### Command file lifecycle (Lua bridge)

`inbox\<id>.json` → moved to `processing\` → executed → result written to `outbox\<id>.json` →
source moved to `archive\` (success) or `failed\` (error). Files are sorted by name, so command
IDs are timestamped to preserve order. One command in flight at a time.

### Atomic writes — mandatory everywhere

Every JSON write is: write `<path>.tmp`, then rename to `<path>`. The poller explicitly skips
`.tmp` files. Breaking this means a reader can see a half-written file. The Lua, both PS1
scripts, and any agent code all follow this.

### Command schema

```json
{ "id": "...", "version": 2, "type": "get_context", "created_by": "...",
  "created_at": "ISO-8601", "dry_run": false, "payload": {} }
```

Result schema is `{ id, ok, type, finished_at, message, data | error }`. Error codes are
`UPPER_SNAKE` prefixes parsed out of the thrown message (e.g. `NO_TARGET_TRACK:`,
`AMBIGUOUS_FX:`). Full schema and per-command payloads: `bridge\command_schema.md`.

## Adding a command (most common task)

All handlers are in `reaper_agent_bridge.lua`:

1. Write a `command_<name>(command)` function returning a plain table (becomes `data`).
2. Register it: `handlers.<name> = command_<name>`.
3. If it mutates the project, `is_mutating()` must return true for it — currently anything
   except `get_context` and `get_fx_parameters`. Mutating commands are auto-wrapped in
   `Undo_BeginBlock`/`EndBlock` (skipped inside `batch`, which wraps the whole set).
4. `dry_run: true` short-circuits before any handler runs (except `get_context`), so handlers
   never need to check it themselves.
5. Resolve tracks via `find_track` (by `target_track_guid`, then `target_track_name` exact
   case-insensitive, then selected track), FX via `find_fx`, params via `find_fx_param`.
   These throw `NO_*` / `AMBIGUOUS_*` errors — don't reimplement matching.

`pcall` wraps every command, so a thrown error becomes a failed result and never kills the
defer loop. Throw `error("CODE: human message")`.

## Running things (Windows, double-click — no terminal)

| Action | File |
|--------|------|
| One-time setup instructions | `install_bridge_in_reaper.bat` |
| Load the bridge | REAPER → Actions → Show action list → ReaScript: Load → `bridge\reaper_agent_bridge.lua`, run once |
| Start the drum worker | `start_worker.bat` |
| Send/test a command | drag a JSON file onto `send_reaper_command.bat` |

`send_reaper_command.ps1 -CommandPath <file> -Wait` sends a command and polls `outbox\` for
the result (auto-fills `id`/`created_at`/`created_by` if missing; `id: "<auto>"` forces a new
one). The AGENTS.md PowerShell snippet is the canonical way for an agent to send + poll.

## Before sending commands

- Check `bridge\heartbeat.json` is fresh. Stale/missing → bridge not running, point David to
  `install_bridge_in_reaper.bat`.
- Run `get_context` before any ambiguous edit.
- Never assume Neural DSP / Odeholm / Misha FX parameter indices — they shift between plugin
  versions. Query once with `get_fx_parameters`, then act. Parameter maps captured so far:
  `docs\misha_parameter_map.md`, `docs\odeholm_thall_parameter_map.md`.
- Don't touch all tracks unless David explicitly asks. Prefer the selected track only when he
  says "selected track" or exactly one is selected.
- Don't overwrite items unless `replace_existing_in_range: true`.

## Worker config

`bridge\bridge_config.json` holds absolute paths (`bridge_root`, `python_exe`,
`drum_generator`, `riff_analyzer`) and flags (`allow_execute_lua`, `allow_risk_level_3` —
both currently false). Both the Lua bridge and the worker read it.

## Conventions

- Drum specs: prefer exact string notation (`kick_notation: "-K--K---K-K--K--"`,
  `snare_notation`, `power_hand`, `subdivision`, `humanize`) over vague keyword specs.
- All files UTF-8 **without BOM** (the PS1 scripts use an explicit `UTF8Encoding($false)`).
- `commands\examples\` holds a working JSON example for every command type — copy these.
