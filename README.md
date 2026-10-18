# CC Warship

[Ship Pilot](https://github.com/levisnakes/cc-ship-pilot) and [Fire Control](https://github.com/levisnakes/cc-fire-control) running together on **one** computer on a Sable ship. Fly from the Linked Typewriter while the radar-aimed cannons fire by themselves.

## Install

```
wget https://raw.githubusercontent.com/levisnakes/cc-warship/main/warship.lua startup.lua
reboot
```

On boot it downloads the newest `ship.lua` and `fire_control.lua` (if they're missing or out of date), then starts both. If `startup.lua` already exists, `rm startup.lua` first. An existing `ship.lua` / `ship.cfg` / `fire_control.lua` is kept and used.

## Hardware

Everything both programs need, on the same wired modem network as the computer: Linked Typewriter, thrusters, relay/transmission (pilot), Cannon Mounts and a radar (guns). See each program's README.

## Screens

| Key (on the computer) | |
|---|---|
| `` ` `` (under Esc) | switch between the **Pilot** and **Guns** screens |

- **Typewriter keys always go to the pilot**, whichever screen is shown, so turning left with A never arms the cannons.
- Keys typed on the computer, and mouse clicks, go to the screen you're looking at (Guns: A arm/safe, X ignore, U un-ignore, F fire).
- An Advanced Monitor mirrors the pilot's screens, the same as plain Ship Pilot.
- If one program crashes, the other keeps running. Its screen shows the error. Press Enter there to restart it.
- Ctrl+T stops both: thrusters off, lift held, triggers released.

## Settings

| Program | Where |
|---|---|
| Pilot | its menus (saved in `ship.cfg`) or `ship_settings.lua` |
| Guns | the UPPERCASE lines at the top of `fire_control.lua`, or `/config.lua` |
| Warship | `SWITCH_KEY` and `START_ON` (`"pilot"` or `"guns"`) at the top of `startup.lua` |

## Updates

- Warship and Ship Pilot update at boot, so a restart is an update.
- Fire Control's own 15-minute updater keeps working. When it updates, it restarts **only the guns**, never the whole computer, so the ship keeps flying.
