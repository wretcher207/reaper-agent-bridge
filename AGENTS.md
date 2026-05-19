# REAPER Agent Bridge Instructions

You can control REAPER through this local bridge. Do not ask David to use a
terminal. If a helper must be run, use or create a `.bat` / `.ps1`.

## Bridge Paths

```text
BRIDGE_ROOT = C:\Users\david\workspace\reaper-agent-bridge
INBOX       = C:\Users\david\workspace\reaper-agent-bridge\inbox
OUTBOX      = C:\Users\david\workspace\reaper-agent-bridge\outbox
HEARTBEAT   = C:\Users\david\workspace\reaper-agent-bridge\bridge\heartbeat.json
JOBS        = C:\Users\david\workspace\reaper-agent-bridge\jobs
JOBS_DONE   = C:\Users\david\workspace\reaper-agent-bridge\jobs_done
```

## Required Workflow

1. Check `bridge\heartbeat.json`.
2. If it is missing or stale, tell David the bridge is not running and point him
   to `install_bridge_in_reaper.bat`.
3. Send a command by writing `inbox\<id>.json.tmp`, then renaming it to
   `inbox\<id>.json`.
4. Poll for `outbox\<id>.json`.
5. Read the result and report what happened.

## PowerShell Send Snippet

```powershell
$root = "C:\Users\david\workspace\reaper-agent-bridge"
$id = "codex-" + (Get-Date -Format "yyyy-MM-ddTHH-mm-ss") + "-" + (-join ((48..57 + 97..102) | Get-Random -Count 4 | ForEach-Object {[char]$_}))
$cmd = @{
  id = $id
  version = 2
  type = "get_context"
  created_by = "codex"
  created_at = Get-Date -Format "o"
  dry_run = $false
  payload = @{ include_fx = $true }
}
$tmp = Join-Path $root "inbox\$id.json.tmp"
$final = Join-Path $root "inbox\$id.json"
$cmd | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination $final -Force

$out = Join-Path $root "outbox\$id.json"
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
  if (Test-Path -LiteralPath $out) {
    Get-Content -LiteralPath $out -Raw
    break
  }
  Start-Sleep -Milliseconds 250
}
```

## Current Bridge Commands

- `get_context`
- `play`
- `stop`
- `insert_midi_file`
- `audition_groove`
- `batch`
- `solo_track`
- `set_track_color`
- `get_fx_parameters`
- `set_fx_param`
- `write_fx_param_automation`

## Drum Generation

If you have shell access, run:

```text
C:\Users\david\AppData\Local\Programs\Python\Python312\python.exe C:\Users\david\workspace\reaper-tools\generate_drums.py --bpm <BPM> --bars <BARS> --out C:\Users\david\workspace\reaper-agent-bridge\jobs_done\drums_<id>.mid --spec @<specfile>
```

Then send `insert_midi_file` or `audition_groove` to REAPER.

If you do not have shell access, write a drum job JSON into `jobs` and wait for
`jobs_done\<id>.result.json`. The worker must be running via `start_worker.bat`.

For drums, prefer exact string notation over vague keyword specs:

```json
{
  "kick_notation": "-K--K---K-K--K--",
  "snare_notation": "----S-------S---",
  "power_hand": "china_r",
  "subdivision": 16,
  "humanize": 25
}
```

## Safety Rules

- Run `get_context` before ambiguous edits.
- Prefer selected track only when David clearly says "selected track" or the
  REAPER state shows exactly one selected track.
- Do not use all tracks unless David explicitly asks.
- Do not overwrite existing items unless `replace_existing_in_range` is true.
- Every mutating command should be undoable in REAPER.
- Never assume Neural DSP or Odeholm parameter indices. Query them first once
  with `get_fx_parameters`.
