# Set up ftc-pi-bridge on a Windows PC:
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1         (asks before each step)
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1 -Yes    (no questions)
# It puts `ftc-bridge` on your PATH, adds the AI tools (MCP) to the AI apps it finds, checks the
# Raspberry Pi USB driver, and makes this PC's key for the Pi. Safe to run again.
param([switch]$Yes)
$ErrorActionPreference = 'Continue'
$Here = $PSScriptRoot
$Repo = Split-Path -Parent $Here
$Server = Join-Path $Repo 'mcp\server.py'
$Bridge = Join-Path $Here 'ftc-bridge.ps1'

function Ok([string]$m) { Write-Host "  [ok] $m" -ForegroundColor Green }
function Skip([string]$m) { Write-Host "  - $m" }
function Warn([string]$m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Ask([string]$q) {
    if ($Yes) { return $true }
    $a = Read-Host "  $q [Y/n]"
    return ($a -eq '' -or $a -match '^[Yy]')
}
function Has([string]$cmd) { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

Write-Host 'Checking this PC'
if (Has 'ssh') { Ok 'ssh (built into Windows)' }
else { Warn 'ssh is missing: Settings > System > Optional features > add "OpenSSH Client", then run this again'; exit 1 }
if (Has 'tar') { Ok 'tar (built into Windows)' } else { Warn 'tar is missing (needs Windows 10 1803 or newer)' }
$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) { $adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe' }
if (Test-Path $adb) { Ok 'adb (Android Studio)' } else { Warn 'adb not found: install Android Studio to upload code' }

# The Pi shows up on Windows as a "Raspberry Pi USB Remote NDIS Network Device", which needs
# Raspberry Pi's driver. (Only visible while the Pi is plugged in.)
$rndis = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -like '*Raspberry Pi USB Remote NDIS*' }
if ($rndis) { Ok 'Raspberry Pi USB driver' }
else {
    Warn "Raspberry Pi USB driver not seen. Plug the Pi in (middle port) to check; if Windows doesn't find it, install"
    Warn "rpi-usb-gadget-driver-setup.exe from https://github.com/raspberrypi/rpi-usb-gadget/releases"
    if (Ask 'Open that download page now?') { Start-Process 'https://github.com/raspberrypi/rpi-usb-gadget/releases' }
}

$uv = (Get-Command uv -ErrorAction SilentlyContinue).Source
if (-not $uv -and (Has 'winget') -and (Ask 'Install uv (needed for the AI tools)?')) {
    winget install --id astral-sh.uv -e --accept-source-agreements --accept-package-agreements | Out-Null
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $uv = (Get-Command uv -ErrorAction SilentlyContinue).Source
}
if ($uv) { Ok 'uv' } else { Warn 'uv not installed: the AI tools (MCP) will be skipped' }

Write-Host 'Terminal command'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (($userPath -split ';') -contains $Here) { Skip 'ftc-bridge is already on your PATH' }
else {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $Here), 'User')
    Ok 'ftc-bridge added to your PATH (open a new terminal to use it)'
}

if ($uv) {
    Write-Host 'AI apps (MCP)'
    if (Has 'claude') {
        claude mcp get ftc-bridge *> $null
        if ($LASTEXITCODE -eq 0) { Skip 'Claude Code: already added' }
        elseif (Ask 'Add to Claude Code?') { claude mcp add --scope user ftc-bridge -- $uv run $Server | Out-Null; Ok 'Claude Code' }
    }
    if (Has 'codex') {
        codex mcp get ftc-bridge *> $null
        if ($LASTEXITCODE -eq 0) { Skip 'Codex: already added' }
        elseif (Ask 'Add to Codex?') { codex mcp add ftc-bridge -- $uv run $Server | Out-Null; Ok 'Codex' }
    }
    if (Has 'opencode') {
        $oc = Join-Path $HOME '.config\opencode\opencode.json'
        if ((Test-Path $oc) -and (Select-String -Path $oc -Pattern '"ftc-bridge"' -Quiet)) { Skip 'OpenCode: already added' }
        elseif (Ask 'Add to OpenCode?') { opencode mcp add --global ftc-bridge -- $uv run $Server | Out-Null; opencode reload *> $null; Ok 'OpenCode' }
    }
    $desktop = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
    if ((Test-Path (Split-Path $desktop)) -or (Test-Path $desktop)) {
        if ((Test-Path $desktop) -and (Select-String -Path $desktop -Pattern '"ftc-bridge"' -Quiet)) { Skip 'Claude desktop: already added' }
        elseif (Ask 'Add to the Claude desktop app?') {
            $config = if (Test-Path $desktop) { Copy-Item $desktop "$desktop.bak-ftcbridge"; Get-Content $desktop -Raw | ConvertFrom-Json } else { New-Object PSObject }
            if (-not $config.mcpServers) { $config | Add-Member -NotePropertyName mcpServers -NotePropertyValue (New-Object PSObject) -Force }
            $entry = New-Object PSObject -Property @{ command = $uv; args = @('run', $Server) }
            $config.mcpServers | Add-Member -NotePropertyName 'ftc-bridge' -NotePropertyValue $entry -Force
            $config | ConvertTo-Json -Depth 20 | Set-Content -Path $desktop -Encoding UTF8
            Ok 'Claude desktop (restart it to load)'
        }
    }
}

Write-Host "This PC's key for the Pi"
$key = & powershell -NoProfile -ExecutionPolicy Bypass -File $Bridge key
Ok 'made (or found) this PC''s key'
$probe = & powershell -NoProfile -ExecutionPolicy Bypass -File $Bridge pi-version 2>$null
if ($LASTEXITCODE -eq 0) { Ok 'the Pi already accepts this PC' }
else {
    $key | Set-Clipboard
    Write-Host ''
    Write-Host '  The Pi only lets in computers it knows. Your key is copied to the clipboard.' -ForegroundColor Cyan
    Write-Host '  Send it to whoever set up the Pi; on their computer, with the Pi plugged in, they run:' -ForegroundColor Cyan
    Write-Host "    ftc-bridge add-key `"$key`""
}

Write-Host ''
Write-Host 'Done. Open a new terminal and run: ftc-bridge status'
