# Recipes

A recipe is a named, saved list of bridge commands that an agent can replay.
Use recipes to capture a control setup once and apply it again, on this project
or another.

Each recipe is one JSON file in this folder, `<name>.json`:

```json
{
  "name": "lead-synth-setup",
  "description": "Adds a lead synth track with a synth FX and a -6 dB level.",
  "created_by": "agent",
  "saved_at": "2026-05-18T21:40:00",
  "commands": [
    { "type": "add_track", "payload": { "name": "Lead Synth" } },
    { "type": "add_fx", "payload": { "target_track_name": "Lead Synth", "fx_name": "ReaSynth (Cockos)" } }
  ]
}
```

Agents create recipes with the `save_recipe` command and run them with
`apply_recipe`. `list_recipes` and `get_recipe` inspect them. `apply_recipe`
runs every command as a single REAPER undo block.

Recipes are plugin-agnostic: a recipe that references FX by name works on any
project that has those plugins installed. Recipe names allow letters, numbers,
spaces, dashes, underscores, and dots.
