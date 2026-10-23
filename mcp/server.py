# /// script
# requires-python = ">=3.10"
# dependencies = ["mcp>=2.3,<3", "websockets>=13"]
# ///
"""MCP server for ftc-pi-bridge: lets an AI app check the robot, switch robots, and upload code.

Each tool runs the matching `ftc-bridge` command and returns what it printed.
Run with:  uv run mcp/server.py   (uv installs the MCP library the first time)
"""
import asyncio
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import websockets

from mcp.server.mcpserver import MCPServer

# The ftc-bridge command next to this folder (the PowerShell one on Windows), else whichever is on PATH.
HERE = Path(__file__).resolve().parent
if os.name == "nt":
    BRIDGE = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(HERE.parent / "windows" / "ftc-bridge.ps1")]
elif (HERE.parent / "ftc-bridge").exists():
    BRIDGE = [str(HERE.parent / "ftc-bridge")]
else:
    BRIDGE = [shutil.which("ftc-bridge") or "ftc-bridge"]
MAX_OUTPUT = 40_000  # characters; long logs are cut from the top

mcp = MCPServer(
    "ftc-bridge",
    instructions="Uploads FTC robot code through a Raspberry Pi on this Mac's USB. Check list_robots and "
    "ask the user which robot if it's unclear. Run run_tests before upload, and check logs after.",
)


