# ftc-pi-bridge

Upload FTC robot code from a Mac **while the Mac's Wi-Fi stays on the internet**.

```
Mac ──USB──► Raspberry Pi Zero 2 W ──Wi-Fi──► Control Hub
     adb connect 10.12.194.1:5555
```

> **Status:** tested on a Raspberry Pi 5 (USB link, ADB forwarder, saved robots, Wi-Fi scan). Not yet tested end-to-end with a Control Hub or on a Pi Zero 2 W.

## Parts
- Raspberry Pi Zero 2 W (a Pi 4 or Pi 5 also works, through its USB-C port; the Pi 5 also has 5 GHz Wi-Fi)
- microSD card, 16–32 GB
- USB-C to micro-USB **data** cable (charge-only cables won't work)

## Setup (once)
1. `brew install --cask raspberry-pi-imager`
2. Put the SD card in the Mac and run `./flash.sh`. Type which disk to erase.
3. Put the card in the Pi. Plug the Pi's **middle** micro-USB port (labelled USB, not PWR) into the Mac. Wait ~3 minutes the first time.
4. Build the menu bar app: `./mac/build.sh`, then open **FTC Bridge** from Applications.
5. Put the terminal command on your PATH: `ln -sf "$PWD/ftc-bridge" ~/.local/bin/ftc-bridge`
6. Save your robots, in the menu bar app (**Scan**, pick the hub, type its password, **Save & Connect**) or in the terminal:
   `ftc-bridge add comp 12345-RC` (asks for the password)

## Every time
1. Plug in the Pi and turn on the robot. The menu bar icon shows the radio waves when it's connected.
2. `adb connect 10.12.194.1:5555`
3. In Android Studio, pick the Control Hub and press Run.

**Different robot?** Click it in the menu bar app, or `ftc-bridge use practice`.

## Terminal command (for you or an AI agent)
```
ftc-bridge status               which robot the Pi is on, and whether its hub answers
ftc-bridge robots               saved robots (name, Wi-Fi name)
ftc-bridge scan                 nearby Wi-Fi networks
ftc-bridge add NAME WIFI_NAME   save a robot; password from stdin (asked if you're typing)
ftc-bridge use NAME             switch to that robot
ftc-bridge forget NAME          delete a saved robot
ftc-bridge upload [NAME]        send code to the robot (run in the robot project); uses Sloth if the project has it
ftc-bridge upload --full [NAME] full install + app restart (after changing libraries)
ftc-bridge test                 run the TeamCode unit tests (no robot needed)
ftc-bridge logs [--errors] [N]  the robot's recent log (a snapshot, not a live stream)
ftc-bridge adb ARGS...          any adb command, sent to the robot through the Pi
```
An agent passes the password on stdin so it never appears in a command line:
`printf '%s\n' 'the-password' | ftc-bridge add comp 12345-RC`

Paste this into your robot repo's `CLAUDE.md` / `AGENTS.md`:
> To upload robot code: run `ftc-bridge robots` and make sure you know which robot the user means (ask if unclear). Then run `ftc-bridge upload <name>` from the project root. If it fails, run `ftc-bridge status` and report what it says.

## Menu bar icon
| Icon | Meaning |
|---|---|
| radio waves | Connected to the hub |
| radio waves, crossed out | Pi plugged in, hub not reachable (robot off, or no hub chosen) |
| plug | Pi not plugged in |

## Things to know
- **On a Pi Zero 2 W, the hub must be on 2.4 GHz.** It can't see 5 GHz. Control Hubs ship on 2.4 GHz, but events may ask you to use 5 GHz; there, use the normal USB cable.
- **Unplug the Pi during matches.** Rule R704.C: nothing but the Driver Station may be on the robot's Wi-Fi during a match. Bluetooth is turned off on the Pi (rule E301).
- **Don't turn on macOS Internet Sharing for the Pi.** The Pi changes its address when you do.
- **Debugging the Pi:** `ssh -i ~/.ssh/ftcpi ftc@10.12.194.1`

## What's in here
| File | Does |
|---|---|
| `flash.sh` | Writes Raspberry Pi OS Lite plus the files below onto the SD card (via cloud-init) |
| `pi/adb-forward.py` | Forwards port 5555 from the USB link to the hub at `192.168.43.1:5555` |
| `pi/no-gateway.conf` | Stops the Pi from becoming the Mac's internet route |
| `pi/ftc-hub` | Saves / switches robots on the Pi; the app and `ftc-bridge` call it over SSH |
| `ftc-bridge` | The terminal command |
| `mac/` | The FTC Bridge menu bar app (SwiftUI, one file) |

The `.gitignore` refuses robot code (`TeamCode/`, `FtcRobotController/`), robot configs (`*.xml`), keys and builds, so they can't be committed here by accident.

Robot Wi-Fi passwords are saved only on the Pi. They aren't stored on the Mac or in this repo.

## License
MIT
