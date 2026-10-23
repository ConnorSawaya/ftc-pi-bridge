# ftc-pi-bridge

Upload FTC robot code from a Mac **while the Mac's Wi-Fi stays on the internet**.

```
Mac ──USB──► Raspberry Pi Zero 2 W ──Wi-Fi──► Control Hub
     adb connect 10.12.194.1:5555
```

> Not yet tested end-to-end with a Control Hub.

## Parts
- Raspberry Pi Zero 2 W (a Pi 4 or Pi 5 also works, through its USB-C port; the Pi 5 also has 5 GHz Wi-Fi)
- microSD card, 16–32 GB
- USB-C to micro-USB **data** cable (charge-only cables won't work)

## Setup (once)
1. `./install.sh`: builds the menu bar app, installs the `ftc-bridge` command, and adds the AI tools to Claude Code, Codex, OpenCode and the Claude desktop app if you have them (it asks first).
2. `brew install --cask raspberry-pi-imager`
3. Put the SD card in the Mac and run `./flash.sh`. Type which disk to erase.
4. Put the card in the Pi. Plug the Pi's **middle** micro-USB port (labelled USB, not PWR) into the Mac. Wait ~3 minutes the first time.
5. Save your robots: in the menu bar app, **Add robot**, pick your robot from the list, type its Wi-Fi password, **Save & Connect**. Or in the terminal: `ftc-bridge add comp 12345-RC` (asks for the password).

## Every time
1. Plug in the Pi and turn on the robot. The menu bar icon shows radio waves when it's connected.
2. In Android Studio, pick the Control Hub and press Run. The app connects adb for you (without the app: `adb connect 10.12.194.1:5555`).

**Different robot?** Click it in the menu bar app, or `ftc-bridge use practice`.

## Menu bar app
| Icon | Meaning |
|---|---|
| radio waves | Connected to the robot |
| radio waves, crossed out | Pi plugged in, robot not reachable (robot off, or none chosen) |
| plug | Pi not plugged in |

The **Health** card shows the Wi-Fi signal and channel, whether the robot app and adb answer, whether it's the same hub this robot had before (so you don't upload to the wrong robot), and a **Test** button for the real upload speed.

If robot code throws, freezes, or crashes the app, you get a notification with the error and the line in your code, and a **Copy error** button for pasting into an AI chat.

**Open Panels** opens the robot's Panels dashboard (telemetry, graphs, OpMode control, Limelight) in your browser at `http://localhost:8001`, through the Pi. The robot code needs Panels.

The ⚙ button has settings (open at login, robot name in the menu bar, connect Android Studio, notifications, crash alerts), **Back up robot**, and Pi controls: **Disconnect from robot**, **Restart Pi**, **Shut down Pi**.

## Terminal command (for you or an AI agent)
```
ftc-bridge status               which robot the Pi is on, and whether it answers
ftc-bridge robots               saved robots (name, Wi-Fi name)
ftc-bridge scan                 nearby Wi-Fi networks
ftc-bridge add NAME WIFI_NAME   save a robot; password from stdin (asked if you're typing)
ftc-bridge use NAME             switch to that robot
ftc-bridge forget NAME          delete a saved robot
ftc-bridge disconnect           take the Pi off the robot's Wi-Fi
ftc-bridge reboot | shutdown    restart or shut down the Pi
ftc-bridge update-pi            update the Pi's software from this Mac
ftc-bridge health               signal, channel, robot app, adb, and whether it's the same hub as before
ftc-bridge speedtest            real upload speed to the robot
ftc-bridge upload [NAME]        send code to the robot (run in the robot project); uses Sloth if the project has it
ftc-bridge upload --full [NAME] full install + app restart (after changing libraries); backs up the robot first
ftc-bridge test                 run the TeamCode unit tests (no robot needed)
ftc-bridge logs [--errors] [N]  the robot's recent log
ftc-bridge crashes [N]          crashes and exceptions in the robot's recent log
ftc-bridge backup               save the robot's configs and app to this Mac (newest 5 kept per robot)
ftc-bridge backups              list backups
ftc-bridge restore ROBOT/TIME   put a backup back on the robot
ftc-bridge panels [--stop]      open the robot's Panels dashboard at http://localhost:8001
ftc-bridge adb ARGS...          any adb command, sent to the robot through the Pi
```
An agent passes the password on stdin, so it isn't in the command line:
`printf '%s\n' 'the-password' | ftc-bridge add comp 12345-RC`

## AI apps (MCP)
`mcp/server.py` gives AI apps these tools: `status`, `health`, `list_robots`, `scan`, `use_robot`, `upload`, `run_tests`, `logs`, `crashes`, `speed_test`, `backup`, `list_backups`, `restore_backup`, `open_panels`, `read_telemetry` (live Panels values), `update_pi`, `disconnect`. `install.sh` sets it up; to do it by hand, it needs [uv](https://docs.astral.sh/uv/) (`brew install uv`):

**Claude Code:**
```bash
claude mcp add --scope user ftc-bridge -- uv run /path/to/ftc-pi-bridge/mcp/server.py
```

**Claude desktop app:** add to `~/Library/Application Support/Claude/claude_desktop_config.json`, then restart the app:
```json
{ "mcpServers": { "ftc-bridge": { "command": "/opt/homebrew/bin/uv", "args": ["run", "/path/to/ftc-pi-bridge/mcp/server.py"] } } }
```

**Codex:** add to `~/.codex/config.toml`:
```toml
[mcp_servers.ftc-bridge]
command = "uv"
args = ["run", "/path/to/ftc-pi-bridge/mcp/server.py"]
```

Paste this into your robot repo's `CLAUDE.md` / `AGENTS.md`:
> To upload robot code: run `ftc-bridge robots` and make sure you know which robot the user means (ask if unclear). Then run `ftc-bridge upload <name>` from the project root. If it fails, run `ftc-bridge status` and report what it says.

## Updating
`git pull`, then `./install.sh` (rebuilds the app). If the Pi's software changed, the app shows **Update the Pi**; one click updates it over USB, no reflashing.

## Things to know
- **On a Pi Zero 2 W, the robot must be on 2.4 GHz.** It can't see 5 GHz. Control Hubs ship on 2.4 GHz, but events may ask you to use 5 GHz; there, use the normal USB cable.
- **Before a match, disconnect the Pi** (⚙ → Disconnect from robot, `ftc-bridge disconnect`, or unplug it). Rule R704.C: only the Driver Station may be on the robot's Wi-Fi during a match.
- **Shut down the Pi before unplugging it** (⚙ → Shut down Pi) to protect the SD card.
- **Don't turn on macOS Internet Sharing for the Pi.** The Pi changes its address when you do.
- **Debugging the Pi:** `ssh -i ~/.ssh/ftcpi ftc@10.12.194.1`

## What's in here
| File | Does |
|---|---|
| `flash.sh` | Writes Raspberry Pi OS Lite plus the files below onto the SD card |
| `pi/adb-forward.py` | Forwards port 5555 from the USB link to the robot at `192.168.43.1:5555` |
| `pi/no-gateway.conf` | Keeps the Mac's internet on its own Wi-Fi |
| `pi/ftc-hub` | Saves and switches robots on the Pi |
| `install.sh` | Sets everything up on a Mac |
| `ftc-bridge` | The terminal command |
| `mcp/server.py` | The MCP server for AI apps |
| `mac/` | The FTC Bridge menu bar app |

## License
MIT
