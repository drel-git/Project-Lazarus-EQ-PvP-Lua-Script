# Project-Lazarus-EQ-PvP-Lua-Script

Lua script for use on the Project Lazarus EQ Emu server for PvP events

__Path: quests/northkarana/player.lua__

- Zone-wide PvP kill announce (yellow)

- Temporary event-scoped kills/deaths

- Leaderboard of kills/deaths with pagination, export Discord-ready Markdown tables, and broadcast results zonewide.

- Anti-feed window, TTL auto-expiry

- Deterministic event IDs (YYYYMMDD-HHMM[-Name])

- GM controls: !event start [name] [minutes], !event stop, !event clear

- Player commands: !event me, !event top [N] [page] (paginated), !event export

- Broadcast: !event post [N] [page] (paginated)

## Installation
1) Place the script in your EQEmu server under:
```quests/northkarana/player.lua```
2) Reload quests in-game or restart the zone:
```#reloadquest```
3) By default, announcements are zonewide. To make them serverwide, change:
```local ANNOUNCE_SCOPE = "world"```


## GM Commands
!event start [name] [minutes] → Start a new event (optional name + duration)

!event stop                   → Stop the current event

!event clear                  → Clear/reset all event data

## Player Commands
!event                  → Show help

!event me               → Show your kills, deaths, and K/D

!event top [N] [page]   → Show top N players (default 10), paginated

!event export           → Print full Markdown leaderboard for Discord

