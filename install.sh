#!/bin/bash
# Set up ftc-pi-bridge on this Mac:
#   ./install.sh         build the menu bar app, install the ftc-bridge command, and add the
#                        MCP server to the AI apps it finds (asks before each)
#   ./install.sh --yes   the same without asking
# Safe to run again. Making the SD card is separate: ./flash.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER="$HERE/mcp/server.py"
YES=""; [[ "${1:-}" == "--yes" ]] && YES=1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
ask()  { [[ -n "$YES" ]] && return 0; read -r -p "  $1 [Y/n] " a; [[ -z "$a" || "$a" =~ ^[Yy] ]]; }

echo "Checking this Mac"
[[ "$(uname)" == Darwin ]] || { echo "This is for macOS."; exit 1; }
if xcode-select -p >/dev/null 2>&1 && command -v swiftc >/dev/null; then ok "Swift compiler"
else echo "  Install Apple's command line tools first: xcode-select --install"; exit 1; fi
if command -v adb >/dev/null || [[ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then ok "adb (Android Studio)"
else warn "adb not found: install Android Studio to upload code"; fi
UV="$(command -v uv || true)"
if [[ -z "$UV" ]] && command -v brew >/dev/null && ask "Install uv (needed for the AI tools)?"; then
  brew install uv >/dev/null && UV="$(command -v uv)"
fi
[[ -n "$UV" ]] && ok "uv" || warn "uv not installed: the AI tools (MCP) will be skipped"

echo "Menu bar app"
"$HERE/mac/build.sh" >/dev/null && ok "FTC Bridge built and installed in /Applications"

echo "Terminal command"
mkdir -p "$HOME/.local/bin"
ln -sf "$HERE/ftc-bridge" "$HOME/.local/bin/ftc-bridge" && ok "ftc-bridge -> ~/.local/bin"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) warn "~/.local/bin isn't on your PATH. Add this line to ~/.zshrc: export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

if [[ -n "$UV" ]]; then
  echo "AI apps (MCP)"
  if command -v claude >/dev/null; then
    if claude mcp get ftc-bridge >/dev/null 2>&1; then skip "Claude Code: already added"
    elif ask "Add to Claude Code?"; then claude mcp add --scope user ftc-bridge -- "$UV" run "$SERVER" >/dev/null && ok "Claude Code"; fi
  fi
  if command -v codex >/dev/null; then
    if codex mcp get ftc-bridge >/dev/null 2>&1; then skip "Codex: already added"
    elif ask "Add to Codex?"; then codex mcp add ftc-bridge -- "$UV" run "$SERVER" >/dev/null && ok "Codex"; fi
  fi
  if command -v opencode >/dev/null; then
    if grep -qs '"ftc-bridge"' "$HOME/.config/opencode/opencode.json" "$HOME/.config/opencode/opencode.jsonc"; then skip "OpenCode: already added"
    elif ask "Add to OpenCode?"; then
      opencode mcp add --global ftc-bridge -- "$UV" run "$SERVER" >/dev/null && opencode reload >/dev/null 2>&1 || true
      ok "OpenCode"
    fi
  fi
  DESKTOP="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  if [[ -d "/Applications/Claude.app" || -f "$DESKTOP" ]]; then
    if [[ -f "$DESKTOP" ]] && grep -q '"ftc-bridge"' "$DESKTOP"; then skip "Claude desktop: already added"
    elif ask "Add to the Claude desktop app?"; then
      mkdir -p "$(dirname "$DESKTOP")"
      [[ -f "$DESKTOP" ]] && cp "$DESKTOP" "$DESKTOP.bak-ftcbridge"
      python3 - "$DESKTOP" "$UV" "$SERVER" <<'PY'
import json, os, sys
path, uv, server = sys.argv[1:]
config = json.load(open(path)) if os.path.exists(path) else {}
config.setdefault("mcpServers", {})["ftc-bridge"] = {"command": uv, "args": ["run", server]}
json.dump(config, open(path, "w"), indent=2)
PY
      ok "Claude desktop (restart it to load)"
    fi
  fi
fi

echo "Pi"
if [[ -f "$HOME/.ssh/ftcpi" ]] && ping -c1 -t2 10.12.194.1 >/dev/null 2>&1; then
  if "$HERE/ftc-bridge" pi-version 2>/dev/null | grep -q "up to date"; then skip "Pi: up to date"
  elif ask "Update the Pi's software?"; then "$HERE/ftc-bridge" update-pi >/dev/null && ok "Pi updated"; fi
else
  skip "Pi not plugged in (the app offers the update when it is)"
fi

echo
[[ -f "$HOME/.ssh/ftcpi" ]] || echo "Next: put an SD card in this Mac and run ./flash.sh to make the Pi's card."
open "/Applications/FTC Bridge.app"
echo "Done. FTC Bridge is in your menu bar."