def run(*args: str, cwd: str | None = None, timeout: int = 60, ok: tuple[int, ...] = (0,)) -> str:
    try:
        p = subprocess.run([*BRIDGE, *args], cwd=cwd, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return f"FAILED: ftc-bridge {' '.join(args)} took longer than {timeout} s"
    out = (p.stdout + p.stderr).strip()
    if len(out) > MAX_OUTPUT:
        out = "…(cut)…\n" + out[-MAX_OUTPUT:]
    return out if p.returncode in ok else f"FAILED (exit {p.returncode}):\n{out}"


def project_dir(project: str | None) -> tuple[str, str | None]:
    """The robot project folder, and an error message if it isn't one."""
    path = Path(project or os.getcwd()).expanduser()
    if not (path / "gradlew").exists():
        return str(path), f"FAILED: {path} is not a robot project (no gradlew). Pass the robot project's folder as `project`."
    return str(path), None


@mcp.tool()
def status() -> str:
    """Which robot the Pi is on, and whether its Control Hub answers."""
    return run("status", ok=(0, 1))  # 1 = not connected to a robot, which is a status, not a failure


@mcp.tool()
def list_robots() -> str:
    """Saved robots, one per line: name, then Wi-Fi name. If the user didn't say which robot, ask them."""
    return run("robots") or "No robots saved yet. The user can add one in the FTC Bridge menu bar app."


@mcp.tool()
def scan() -> str:
    """Wi-Fi networks the Pi can see right now."""
    return run("scan")


@mcp.tool()
def use_robot(name: str) -> str:
    """Switch the Pi to a saved robot (a name from list_robots)."""
    return run("use", name)


@mcp.tool()
def upload(robot: str, full: bool = False, project: str | None = None) -> str:
    """Build the robot code and put it on the robot. Switches to `robot` first.

    Uses Sloth hot reload (about 1 s) if the project has it; changes apply when the running
    OpMode stops. Set full=True after changing libraries or Gradle files, or if a change
    didn't take effect. `project` is the robot project folder (default: current folder).
    Never guess `robot`: ask the user if it's unclear.
    """
    folder, problem = project_dir(project)
    if problem:
        return problem
    args = ["upload", "--full", robot] if full else ["upload", robot]
    return run(*args, cwd=folder, timeout=900)


@mcp.tool()
def run_tests(project: str | None = None) -> str:
    """Run the TeamCode unit tests on this Mac (no robot needed). Run them before uploading."""
    folder, problem = project_dir(project)
    return problem or run("test", cwd=folder, timeout=900)


@mcp.tool()
def logs(errors_only: bool = False, lines: int = 300, since_mark: bool = False) -> str:
    """The robot's recent log. Instant while the FTC Bridge app records the log (it does by default).

    since_mark=True returns everything since the last upload or mark_log, which is usually what you
    want after uploading and running an OpMode. errors_only keeps errors, fatals and markers.
    """
    args = ["logs", str(lines)]
    if errors_only:
        args.append("--errors")
    if since_mark:
        args.append("--since-mark")
    return run(*args)


@mcp.tool()
def search_logs(pattern: str, lines: int = 20000) -> str:
    """Search the robot's log for a regex (any case), with 2 lines of context, up to 200 lines.
    E.g. a tag, an OpMode name, "Exception", or a telemetry key the code logs."""
    return run("search", pattern, str(lines))


@mcp.tool()
def mark_log(note: str) -> str:
    """Write a marker into the recorded log (e.g. "user is testing the intake now"), so
    logs(since_mark=True) returns only what happens after it. Uploads add one by themselves."""
    return run("mark", note)


@mcp.tool()
def health() -> str:
    """Check the robot connection: Wi-Fi signal and channel, whether the robot app and adb answer,
    and whether this is the same hub as before for this robot name (catches the wrong robot)."""
    return run("health", ok=(0, 1), timeout=90)


@mcp.tool()
def speed_test() -> str:
    """Measure the real upload speed to the robot in MB/s (sends 8 MB through adb, then deletes it)."""
    return run("speedtest", timeout=120)


@mcp.tool()
def crashes(lines: int = 3000) -> str:
    """Find crashes in the robot's recent log: uncaught exceptions in OpModes (with the line in
    the team's code), stuck OpModes, and app crashes. Use this after an upload or when the
    Driver Station shows an error."""
    return run("crashes", str(lines), timeout=90)


@mcp.tool()
def backup() -> str:
    """Save the robot's configs and app to this Mac (newest 5 per robot are kept).
    Full uploads do this by themselves first."""
    return run("backup", timeout=300)


@mcp.tool()
def list_backups() -> str:
    """Backups on this Mac, newest first, as ROBOT/TIME."""
    return run("backups")


@mcp.tool()
def restore_backup(backup: str) -> str:
    """Put a backup's app and configs back on the robot. `backup` is ROBOT/TIME from list_backups.
    Refuses if the backup is from a different hub; tell the user if so."""
    return run("restore", backup, timeout=300)


@mcp.tool()
def open_panels() -> str:
    """Tunnel the robot's Panels dashboard to this Mac and return its address (http://localhost:8001).

    Open that address in a browser to see telemetry, graphs, OpMode controls and the Limelight.
    """
    return run("panels", "--no-open")


@mcp.tool()
async def read_telemetry(seconds: float = 3.0) -> str:
    """Listen to the robot's live Panels data for a few seconds and return the latest of each kind.

    Panels sends JSON messages {pluginID, messageID, data}; telemetry lines come from the
    telemetry plugin. An OpMode has to be running (started from the Driver Station) for most
    values to update.
    """
    setup = run("panels", "--no-open")
    if setup.startswith("FAILED"):
        return setup
    latest: dict[str, object] = {}
    count = 0
    try:
        async with websockets.connect("ws://localhost:8002", open_timeout=5) as ws:
            end = time.monotonic() + min(max(seconds, 0.5), 30)
            while (left := end - time.monotonic()) > 0:
                try:
                    raw = await asyncio.wait_for(ws.recv(), timeout=left)
                except asyncio.TimeoutError:
                    break
                count += 1
                try:
                    msg = json.loads(raw)
                    latest[f"{msg.get('pluginID')}/{msg.get('messageID')}"] = msg.get("data")
                except (ValueError, AttributeError):
                    latest["(not JSON)"] = str(raw)[:500]
    except (OSError, websockets.exceptions.WebSocketException) as e:
        return f"FAILED: couldn't read Panels live data ({e}). Is Panels in the robot code and the robot app running?"
    if not latest:
        return f"Connected, but no messages in {seconds:g} s. Start an OpMode from the Driver Station."
    out = json.dumps(latest, indent=1, default=str)
    if len(out) > MAX_OUTPUT:
        out = out[:MAX_OUTPUT] + "\n…(cut)…"
    return f"{count} messages in {seconds:g} s; latest of each kind:\n{out}"


@mcp.tool()
def update_pi() -> str:
    """Update the Pi's software from this Mac if it's out of date (about 10 s; adb reconnects after)."""
    version = run("pi-version")
    if "up to date" in version or version.startswith("FAILED"):
        return version
    return run("update-pi", timeout=180)


@mcp.tool()
def disconnect() -> str:
    """Take the Pi off the robot's Wi-Fi. Required before a match (rule R704.C)."""
    return run("disconnect")


if __name__ == "__main__":
    mcp.run()
