# REAPER Agent Bridge — Agent Instructions

You can control REAPER through this local file bridge. No network, no terminal
required for the agent: you read and write JSON files in shared folders.

This bridge is plugin-agnostic. It knows nothing about any specific synth, amp
sim, or drum tool. You discover what a project contains, then act on it. If a
human asks you to set up controls for plugins you have never seen, use
`scan_fx` to learn the project, then build and save a recipe.

## Bridge paths

The bridge root is this repository folder. All paths below are relative to it.

```text
inbox\        write command JSON here
outbox\       read result JSON here (same id)
bridge\heartbeat.json   liveness check
jobs\         write job JSON here (for external tools, see "Job worker")
jobs_done\    read job results here
recipes\      saved recipes (JSON) — you can save and replay these
```

## Required workflow

1. Check `bridge\heartbeat.json`. If missing or its `alive_at` is stale (more
   than a few seconds old), the bridge is not running — tell the user to run
   `install_bridge_in_reaper.bat` and load the bridge script in REAPER.
2. Send a command: write `inbox\<id>.json.tmp`, then rename it to
   `inbox\<id>.json`. The rename must be atomic; never write `.json` directly.
3. Poll for `outbox\<id>.json`. Read the result.
4. Report what happened. On `ok: false`, the `error.code` is an
   `UPPER_SNAKE` code (e.g. `NO_TARGET_TRACK`, `AMBIGUOUS_FX`).

Run `get_context` before any ambiguous edit. Use `dry_run: true` on a mutating
command to preview without changing the project.

## Sending a command (PowerShell)

```powershell
$root = Split-Path -Parent $MyInvocation.MyCommand.Path  # or the repo path
$id = "agent-" + (Get-Date -Format "yyyy-MM-ddTHH-mm-ss") + "-" + (-join ((48..57 + 97..102) | Get-Random -Count 4 | ForEach-Object {[char]$_}))
$cmd = @{
  id = $id; version = 3; type = "get_context"; created_by = "agent"
  created_at = Get-Date -Format "o"; dry_run = $false
  payload = @{ include_fx = $true }
}
$tmp = Join-Path $root "inbox\$id.json.tmp"
$final = Join-Path $root "inbox\$id.json"
$cmd | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination $final -Force

$out = Join-Path $root "outbox\$id.json"
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
  if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw; break }
  Start-Sleep -Milliseconds 250
}
```

## Commands

Full payloads and examples: `bridge\command_schema.md` and `commands\examples\`.

**Read / discover**
- `get_context` — project, tracks, FX names, transport, markers, regions.
- `get_fx_parameters` — full parameter list for one FX (paged).
- `scan_fx` — every FX and its parameters across the project. Use this first
  when you do not know what plugins a project uses.

**Transport / project**
- `play`, `stop`, `pause`, `record`
- `set_cursor`, `set_time_selection`, `set_tempo`
- `render` (gated — needs `allow_risk_level_3`)

**Tracks**
- `add_track`, `delete_track`, `rename_track`, `select_track`
- `set_track_volume`, `set_track_pan`, `mute_track`, `solo_track`, `arm_track`
- `set_track_color`

**FX**
- `add_fx`, `remove_fx`, `bypass_fx`, `move_fx`
- `set_fx_param`, `write_fx_param_automation`

**Markers / regions / items**
- `add_marker`, `add_region`, `delete_marker`, `delete_items_in_range`

**MIDI**
- `insert_midi_file`, `audition_groove`

**Composition**
- `batch` — run several commands as one undo block.
- `save_recipe`, `list_recipes`, `get_recipe`, `apply_recipe`

## Targeting tracks, FX, and parameters

Every command that acts on a track resolves it the same way, in order:
`target_track_guid`, then `target_track_name` (exact, case-insensitive), then
the selected track. FX resolve by `fx_index` or `fx_name_contains`; parameters
by `param_index` or `param_name_contains`. Ambiguous matches throw
`AMBIGUOUS_*` — narrow the selector. Never hardcode FX or parameter indices;
they shift between plugin versions. Query with `scan_fx` or
`get_fx_parameters` first, then act.

## Recipes — set up reusable controls

A recipe is a named, saved list of commands. Use recipes to capture a control
setup once and replay it, on this project or another.

1. Discover: `scan_fx` to see the FX and parameters in the project.
2. Build: assemble the commands that create the setup (add tracks, add FX, set
   params, write automation).
3. Save: `save_recipe` with a `name`, `description`, and the `commands` array.
4. Replay: `apply_recipe` with the `name` runs them as one undo block.

Recipes are plain JSON in `recipes\`. They are plugin-agnostic — a recipe that
references FX by name works on any project that has those plugins.

## Job worker — external tools

Some agents cannot run a shell. For work that needs an external program (a MIDI
generator, an analyzer, a renderer), use the job worker:

1. The user registers the program as a `tool` in `bridge\bridge_config.json`.
2. Write a job JSON to `jobs\`: `{ "id", "tool": "<registered name>",
   "params": { ... }, "spec": { ... }, "dry_run": false }`.
3. The worker substitutes `params` into the tool's argument template, runs it,
   and writes `jobs_done\<id>.result.json`.
4. Read the result; its `output_path` is the file the tool produced. Feed that
   into a bridge command (e.g. `insert_midi_file`).

The worker must be running — the user starts it with `start_worker.bat`.

## Safety

- Check the heartbeat before sending commands.
- Run `get_context` before ambiguous edits.
- Prefer the selected track only when the user clearly means it or exactly one
  track is selected. Do not act on all tracks unless explicitly asked.
- Do not overwrite existing media items unless `replace_existing_in_range` is
  true. Do not delete items, tracks, or FX without clear intent.
- `render` and `allow_execute_lua` are gated behind config flags; do not assume
  they are enabled.
- Every mutating command is wrapped in a REAPER undo block, so a mistake is
  recoverable with Ctrl+Z.
