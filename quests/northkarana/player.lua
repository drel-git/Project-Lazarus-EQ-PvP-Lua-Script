-- Project Lazarus EQ PvP Event Tracker for North Karana
-- - Zonewide yellow announce on PvP kills
-- - Temporary (event-scoped) kills/deaths in Data Buckets (TTL)
-- - Deterministic Event IDs: YYYYMMDD-HHMM[-Name]
-- - GM: start/stop/clear | Players: me/top/export/post (with pagination)

---------------------------
-- CONFIG
---------------------------
local MT_Yellow = 15
local ANNOUNCE_SCOPE = "zone"            -- "zone" or "world" for announcements
local EVENT_TTL_SECONDS = 36 * 60 * 60   -- ~36h; event data expires automatically
local ANTI_FEED_SECONDS = 45             -- ignore repeat killer->victim within N seconds

-- Pagination defaults
local DEFAULT_TOP_N  = 10   -- default "how many" if not specified
local TOP_PAGE_SIZE  = 10   -- default page size for !event top
local POST_PAGE_SIZE = 10   -- default page size for !event post

---------------------------
-- KEYS (scoped to this zone's event)
---------------------------
local function KEY_EVENT_ID()             return "nk:event:id" end         -- string
local function KEY_EVENT_ACTIVE()         return "nk:event:active" end     -- "1"/"0"
local function KEY_EVENT_END_TS()         return "nk:event:endts" end      -- unix ts (optional)
local function KEY_INDEX(eid)             return ("nk:%s:index"):format(eid) end
local function K_NAME(eid, cid)           return ("nk:%s:name:%d"):format(eid, cid) end
local function K_KILLS(eid, cid)          return ("nk:%s:kills:%d"):format(eid, cid) end
local function K_DEATHS(eid, cid)         return ("nk:%s:deaths:%d"):format(eid, cid) end
local function K_LAST_PAIR(eid, kid, vid) return ("nk:%s:lastpair:%d:%d"):format(eid, kid, vid) end

---------------------------
-- DATA BUCKET HELPERS (with TTL)
---------------------------
local function get_s(key)
  local v = eq.get_data(key)
  return (v == nil) and "" or v
end

local function set_s(key, val, ttl)
  eq.set_data(key, val or "", ttl or EVENT_TTL_SECONDS)
end

local function get_n(key)
  local v = get_s(key)
  if v == "" then return 0 end
  return tonumber(v) or 0
end

local function set_n(key, num, ttl)
  set_s(key, tostring(num or 0), ttl)
end

local function incr_n(key, delta, ttl)
  set_n(key, get_n(key) + (delta or 1), ttl)
end

---------------------------
-- MISC HELPERS
---------------------------
local function zmsg(msg)
  if ANNOUNCE_SCOPE == "world" then
    eq.world_message(MT_Yellow, msg)
  else
    if eq.zone_message then
      eq.zone_message(MT_Yellow, msg)
    else
      eq.world_message(MT_Yellow, msg)
    end
  end
end

local function tell(c, msg)
  if c and c.valid then c:Message(MT_Yellow, msg) end
end

local function split_csv(s)
  local t = {}
  if not s or s == "" then return t end
  for part in s:gmatch("([^,]+)") do table.insert(t, part) end
  return t
end

local function join_csv(t) return table.concat(t, ",") end

local function set_add_csv(s, item)
  local t = split_csv(s)
  local seen = {}
  for _,v in ipairs(t) do seen[v] = true end
  if not seen[item] then table.insert(t, item) end
  return join_csv(t)
end

local function now() return os.time() end

local function fmt_kd(k, d)
  if d <= 0 then return string.format("%.2f", k) end
  return string.format("%.2f", k / d)
end

local function chunk_and_send(client, text)
  -- send long outputs line-by-line to avoid chat-size limits
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then tell(client, line) end
  end
end

-- Deterministic Event IDs: YYYYMMDD-HHMM[-Name]
local function ymd_hm()
  local t = os.date("*t")
  return string.format("%04d%02d%02d-%02d%02d", t.year, t.month, t.day, t.hour, t.min)
end

---------------------------
-- EVENT LIFECYCLE
---------------------------
local function current_event_id()
  return get_s(KEY_EVENT_ID())
end

local function event_active()
  if get_s(KEY_EVENT_ACTIVE()) ~= "1" then return false end
  local endts = get_n(KEY_EVENT_END_TS())
  if endts > 0 and now() >= endts then
    set_s(KEY_EVENT_ACTIVE(), "0", EVENT_TTL_SECONDS) -- auto stop
    return false
  end
  return true
end

local function start_event(starter, name_opt, duration_minutes_opt)
  local eid = ymd_hm()
  if name_opt and name_opt ~= "" then
    eid = eid .. "-" .. name_opt:gsub("[^%w_%-]", "")
  end

  set_s(KEY_EVENT_ID(), eid, EVENT_TTL_SECONDS)
  set_s(KEY_EVENT_ACTIVE(), "1", EVENT_TTL_SECONDS)

  local dur = tonumber(duration_minutes_opt or 0) or 0
  if dur > 0 then
    set_n(KEY_EVENT_END_TS(), now() + (dur * 60), EVENT_TTL_SECONDS)
  else
    set_n(KEY_EVENT_END_TS(), 0, EVENT_TTL_SECONDS)
  end

  set_s(KEY_INDEX(eid), "", EVENT_TTL_SECONDS) -- fresh index

  zmsg(string.format("NK PvP Event started%s!",
    (name_opt and name_opt ~= "") and (": " .. name_opt) or ""))
  if dur > 0 then
    zmsg(string.format("Event will auto-end in %d minute(s).", dur))
  end
  tell(starter, "Event ID: " .. eid)
end

local function stop_event(stopper)
  if not event_active() then
    tell(stopper, "No active event.")
    return
  end
  set_s(KEY_EVENT_ACTIVE(), "0", EVENT_TTL_SECONDS)
  zmsg("NK PvP Event has ended! Use !event export or !event post to share the leaderboard.")
end

local function clear_event(clarifier)
  local eid = current_event_id()
  if eid == "" then
    tell(clarifier, "No event data to clear.")
    return
  end
  set_s(KEY_EVENT_ID(), "", EVENT_TTL_SECONDS)
  set_s(KEY_EVENT_ACTIVE(), "0", EVENT_TTL_SECONDS)
  set_n(KEY_EVENT_END_TS(), 0, EVENT_TTL_SECONDS)
  zmsg("NK PvP Event data cleared (old stats will expire shortly).")
end

---------------------------
-- RECORD KILL/DEATH (ACTIVE EVENT ONLY)
---------------------------
local function record_kill(killer, victim)
  if not event_active() then return end
  local eid = current_event_id()
  if eid == "" then return end
  local kid = killer:CharacterID()
  local vid = victim:CharacterID()

  -- anti-feed: same pair within short window
  local pair_key = K_LAST_PAIR(eid, kid, vid)
  local last_ts = get_n(pair_key)
  if last_ts > 0 and (now() - last_ts) < ANTI_FEED_SECONDS then
    set_n(pair_key, now(), ANTI_FEED_SECONDS) -- refresh window but do not count
    return
  end
  set_n(pair_key, now(), ANTI_FEED_SECONDS)

  -- update names and counts
  set_s(K_NAME(eid, kid), killer:GetCleanName(), EVENT_TTL_SECONDS)
  set_s(K_NAME(eid, vid),  victim:GetCleanName(), EVENT_TTL_SECONDS)
  incr_n(K_KILLS(eid, kid), 1, EVENT_TTL_SECONDS)
  incr_n(K_DEATHS(eid, vid), 1, EVENT_TTL_SECONDS)

  -- maintain participant index
  local idx_key = KEY_INDEX(eid)
  local idx = get_s(idx_key)
  idx = set_add_csv(idx, tostring(kid))
  idx = set_add_csv(idx, tostring(vid))
  set_s(idx_key, idx, EVENT_TTL_SECONDS)

  -- announce
  local msg = string.format("NK PvP: %s has slain %s! (Event Kills: %d)",
    killer:GetCleanName(), victim:GetCleanName(), get_n(K_KILLS(eid, kid)))
  zmsg(msg)
end

---------------------------
-- BUILD & RENDER LEADERBOARD
---------------------------
local function collect_rows(limit)
  local eid = current_event_id()
  if eid == "" then return {}, "" end
  local ids = split_csv(get_s(KEY_INDEX(eid)))
  local rows = {} -- {name=, kills=, deaths=, ratio=}
  for _, id in ipairs(ids) do
    local k = get_n(K_KILLS(eid, id))
    local d = get_n(K_DEATHS(eid, id))
    if k > 0 or d > 0 then
      local nm = get_s(K_NAME(eid, id))
      if nm == "" then nm = ("#" .. tostring(id)) end
      table.insert(rows, { name = nm, kills = k, deaths = d, ratio = (d == 0) and k or (k / d) })
    end
  end

  table.sort(rows, function(a,b)
    if a.kills ~= b.kills then return a.kills > b.kills end
    if a.ratio ~= b.ratio then return a.ratio > b.ratio end
    return a.deaths < b.deaths
  end)

  local n = math.min(limit or DEFAULT_TOP_N, #rows)
  local out = {}
  for i=1,n do table.insert(out, rows[i]) end
  return out, eid
end

local function render_table(rows, title)
  local header = string.format("%s\n%s", title, "-------------------------------------------")
  local lines = {
    header,
    string.format("%-5s %-18s %5s %5s %7s", "Rank", "Name", "K", "D", "K/D")
  }
  for i, r in ipairs(rows) do
    table.insert(lines, string.format("%-5s %-18s %5d %5d %7s",
      "#" .. i, r.name, r.kills, r.deaths, fmt_kd(r.kills, r.deaths)))
  end
  return table.concat(lines, "\n")
end

local function render_markdown(rows, eid)
  local t = { string.format("**North Karana PvP — Event %s**", eid), "", "```" }
  table.insert(t, string.format("%-5s %-18s %5s %5s %7s", "Rank", "Name", "K", "D", "K/D"))
  for i, r in ipairs(rows) do
    table.insert(t, string.format("%-5s %-18s %5d %5d %7s",
      "#" .. i, r.name, r.kills, r.deaths, fmt_kd(r.kills, r.deaths)))
  end
  table.insert(t, "```")
  table.insert(t, string.format("_Temporary event stats. Will expire ~%dh after last update._", math.floor(EVENT_TTL_SECONDS/3600)))
  return table.concat(t, "\n")
end

-- Pagination helper (used by !event top and !event post)
local function paginate_rows(rows, n, page, default_page_size)
  local total = #rows
  local per = (n and n > 0) and n or (default_page_size or 10)
  local pages = math.max(1, math.ceil(total / per))
  local p = math.max(1, math.min(page and page > 0 and page or 1, pages))
  local start_i = (p - 1) * per + 1
  local end_i = math.min(start_i + per - 1, total)
  local slice = {}
  for i = start_i, end_i do table.insert(slice, rows[i]) end
  return slice, p, pages, total, start_i, end_i
end

---------------------------
-- COMMANDS
---------------------------
local function handle_command(e)
  local raw = e.message or ""
  if raw:sub(1,1) ~= "!" then return false end
  local msg = raw:lower()
  local tokens = {}
  for t in raw:gmatch("%S+") do table.insert(tokens, t) end
  local function is_gm(c) return c and c.valid and c:GetGM() end

  -- help
  if msg == "!event" or msg == "!event help" then
    tell(e.self, "NK PvP Event commands:")
    tell(e.self, "!event start [name] [minutes]  (GM)  — start event (optional name/duration)")
    tell(e.self, "!event stop                     (GM)  — stop the active event")
    tell(e.self, "!event clear                    (GM)  — clear event id/data (soft)")
    tell(e.self, "!event me                              — your event K/D")
    tell(e.self, "!event top [N] [page]                 — show top N (default 10), paginated")
    tell(e.self, "!event export                         — print Markdown leaderboard for Discord")
    tell(e.self, "!event post [N] [page]                — broadcast leaderboard to zone/world")
    return true
  end

  -- GM: start
  if msg:find("^!event start") == 1 then
    if not is_gm(e.self) then tell(e.self, "You do not have permission.") return true end
    local name = tokens[3] or ""
    local minutes = tokens[4] or ""
    start_event(e.self, name, minutes)
    return true
  end

  -- GM: stop
  if msg == "!event stop" then
    if not is_gm(e.self) then tell(e.self, "You do not have permission.") return true end
    stop_event(e.self)
    return true
  end

  -- GM: clear
  if msg == "!event clear" then
    if not is_gm(e.self) then tell(e.self, "You do not have permission.") return true end
    clear_event(e.self)
    return true
  end

  -- Player: me
  if msg == "!event me" then
    local eid = current_event_id()
    if eid == "" or not event_active() then
      tell(e.self, "No active NK PvP event.")
      return true
    end
    local cid = e.self:CharacterID()
    local k = get_n(K_KILLS(eid, cid))
    local d = get_n(K_DEATHS(eid, cid))
    tell(e.self, string.format("NK Event — %s: Kills %d, Deaths %d, K/D %s",
      e.self:GetCleanName(), k, d, fmt_kd(k,d)))
    return true
  end

  -- Player: top [N] [page] (paginated)
  if msg:find("^!event top") == 1 then
    local n = tonumber(tokens[3] or "") or TOP_PAGE_SIZE
    local page = tonumber(tokens[4] or "") or 1
    local rows, eid = collect_rows(n == 0 and DEFAULT_TOP_N or math.max(n, 1))
    if eid == "" then tell(e.self, "No event is initialized. GM can start one with !event start") return true end
    if #rows == 0 then tell(e.self, "No PvP stats recorded for this event yet.") return true end

    local slice, p, pages, total, start_i, end_i = paginate_rows(rows, n, page, TOP_PAGE_SIZE)
    if #slice == 0 then
      tell(e.self, string.format("No entries for page %d. Valid pages: 1-%d.", page, pages))
      return true
    end

    local header = string.format("NK PvP — Event %s | Top %d (Page %d/%d, Showing %d–%d of %d)",
                    eid, n, p, pages, start_i, end_i, total)
    local lines = { header,
                    string.format("%-5s %-18s %5s %5s %7s", "Rank", "Name", "K", "D", "K/D") }
    for i, r in ipairs(slice) do
      local global_rank = start_i + i - 1
      table.insert(lines, string.format("%-5s %-18s %5d %5d %7s",
        "#" .. global_rank, r.name, r.kills, r.deaths, fmt_kd(r.kills, r.deaths)))
    end
    if p < pages then
      table.insert(lines, string.format("Use !event top %d %d for next page.", n, p + 1))
    end
    chunk_and_send(e.self, table.concat(lines, "\n"))
    return true
  end

  -- Player/GM: export (Markdown)
  if msg == "!event export" then
    local rows, eid = collect_rows(DEFAULT_TOP_N)
    if eid == "" then tell(e.self, "No event is initialized.") return true end
    if #rows == 0 then tell(e.self, "No PvP stats recorded for this event yet.") return true end
    local md = render_markdown(rows, eid)
    chunk_and_send(e.self, md)
    return true
  end

  -- Player/GM: post [N] [page] — broadcast (paginated)
  if msg:find("^!event post") == 1 then
    local n = tonumber(tokens[3] or "") or POST_PAGE_SIZE
    local page = tonumber(tokens[4] or "") or 1
    local rows, eid = collect_rows(n == 0 and DEFAULT_TOP_N or math.max(n, 1))
    if eid == "" then tell(e.self, "No event is initialized.") return true end
    if #rows == 0 then tell(e.self, "No PvP stats recorded for this event yet.") return true end

    local slice, p, pages, total, start_i, end_i = paginate_rows(rows, n, page, POST_PAGE_SIZE)
    if #slice == 0 then
      tell(e.self, string.format("No entries for page %d. Valid pages: 1-%d.", page, pages))
      return true
    end

    zmsg(string.format("NK PvP — Event %s | Top %d (Page %d/%d, Showing %d–%d of %d)",
        eid, n, p, pages, start_i, end_i, total))
    zmsg(string.format("%-5s %-18s %5s %5s %7s", "Rank", "Name", "K", "D", "K/D"))
    for i, r in ipairs(slice) do
      local global_rank = start_i + i - 1
      zmsg(string.format("%-5s %-18s %5d %5d %7s",
        "#" .. global_rank, r.name, r.kills, r.deaths, fmt_kd(r.kills, r.deaths)))
    end
    if p < pages then
      zmsg(string.format("Use !event post %d %d for next page.", n, p + 1))
    end
    return true
  end

  return false
end

---------------------------
-- EVENTS
---------------------------
function event_enter_zone(e)
  tell(e.self, "North Karana PvP: Type !event for commands. GMs can start/stop an event.")
end

function event_say(e)
  if handle_command(e) then return end
end

-- Fires on the KILLER; victim is e.other
function event_pvp_kill(e)
  if not event_active() then return end
  local killer = e.self
  local victim = e.other
  if killer and killer.valid and victim and victim.valid then
    record_kill(killer, victim)
  end
end

function event_death(e)
  -- no-op: deaths are counted at time of being the PvP victim
end

function event_connect(e)
  if event_active() then
    local eid = current_event_id()
    if eid ~= "" then tell(e.self, ("NK PvP Event %s is ACTIVE — type !event for info."):format(eid)) end
  end
end
