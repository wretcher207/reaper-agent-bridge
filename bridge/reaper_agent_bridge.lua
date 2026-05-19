-- REAPER Agent Bridge v2
-- Load this once in REAPER's Action List. It runs as a deferred script and
-- watches C:\Users\david\workspace\reaper-agent-bridge\inbox for JSON commands.

local SCRIPT_PATH = ({ reaper.get_action_context() })[2] or ""
local SCRIPT_DIR = SCRIPT_PATH:match("^(.*)[/\\][^/\\]+$") or "."
package.path = SCRIPT_DIR .. "\\?.lua;" .. package.path

local json = require("json")

local CONFIG_PATH = SCRIPT_DIR .. "\\bridge_config.json"

local function read_file(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local text = file:read("*a")
  file:close()
  return text
end

local function write_file(path, text)
  local file, err = io.open(path, "wb")
  if not file then error(err or ("Cannot write " .. path)) end
  file:write(text)
  file:close()
end

local function exists(path)
  local file = io.open(path, "rb")
  if file then file:close(); return true end
  return false
end

local function parent_dir(path)
  return path:match("^(.*)[/\\][^/\\]+$") or path
end

-- The script lives in <bridge_root>\bridge, so the bridge root is one level up.
local DEFAULT_BRIDGE_ROOT = parent_dir(SCRIPT_DIR)

local function default_config()
  return {
    bridge_root = DEFAULT_BRIDGE_ROOT,
    poll_interval_seconds = 0.25,
    archive_successful_commands = true,
    allow_execute_lua = false,
    allow_risk_level_3 = false,
    bridge_version = 2,
    default_timeout_ms = 30000,
    python_exe = "",
    drum_generator = "",
    riff_analyzer = "",
  }
end

-- Generate a config on first run so a ReaPack install works without setup.
local function load_config()
  local text = read_file(CONFIG_PATH)
  if text then
    local ok, parsed = pcall(json.decode, text)
    if ok and type(parsed) == "table" then
      if not parsed.bridge_root or parsed.bridge_root == "" then
        parsed.bridge_root = DEFAULT_BRIDGE_ROOT
      end
      return parsed
    end
  end
  local config = default_config()
  pcall(write_file, CONFIG_PATH, json.encode(config))
  return config
end

local config = load_config()
local root = config.bridge_root

local paths = {
  inbox = root .. "\\inbox",
  processing = root .. "\\processing",
  outbox = root .. "\\outbox",
  failed = root .. "\\failed",
  archive = root .. "\\archive",
  logs = root .. "\\logs",
  heartbeat = root .. "\\bridge\\heartbeat.json",
}

-- Create the working folders if they are missing (fresh install or moved root).
for _, dir in pairs({ paths.inbox, paths.processing, paths.outbox, paths.failed, paths.archive, paths.logs }) do
  if reaper.RecursiveCreateDirectory then reaper.RecursiveCreateDirectory(dir, 0) end
end

local in_flight_command = nil
local last_poll = 0
local poll_interval = tonumber(config.poll_interval_seconds or 0.25)

local function now()
  return os.date("%Y-%m-%dT%H:%M:%S")
end

local function log_line(message)
  local file = io.open(paths.logs .. "\\bridge.log", "ab")
  if file then
    file:write("[" .. now() .. "] " .. message .. "\n")
    file:close()
  end
end

local function atomic_write_json(path, value)
  local tmp = path .. ".tmp"
  write_file(tmp, json.encode(value))
  os.remove(path)
  local ok, err = os.rename(tmp, path)
  if not ok then error(err or ("Cannot rename " .. tmp)) end
end

local function move_file(src, dst)
  os.remove(dst)
  local ok = os.rename(src, dst)
  if ok then return true end
  local text = read_file(src)
  if not text then return false end
  write_file(dst, text)
  os.remove(src)
  return true
end

local function list_inbox()
  local files = {}
  local index = 0
  while true do
    local filename = reaper.EnumerateFiles(paths.inbox, index)
    if not filename then break end
    if filename:match("%.json$") and not filename:match("%.tmp$") then
      files[#files + 1] = filename
    end
    index = index + 1
  end
  table.sort(files)
  return files
end

local function selected_item_count()
  return reaper.CountSelectedMediaItems(0)
end

local function db_from_volume(volume)
  if not volume or volume <= 0 then return -150.0 end
  return 20.0 * math.log(volume, 10)
end

local function bar_from_time(seconds)
  local ok, measures = pcall(function()
    local _, measure = reaper.TimeMap2_timeToBeats(0, seconds)
    return measure
  end)
  if ok and type(measures) == "number" then return measures + 1 end
  local tempo = reaper.Master_GetTempo()
  return math.floor((seconds / (240.0 / tempo))) + 1
end

local function time_from_bar(bar)
  local ok, value = pcall(function()
    return reaper.TimeMap2_beatsToTime(0, 0, math.max(0, bar - 1))
  end)
  if ok and type(value) == "number" then return value end
  local tempo = reaper.Master_GetTempo()
  return (bar - 1) * (240.0 / tempo)
end

local function get_project_name()
  local _, name = reaper.EnumProjects(-1, "")
  if name and name ~= "" then
    return name:match("[^/\\]+$") or name
  end
  local ok, project_name = reaper.GetProjectName(0, "")
  if ok and project_name and project_name ~= "" then return project_name end
  return "Untitled"
end

local function get_time_selection()
  local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  return {
    start = start_time,
    ["end"] = end_time,
    start_bar = bar_from_time(start_time),
    end_bar = bar_from_time(end_time),
    active = end_time > start_time,
  }
end

local function get_transport()
  local state = reaper.GetPlayState()
  return {
    playing = (state & 1) == 1,
    paused = (state & 2) == 2,
    recording = (state & 4) == 4,
  }
end

local function get_tracks(include_fx)
  local tracks = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(track, "")
    local volume = reaper.GetMediaTrackInfo_Value(track, "D_VOL")
    local track_info = {
      index = i + 1,
      guid = reaper.GetTrackGUID(track),
      name = name,
      selected = reaper.IsTrackSelected(track),
      muted = reaper.GetMediaTrackInfo_Value(track, "B_MUTE") == 1,
      soloed = reaper.GetMediaTrackInfo_Value(track, "I_SOLO") ~= 0,
      armed = reaper.GetMediaTrackInfo_Value(track, "I_RECARM") == 1,
      volume = volume,
      volume_db = db_from_volume(volume),
      pan = reaper.GetMediaTrackInfo_Value(track, "D_PAN"),
      folder_depth = reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH"),
      item_count = reaper.CountTrackMediaItems(track),
    }
    if include_fx then
      track_info.fx = {}
      for fx = 0, reaper.TrackFX_GetCount(track) - 1 do
        local _, fx_name = reaper.TrackFX_GetFXName(track, fx, "")
        track_info.fx[#track_info.fx + 1] = { index = fx, api_index = fx, scope = "track", name = fx_name }
      end
      track_info.input_fx = {}
      if reaper.TrackFX_GetRecCount then
        for fx = 0, reaper.TrackFX_GetRecCount(track) - 1 do
          local api_index = 0x1000000 + fx
          local _, fx_name = reaper.TrackFX_GetFXName(track, api_index, "")
          track_info.input_fx[#track_info.input_fx + 1] = { index = fx, api_index = api_index, scope = "input", name = fx_name }
        end
      end
    end
    tracks[#tracks + 1] = track_info
  end
  return tracks
end

local function get_markers_regions()
  local markers, regions = {}, {}
  local _, marker_count, region_count = reaper.CountProjectMarkers(0)
  for i = 0, marker_count + region_count - 1 do
    local ok, is_region, pos, region_end, name, index, color = reaper.EnumProjectMarkers3(0, i)
    if ok then
      local entry = {
        name = name,
        index = index,
        color = color,
        start = pos,
        start_bar = bar_from_time(pos),
      }
      if is_region then
        entry["end"] = region_end
        entry.end_bar = bar_from_time(region_end)
        regions[#regions + 1] = entry
      else
        entry.position = pos
        entry.bar = bar_from_time(pos)
        markers[#markers + 1] = entry
      end
    end
  end
  return markers, regions
end

local function command_get_context(command)
  local payload = command.payload or {}
  local cursor = reaper.GetCursorPosition()
  local markers, regions = get_markers_regions()
  return {
    project_name = get_project_name(),
    tempo = reaper.Master_GetTempo(),
    has_tempo_changes = reaper.CountTempoTimeSigMarkers(0) > 0,
    cursor = { seconds = cursor, bar = bar_from_time(cursor) },
    time_selection = get_time_selection(),
    transport = get_transport(),
    tracks = get_tracks(payload.include_fx ~= false),
    markers = markers,
    regions = regions,
    selected_track_count = reaper.CountSelectedTracks(0),
    selected_item_count = selected_item_count(),
  }
end

local function find_track(payload)
  if payload.target_track_guid then
    for i = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, i)
      if reaper.GetTrackGUID(track) == payload.target_track_guid then return track, i + 1 end
    end
    error("NO_TARGET_TRACK: No track with guid " .. payload.target_track_guid)
  end
  if payload.target_track_name then
    local found, found_index = nil, nil
    local needle = payload.target_track_name:lower()
    for i = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, i)
      local _, name = reaper.GetTrackName(track, "")
      if name:lower() == needle then
        if found then error("AMBIGUOUS_TARGET_TRACK: Multiple tracks named " .. payload.target_track_name) end
        found, found_index = track, i + 1
      end
    end
    if found then return found, found_index end
    error("NO_TARGET_TRACK: No track named " .. payload.target_track_name)
  end
  local selected = reaper.GetSelectedTrack(0, 0)
  if selected then
    return selected, math.floor(reaper.GetMediaTrackInfo_Value(selected, "IP_TRACKNUMBER"))
  end
  error("NO_TARGET_TRACK: Select a track or provide target_track_name")
end

local function contains_ci(haystack, needle)
  if not haystack or not needle then return false end
  return tostring(haystack):lower():find(tostring(needle):lower(), 1, true) ~= nil
end

local function find_fx(payload)
  local track, track_index = find_track(payload)
  local scope = payload.fx_scope or payload.scope or "all"
  local search_track_fx = scope == "all" or scope == "track" or scope == "normal"
  local search_input_fx = scope == "all" or scope == "input" or scope == "rec" or scope == "record"
  local matches = {}

  if payload.fx_index ~= nil then
    local fx_index = tonumber(payload.fx_index)
    local api_index = fx_index
    local resolved_scope = "track"
    if scope == "input" or scope == "rec" or scope == "record" then
      local rec_count = reaper.TrackFX_GetRecCount and reaper.TrackFX_GetRecCount(track) or 0
      if not fx_index or fx_index < 0 or fx_index >= rec_count then
        error("NO_FX: Input FX index out of range")
      end
      api_index = 0x1000000 + fx_index
      resolved_scope = "input"
    else
      local fx_count = reaper.TrackFX_GetCount(track)
      if not fx_index or fx_index < 0 or fx_index >= fx_count then
        error("NO_FX: Track FX index out of range")
      end
    end
    local _, fx_name = reaper.TrackFX_GetFXName(track, api_index, "")
    return track, track_index, api_index, fx_name, resolved_scope, fx_index
  end

  local needle = payload.fx_name_contains
  if not needle or needle == "" then
    error("NO_FX_SELECTOR: Provide fx_name_contains or fx_index")
  end

  local function add_matches(count, api_offset, match_scope)
    for fx = 0, count - 1 do
      local api_index = api_offset + fx
      local _, fx_name = reaper.TrackFX_GetFXName(track, api_index, "")
      if contains_ci(fx_name, needle) then
        matches[#matches + 1] = { index = fx, api_index = api_index, scope = match_scope, name = fx_name }
      end
    end
  end

  if search_track_fx then
    add_matches(reaper.TrackFX_GetCount(track), 0, "track")
  end
  if search_input_fx and reaper.TrackFX_GetRecCount then
    add_matches(reaper.TrackFX_GetRecCount(track), 0x1000000, "input")
  end

  if #matches == 0 then error("NO_FX: No FX matched " .. tostring(needle)) end
  if #matches > 1 then error("AMBIGUOUS_FX: Multiple FX matched " .. tostring(needle)) end
  return track, track_index, matches[1].api_index, matches[1].name, matches[1].scope, matches[1].index
end

local function get_fx_param_info(track, fx_index, param_index)
  local _, name = reaper.TrackFX_GetParamName(track, fx_index, param_index, "")
  local normalized = reaper.TrackFX_GetParamNormalized(track, fx_index, param_index)
  local value, min_value, max_value = reaper.TrackFX_GetParam(track, fx_index, param_index)
  local formatted = ""
  local ok, retval, text = pcall(reaper.TrackFX_GetFormattedParamValue, track, fx_index, param_index, "")
  if ok then
    if type(text) == "string" then
      formatted = text
    elseif type(retval) == "string" then
      formatted = retval
    end
  end
  return {
    index = param_index,
    name = name,
    value = value,
    normalized_value = normalized,
    min = min_value,
    max = max_value,
    formatted_value = formatted,
  }
end

local function find_fx_param(track, fx_index, payload)
  local param_count = reaper.TrackFX_GetNumParams(track, fx_index)
  if payload.param_index ~= nil then
    local param_index = tonumber(payload.param_index)
    if not param_index or param_index < 0 or param_index >= param_count then
      error("NO_PARAM: Parameter index out of range")
    end
    return param_index, get_fx_param_info(track, fx_index, param_index)
  end

  local needle = payload.param_name_contains
  if not needle or needle == "" then
    error("NO_PARAM_SELECTOR: Provide param_name_contains or param_index")
  end

  local matches = {}
  for param = 0, param_count - 1 do
    local info = get_fx_param_info(track, fx_index, param)
    if contains_ci(info.name, needle) then
      matches[#matches + 1] = info
    end
  end

  if #matches == 0 then error("NO_PARAM: No parameter matched " .. tostring(needle)) end
  if #matches > 1 then error("AMBIGUOUS_PARAM: Multiple parameters matched " .. tostring(needle)) end
  return matches[1].index, matches[1]
end

local function time_from_point(point)
  if point.time ~= nil then return tonumber(point.time) or 0 end
  if point.seconds ~= nil then return tonumber(point.seconds) or 0 end
  if point.bar ~= nil then
    local bar = tonumber(point.bar) or 1
    local beat = tonumber(point.beat or 1) or 1
    local whole_bar = math.floor(bar)
    local beat_offset = 0
    if beat > 0 then beat_offset = beat - 1 end
    local ok, value = pcall(function()
      return reaper.TimeMap2_beatsToTime(0, beat_offset, math.max(0, whole_bar - 1))
    end)
    if ok and type(value) == "number" then return value end
    return time_from_bar(bar)
  end
  error("BAD_POINT_TIME: Automation point needs time, seconds, or bar")
end

local function envelope_shape(shape)
  local value = tostring(shape or "linear"):lower()
  if value == "linear" then return 0 end
  if value == "square" or value == "hold" then return 1 end
  if value == "slow_start_end" or value == "slow" then return 2 end
  if value == "fast_start" or value == "fast" then return 3 end
  if value == "bezier" then return 5 end
  return 0
end

local function resolve_position(position)
  position = position or { type = "cursor" }
  local kind = position.type or "cursor"
  if kind == "cursor" then return reaper.GetCursorPosition() end
  if kind == "time" then return tonumber(position.seconds or 0) or 0 end
  if kind == "bar" then return time_from_bar(tonumber(position.bar or 1) or 1) end
  if kind == "time_selection" then
    local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if end_time <= start_time then error("NO_TIME_SELECTION: No active time selection") end
    return start_time, end_time
  end
  if kind == "marker" or kind == "region" then
    local _, marker_count, region_count = reaper.CountProjectMarkers(0)
    local needle = (position.name or ""):lower()
    for i = 0, marker_count + region_count - 1 do
      local ok, is_region, pos, region_end, name = reaper.EnumProjectMarkers3(0, i)
      if ok and name and name:lower() == needle then
        if kind == "region" and is_region then return pos, region_end end
        if kind == "marker" and not is_region then return pos end
      end
    end
    error("NO_" .. kind:upper() .. ": No " .. kind .. " named " .. tostring(position.name))
  end
  if kind == "selected_item" then
    local item = reaper.GetSelectedMediaItem(0, 0)
    if not item then error("NO_SELECTED_ITEM: No selected media item") end
    local start_time = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    return start_time, start_time + len
  end
  error("BAD_POSITION: Unsupported position type " .. tostring(kind))
end

local function resolve_length(length, position_end, start_time)
  length = length or { type = "as_generated" }
  local kind = length.type or "as_generated"
  if kind == "bars" then
    local end_time = time_from_bar(bar_from_time(start_time) + (tonumber(length.bars or 1) or 1))
    return end_time - start_time
  end
  if kind == "region" or kind == "time_selection" then
    if not position_end or position_end <= start_time then
      error("BAD_LENGTH: " .. kind .. " length needs a range position")
    end
    return position_end - start_time
  end
  if kind == "seconds" then return tonumber(length.seconds or 0) or 0 end
  if kind == "as_generated" then return nil end
  error("BAD_LENGTH: Unsupported length type " .. tostring(kind))
end

local function range_has_items(track, start_time, end_time)
  local overlaps = {}
  if not end_time or end_time <= start_time then return overlaps end
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if pos < end_time and (pos + len) > start_time then
      overlaps[#overlaps + 1] = { position = pos, length = len }
    end
  end
  return overlaps
end

local function delete_items_in_range(track, start_time, end_time)
  for i = reaper.CountTrackMediaItems(track) - 1, 0, -1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if pos < end_time and (pos + len) > start_time then
      reaper.DeleteTrackMediaItem(track, item)
    end
  end
end

local function insert_midi_payload(payload)
  local midi_path = payload.midi_path
  if not midi_path or not exists(midi_path) then
    error("MIDI_NOT_FOUND: " .. tostring(midi_path))
  end

  local track, track_index = find_track(payload)
  local start_time, position_end = resolve_position(payload.position)
  local requested_length = resolve_length(payload.length, position_end, start_time)
  local end_time = requested_length and (start_time + requested_length) or nil

  if end_time and payload.replace_existing_in_range then
    delete_items_in_range(track, start_time, end_time)
  elseif end_time then
    local overlaps = range_has_items(track, start_time, end_time)
    if #overlaps > 0 then error("RANGE_OCCUPIED: Existing item overlaps target range") end
  end

  reaper.SetOnlyTrackSelected(track)
  reaper.SetEditCurPos(start_time, false, false)
  local before = selected_item_count()
  reaper.InsertMedia(midi_path, 0)
  local item = reaper.GetSelectedMediaItem(0, 0)
  if selected_item_count() <= before or not item then
    item = reaper.GetTrackMediaItem(track, reaper.CountTrackMediaItems(track) - 1)
  end
  if not item then error("INSERT_FAILED: REAPER did not create a media item") end

  if requested_length and requested_length > 0 then
    reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", payload.loop == false and 0 or 1)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", requested_length)
  end
  reaper.UpdateArrange()

  local _, track_name = reaper.GetTrackName(track, "")
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  return {
    track = { index = track_index, name = track_name },
    item = {
      start_seconds = item_pos,
      end_seconds = item_pos + item_len,
      start_bar = bar_from_time(item_pos),
      length_seconds = item_len,
      looped = payload.loop ~= false,
    },
    midi_path = midi_path,
  }
end

local function command_insert_midi_file(command)
  return insert_midi_payload(command.payload or {})
end

local function command_audition_groove(command)
  local payload = command.payload or {}
  payload.loop = true
  local data = insert_midi_payload(payload)
  local start_time = data.item.start_seconds
  local end_time = data.item.end_seconds
  if payload.solo_track then
    local track = reaper.GetTrack(0, data.track.index - 1)
    if track then reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 1) end
  end
  reaper.GetSet_LoopTimeRange(true, true, start_time, end_time, false)
  reaper.SetEditCurPos(start_time, false, false)
  if payload.play ~= false then reaper.Main_OnCommand(1007, 0) end
  data.audition = { loop_start = start_time, loop_end = end_time, playing = payload.play ~= false }
  return data
end

local function command_play()
  reaper.Main_OnCommand(1007, 0)
  return { transport = get_transport() }
end

local function command_stop()
  reaper.Main_OnCommand(1016, 0)
  return { transport = get_transport() }
end

local function command_set_track_color(command)
  local payload = command.payload or {}
  local track = find_track(payload)
  local color = payload.color
  if type(color) == "table" then
    color = reaper.ColorToNative(color.r or 0, color.g or 0, color.b or 0) | 0x1000000
  end
  if type(color) ~= "number" then error("BAD_COLOR: Provide native color number or {r,g,b}") end
  reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", color)
  return { color = color }
end

local function command_solo_track(command)
  local payload = command.payload or {}
  local track = find_track(payload)
  reaper.SetMediaTrackInfo_Value(track, "I_SOLO", payload.solo == false and 0 or 1)
  return { solo = payload.solo ~= false }
end

local function command_get_fx_parameters(command)
  local payload = command.payload or {}
  local track, track_index, fx_index, fx_name, fx_scope, display_fx_index = find_fx(payload)
  local _, track_name = reaper.GetTrackName(track, "")
  local params = {}
  local param_count = reaper.TrackFX_GetNumParams(track, fx_index)
  local filter = payload.param_name_contains
  local offset = math.max(0, tonumber(payload.offset or 0) or 0)
  local limit = tonumber(payload.limit or 200) or 200
  if limit < 1 then limit = 1 end
  if limit > 1000 then limit = 1000 end
  local include_empty = payload.include_empty == true
  local matched_count = 0
  for param = 0, param_count - 1 do
    local info = get_fx_param_info(track, fx_index, param)
    local looks_empty = info.name:match("^#%d+$") and (info.formatted_value == nil or info.formatted_value == "")
    if (include_empty or not looks_empty) and (not filter or contains_ci(info.name, filter)) then
      matched_count = matched_count + 1
      if matched_count > offset and #params < limit then
        params[#params + 1] = info
      end
    end
  end
  return {
    track = { index = track_index, name = track_name, guid = reaper.GetTrackGUID(track) },
    fx = { index = display_fx_index or fx_index, api_index = fx_index, scope = fx_scope or "track", name = fx_name, parameter_count = param_count },
    parameters = params,
    paging = {
      offset = offset,
      limit = limit,
      returned = #params,
      matched_count = matched_count,
      has_more = matched_count > (offset + #params),
      include_empty = include_empty,
      filter = filter,
    },
  }
end

local function command_set_fx_param(command)
  local payload = command.payload or {}
  local track, track_index, fx_index, fx_name, fx_scope, display_fx_index = find_fx(payload)
  local param_index, before = find_fx_param(track, fx_index, payload)
  local ok = false

  if payload.normalized_value ~= nil then
    local value = tonumber(payload.normalized_value)
    if not value then error("BAD_PARAM_VALUE: normalized_value must be a number") end
    if value < 0 then value = 0 end
    if value > 1 then value = 1 end
    ok = reaper.TrackFX_SetParamNormalized(track, fx_index, param_index, value)
  elseif payload.relative ~= nil then
    local delta = tonumber(tostring(payload.relative):gsub("^%+", ""))
    if not delta then error("BAD_PARAM_VALUE: relative must be numeric, like +0.2 or -0.1") end
    local current = reaper.TrackFX_GetParamNormalized(track, fx_index, param_index)
    local value = current + delta
    if value < 0 then value = 0 end
    if value > 1 then value = 1 end
    ok = reaper.TrackFX_SetParamNormalized(track, fx_index, param_index, value)
  elseif payload.formatted_value ~= nil then
    local call_ok, retval = pcall(reaper.TrackFX_SetFormattedParamValue, track, fx_index, param_index, tostring(payload.formatted_value))
    if not call_ok then error("FORMATTED_VALUE_UNSUPPORTED: " .. tostring(retval)) end
    ok = retval
  else
    error("BAD_PARAM_VALUE: Provide normalized_value, relative, or formatted_value")
  end

  if not ok then error("SET_PARAM_FAILED: REAPER rejected the parameter value") end
  local after = get_fx_param_info(track, fx_index, param_index)
  local _, track_name = reaper.GetTrackName(track, "")
  return {
    track = { index = track_index, name = track_name, guid = reaper.GetTrackGUID(track) },
    fx = { index = display_fx_index or fx_index, api_index = fx_index, scope = fx_scope or "track", name = fx_name },
    parameter = { before = before, after = after },
  }
end

local function command_write_fx_param_automation(command)
  local payload = command.payload or {}
  local track, track_index, fx_index, fx_name, fx_scope, display_fx_index = find_fx(payload)
  local param_index, param_info = find_fx_param(track, fx_index, payload)
  local points = payload.points or {}
  if #points == 0 then error("NO_POINTS: Provide at least one automation point") end

  local envelope = reaper.GetFXEnvelope(track, fx_index, param_index, true)
  if not envelope then error("NO_ENVELOPE: Could not create FX envelope") end
  pcall(reaper.SetEnvelopeInfo_Value, envelope, "B_VISIBLE", 1)
  pcall(reaper.SetEnvelopeInfo_Value, envelope, "B_ARM", 1)
  pcall(reaper.SetEnvelopeInfo_Value, envelope, "I_TCPH", 80)

  local start_time = nil
  local end_time = nil
  if payload.range then
    start_time, end_time = resolve_position(payload.range)
  elseif payload.position then
    start_time, end_time = resolve_position(payload.position)
  end

  if payload.clear_existing_in_range then
    if not start_time or not end_time or end_time <= start_time then
      local min_time, max_time = nil, nil
      for _, point in ipairs(points) do
        local t = time_from_point(point)
        if not min_time or t < min_time then min_time = t end
        if not max_time or t > max_time then max_time = t end
      end
      start_time = min_time
      end_time = max_time
    end
    if start_time and end_time and end_time >= start_time then
      reaper.DeleteEnvelopePointRange(envelope, start_time, end_time)
    end
  end

  local inserted = {}
  for _, point in ipairs(points) do
    local t = time_from_point(point)
    local value = tonumber(point.value)
    if not value then error("BAD_POINT_VALUE: Automation point value must be numeric") end
    if value < 0 then value = 0 end
    if value > 1 then value = 1 end
    local shape = envelope_shape(point.shape)
    local tension = tonumber(point.tension or 0) or 0
    reaper.InsertEnvelopePoint(envelope, t, value, shape, tension, point.selected == true, true)
    inserted[#inserted + 1] = {
      time = t,
      bar = bar_from_time(t),
      value = value,
      shape = shape,
      source = point,
    }
  end
  reaper.Envelope_SortPoints(envelope)
  pcall(reaper.SetCursorContext, 2, envelope)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  local _, track_name = reaper.GetTrackName(track, "")
  return {
    track = { index = track_index, name = track_name, guid = reaper.GetTrackGUID(track) },
    fx = { index = display_fx_index or fx_index, api_index = fx_index, scope = fx_scope or "track", name = fx_name },
    parameter = param_info,
    inserted_count = #inserted,
    cleared_range = payload.clear_existing_in_range and { start_time = start_time, end_time = end_time } or nil,
    points = inserted,
  }
end

local handlers = {}

local function is_mutating(command_type)
  return command_type ~= "get_context" and command_type ~= "get_fx_parameters"
end

local function run_command(command, in_batch)
  if type(command) ~= "table" then error("BAD_COMMAND: Command is not an object") end
  if not command.type then error("BAD_COMMAND: Missing type") end
  local handler = handlers[command.type]
  if not handler then error("UNKNOWN_COMMAND: " .. tostring(command.type)) end

  if command.dry_run and command.type ~= "get_context" then
    return { dry_run = true, would_run = command.type, payload = command.payload or {} }
  end

  local undo_started = false
  if is_mutating(command.type) and not in_batch then
    reaper.Undo_BeginBlock()
    undo_started = true
  end
  local data = handler(command)
  if undo_started then
    reaper.Undo_EndBlock(command.undo_label or ("Agent: " .. command.type), -1)
  end
  return data
end

handlers.get_context = command_get_context
handlers.play = command_play
handlers.stop = command_stop
handlers.insert_midi_file = command_insert_midi_file
handlers.audition_groove = command_audition_groove
handlers.set_track_color = command_set_track_color
handlers.solo_track = command_solo_track
handlers.get_fx_parameters = command_get_fx_parameters
handlers.set_fx_param = command_set_fx_param
handlers.write_fx_param_automation = command_write_fx_param_automation

handlers.batch = function(command)
  local payload = command.payload or {}
  local commands = payload.commands or {}
  local results = {}
  reaper.Undo_BeginBlock()
  for i, sub in ipairs(commands) do
    local ok, data = pcall(run_command, sub, true)
    results[#results + 1] = { index = i, type = sub.type, ok = ok, data = ok and data or nil, error = ok and nil or tostring(data) }
    if not ok and payload.stop_on_error ~= false then
      reaper.Undo_EndBlock(command.undo_label or payload.undo_label or "Agent: batch failed", -1)
      error("BATCH_FAILED: sub-command " .. i .. " failed: " .. tostring(data))
    end
  end
  reaper.Undo_EndBlock(command.undo_label or payload.undo_label or "Agent: batch", -1)
  return { results = results }
end

local function write_result(command, ok, data_or_error)
  local result
  if ok then
    result = {
      id = command.id,
      ok = true,
      type = command.type,
      finished_at = now(),
      message = "Command completed: " .. tostring(command.type),
      data = data_or_error,
      warnings = {},
    }
  else
    result = {
      id = command.id,
      ok = false,
      type = command.type,
      finished_at = now(),
      message = tostring(data_or_error),
      error = { code = tostring(data_or_error):match("^([A-Z_]+):") or "COMMAND_FAILED", details = tostring(data_or_error) },
    }
  end
  atomic_write_json(paths.outbox .. "\\" .. command.id .. ".json", result)
end

local function process_file(filename)
  local inbox_path = paths.inbox .. "\\" .. filename
  local processing_path = paths.processing .. "\\" .. filename
  if not move_file(inbox_path, processing_path) then return end

  local command = nil
  local text = read_file(processing_path)
  local ok, parsed = pcall(json.decode, text or "")
  if ok then command = parsed else
    command = { id = filename:gsub("%.json$", ""), type = "parse" }
    write_result(command, false, "BAD_JSON: " .. tostring(parsed))
    move_file(processing_path, paths.failed .. "\\" .. filename)
    return
  end

  command.id = command.id or filename:gsub("%.json$", "")
  in_flight_command = command.id
  log_line("start " .. command.id .. " " .. tostring(command.type))
  local run_ok, data = pcall(run_command, command, false)
  write_result(command, run_ok, data)
  log_line((run_ok and "ok " or "fail ") .. command.id .. " " .. tostring(command.type))

  local destination = run_ok and paths.archive or paths.failed
  move_file(processing_path, destination .. "\\" .. filename)
  in_flight_command = nil
end

local function write_heartbeat()
  local heartbeat = {
    alive_at = now(),
    bridge_version = config.bridge_version or 2,
    project_name = get_project_name(),
    in_flight_command = in_flight_command,
    reaper_focused = true,
  }
  atomic_write_json(paths.heartbeat, heartbeat)
end

local function loop()
  local current = reaper.time_precise()
  if current - last_poll >= poll_interval then
    last_poll = current
    local ok, err = pcall(function()
      write_heartbeat()
      local files = list_inbox()
      if #files > 0 then process_file(files[1]) end
    end)
    if not ok then
      log_line("loop error " .. tostring(err))
      in_flight_command = nil
    end
  end
  reaper.defer(loop)
end

log_line("bridge started")
loop()
