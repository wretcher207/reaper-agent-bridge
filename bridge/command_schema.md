# Command Schema

Every command is JSON.

```json
{
  "id": "codex-2026-05-18T21-15-00-3f9a",
  "version": 2,
  "type": "get_context",
  "created_by": "codex",
  "created_at": "2026-05-18T21:15:00-04:00",
  "dry_run": false,
  "payload": {}
}
```

## Implemented Commands

### get_context

```json
{
  "include_fx": true
}
```

### play

```json
{}
```

### stop

```json
{}
```

### insert_midi_file

```json
{
  "midi_path": "C:\\Users\\david\\workspace\\reaper-agent-bridge\\jobs_done\\drums_example.mid",
  "target_track_name": "Odeholm Drums",
  "position": { "type": "cursor" },
  "length": { "type": "bars", "bars": 4 },
  "loop": true,
  "replace_existing_in_range": false
}
```

`position.type` can be `cursor`, `time`, `bar`, `marker`, `region`,
`time_selection`, or `selected_item`.

`length.type` can be `bars`, `region`, `time_selection`, `seconds`, or
`as_generated`.

### audition_groove

Same payload as `insert_midi_file`, plus:

```json
{
  "solo_track": true,
  "play": true
}
```

### batch

```json
{
  "stop_on_error": true,
  "undo_label": "Agent: batch edit",
  "commands": [
    { "type": "solo_track", "payload": { "target_track_name": "Odeholm Drums", "solo": true } },
    { "type": "set_track_color", "payload": { "target_track_name": "Odeholm Drums", "color": { "r": 180, "g": 20, "b": 20 } } }
  ]
}
```

### get_fx_parameters

```json
{
  "target_track_name": "Guitar DI",
  "fx_name_contains": "Archetype Misha",
  "fx_scope": "all",
  "limit": 200,
  "offset": 0,
  "include_empty": false
}
```

Optional filter:

```json
{
  "param_name_contains": "Glitch"
}
```

### set_fx_param

```json
{
  "target_track_name": "Guitar DI",
  "fx_name_contains": "Archetype Misha",
  "fx_scope": "all",
  "param_name_contains": "Glitch Mix",
  "normalized_value": 0.65
}
```

Also supports:

```json
{ "relative": "+0.1" }
```

or:

```json
{ "formatted_value": "65 %" }
```

### write_fx_param_automation

```json
{
  "target_track_name": "GTR_1",
  "fx_name_contains": "Misha",
  "fx_scope": "track",
  "param_name_contains": "Glitch Chaos",
  "clear_existing_in_range": true,
  "points": [
    { "bar": 33, "beat": 1, "value": 0.0, "shape": "linear" },
    { "bar": 37, "beat": 1, "value": 1.0, "shape": "linear" },
    { "bar": 37, "beat": 2, "value": 0.0, "shape": "square" }
  ]
}
```

Point time can be `time`, `seconds`, or `bar` plus optional `beat`. Values are
normalized `0.0` to `1.0`.
