# ftc-bridge for Windows: the same commands as the Mac's ftc-bridge (run `ftc-bridge` for the list).
# Needs: Windows 10/11 (ssh and tar are built in), Android Studio (adb), and the Raspberry Pi
# USB RNDIS driver (install.ps1 checks). Written for Windows PowerShell 5.1: no newer syntax.
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$ErrorActionPreference = 'Continue'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false   # robot names and Wi-Fi names to ssh as UTF-8

$Help = @'
ftc-bridge status               which robot the Pi is on, and whether its hub answers
ftc-bridge robots               saved robots (name, Wi-Fi name)
ftc-bridge scan                 nearby Wi-Fi networks
ftc-bridge add NAME WIFI_NAME   save a robot; the password is read from stdin (asked if typing)
ftc-bridge use NAME             switch the Pi to that robot
ftc-bridge forget NAME          delete a saved robot
ftc-bridge disconnect           take the Pi off the robot's Wi-Fi (before a match: rule R704.C)
ftc-bridge reboot | shutdown    restart or shut down the Pi (shut down before unplugging)
ftc-bridge health               Wi-Fi signal and channel, robot app, adb, and whether it's the same hub as before
ftc-bridge speedtest            real upload speed to the robot
ftc-bridge key                  this computer's public key (give it to whoever set up the Pi)
ftc-bridge add-key "KEY"        let another computer use the Pi
ftc-bridge pi-log [N]           how the Pi's previous run ended (a freeze ends without a shutdown)
ftc-bridge pi-version           the Pi's software version, and the one on this computer
ftc-bridge update-pi            update the Pi's software from this computer

Run these from the robot project folder:
ftc-bridge upload [NAME]        send code to the robot (Sloth hot reload if the project has it)
ftc-bridge upload --full [NAME] full install + app restart; backs up the robot first
ftc-bridge test                 run the TeamCode unit tests (no robot needed)

ftc-bridge logs [--errors] [--since-mark] [N]   the robot's recent log
ftc-bridge search PATTERN [N]   search the robot's log
ftc-bridge crashes [N]          crashes and exceptions in the recent log
ftc-bridge mark TEXT            put a marker in the recorded log
ftc-bridge record               keep recording the robot's log on this computer
ftc-bridge data                 runs recorded on the robot by BridgeLog (robot\BridgeLog.java)
ftc-bridge data pull [latest|all|NAME]   copy runs to this computer (only new ones)
ftc-bridge data summary [latest|FILE]    each column's min / max / mean, and the run's length
ftc-bridge backup | backups     save the robot's configs and app / list backups
ftc-bridge restore ROBOT/TIME [--force]   put a backup back on the robot
ftc-bridge panels [--stop]      open the robot's Panels dashboard (http://localhost:8001)
ftc-bridge adb ARGS...          any adb command, sent to the robot through the Pi

Example for an agent:  'the-password' | ftc-bridge add comp 12345-RC
'@

# ---- settings -------------------------------------------------------------
$OnWindows = ($env:OS -eq 'Windows_NT')
$Pi = 'ftc@10.12.194.1'
$AdbSerial = '10.12.194.1:5555'
$App = 'com.qualcomm.ftcrobotcontroller'
$RcActivity = "$App/org.firstinspires.ftc.robotcontroller.internal.PermissionValidatorWrapper"
$PanelsPorts = 8001, 8002, 5800, 5801, 5805, 5807   # Panels page + live data; Limelight via Panels
$CrashPattern = 'User code threw an uncaught exception|User OpMode was stuck in|FATAL EXCEPTION'
$Key = Join-Path (Join-Path $HOME '.ssh') 'ftcpi'
$SshOpts = @('-i', $Key, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3', '-o', 'LogLevel=ERROR',
             '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null')
if ($OnWindows) { $SshOpts[-1] = 'NUL' }
$PiFiles = Join-Path (Split-Path -Parent $PSScriptRoot) 'pi'
if ($env:FTC_BRIDGE_DATA) { $Data = $env:FTC_BRIDGE_DATA }
elseif ($OnWindows) { $Data = Join-Path $env:LOCALAPPDATA 'ftc-pi-bridge' }
else { $Data = Join-Path $HOME '.ftc-pi-bridge' }
$LogDir = Join-Path $Data 'logs'
$RobotLog = Join-Path $LogDir 'robot.log'
$RecorderPid = Join-Path $LogDir 'recorder.pid'
$Backups = Join-Path $Data 'backups'
$RunData = Join-Path $Data 'data'                  # runs pulled from the robot
$RobotData = '/sdcard/FIRST/bridge-data'           # where BridgeLog.java writes them

$Adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $Adb -and $OnWindows) { $Adb = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe' }

function Die([string]$msg) { [Console]::Error.WriteLine("error: $msg"); exit 1 }
function CheckName([string]$n) {
    if ($n -notmatch '^[A-Za-z0-9._-]{1,32}$') { Die "robot names can use letters, numbers, . _ - (up to 32)" }
}

# Runs ftc-hub on the Pi; returns its output lines. $input is sent to its stdin.
function PiRun([string[]]$hubArgs, [string]$stdin = $null) {
    $all = $SshOpts + @($Pi, 'sudo', '/usr/local/bin/ftc-hub') + $hubArgs
    if ($null -ne $stdin) { $out = $stdin | & ssh @all 2>&1 } else { $out = & ssh @all 2>&1 }
    $script:PiExit = $LASTEXITCODE
    if ($PiExit -eq 255) { Die "can't reach the Pi. Is it plugged into this computer?" }
    return @($out | ForEach-Object { "$_" })
}
function Field($lines, [string]$name) {
    foreach ($l in $lines) { if ($l.StartsWith("$name=")) { return $l.Substring($name.Length + 1) } }
    return ''
}

# Returns one object (PowerShell returns everything a function writes, so no Write-Output here).
function GetStatus {
    $s = PiRun @('status')
    $robot = Field $s 'robot'; $ssid = Field $s 'ssid'; $hub = Field $s 'hub'
    if (-not $robot) { return @{ Ok = $false; Msg = 'Pi plugged in, no robot chosen (ftc-bridge use NAME)' } }
    if ($hub -eq 'up') { return @{ Ok = $true; Msg = "Connected to $robot ($ssid), hub reachable" } }
    return @{ Ok = $false; Msg = "Set to $robot ($ssid), but the hub isn't answering. Is the robot on?" }
}

function AdbState { (& $Adb -s $AdbSerial get-state 2>$null | Out-String).Trim() }

# Fresh adb connection to whichever robot the Pi is on (for anything that changes the robot).
function ConnectAdb {
    if (-not $Adb -or -not (Test-Path $Adb)) { Die "adb not found. Install Android Studio (it includes adb)." }
    $st = GetStatus
    [Console]::Error.WriteLine($st.Msg)
    & $Adb disconnect $AdbSerial *> $null
    $c = & $Adb connect $AdbSerial 2>&1 | Out-String
    if ($c -notmatch 'connected to') { Die "adb couldn't connect through the Pi" }
    $env:ANDROID_SERIAL = $AdbSerial   # Gradle and plain adb now only target the robot
}
# For commands that only read: reuse a live adb connection.
function QuickAdb {
    if ((AdbState) -eq 'device') { $env:ANDROID_SERIAL = $AdbSerial } else { ConnectAdb }
}

function Recording {
    if (-not (Test-Path $RecorderPid)) { return $false }
    $p = Get-Process -Id ([int](Get-Content $RecorderPid -Raw).Trim()) -ErrorAction SilentlyContinue
    return [bool]$p
}
function RecentLog([int]$n) {
    if ((Recording) -and (Test-Path $RobotLog)) { return @(Get-Content $RobotLog -Tail $n) }
    QuickAdb
    return @(& $Adb logcat -d -v threadtime -t $n 2>$null | ForEach-Object { "$_".TrimEnd("`r") })
}
function MarkLog([string]$text) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Add-Content -Path $RobotLog -Value ("=== ftc-bridge: {0} ({1}) ===" -f $text, (Get-Date -Format 'MM-dd HH:mm:ss'))
}

function Gradle([string[]]$tasks) {
    $wrapper = if ($OnWindows) { '.\gradlew.bat' } else { './gradlew' }
    if (-not (Test-Path $wrapper)) { Die "run this from your robot project folder (the one with gradlew)" }
    if (-not $env:JAVA_HOME -and $OnWindows) {
        $jbr = Join-Path $env:ProgramFiles 'Android\Android Studio\jbr'
        if (Test-Path $jbr) { $env:JAVA_HOME = $jbr }   # Android Studio ships a JDK
    }
    & $wrapper @tasks
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
function HasSloth {
    $files = Get-ChildItem -Path 'TeamCode\build.gradle*', 'build.gradle*', 'build.dependencies.gradle' -ErrorAction SilentlyContinue
    return [bool]($files | Select-String -Pattern 'sloth' -Quiet)
}
function HubSerial { (& $Adb shell getprop ro.serialno 2>$null | Out-String).Trim() }

function BackupRobot {
    $robot = Field (PiRun @('status')) 'robot'; if (-not $robot) { $robot = 'unknown' }
    $dir = Join-Path (Join-Path $Backups $robot) (Get-Date -Format 'yyyy-MM-dd_HHmmss')
    $cfg = Join-Path $dir 'configs'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null
    $list = & $Adb shell 'ls /sdcard/FIRST/*.xml 2>/dev/null' 2>$null
    foreach ($f in $list) { $f = "$f".Trim(); if ($f) { & $Adb pull $f $cfg *> $null } }
    $apk = (& $Adb shell pm path $App 2>$null | Out-String).Trim() -replace '^package:', ''
    if ($apk) { & $Adb pull $apk (Join-Path $dir 'robot-app.apk') *> $null }
    "robot=$robot", "hub_serial=$(HubSerial)", "time=$(Get-Date)" | Set-Content (Join-Path $dir 'info.txt')
    $n = @(Get-ChildItem $cfg).Count
    $app = if (Test-Path (Join-Path $dir 'robot-app.apk')) { ' and the app' } else { '' }
    Write-Output "Backed up ${robot}: $n config(s)$app -> $robot/$(Split-Path -Leaf $dir)"
    Get-ChildItem (Join-Path $Backups $robot) -Directory | Sort-Object Name -Descending |
        Select-Object -Skip 5 | Remove-Item -Recurse -Force   # keep the newest 5
}

# The Pi software's version: a fingerprint of the files in pi\ (same as on the Mac).
function LatestPiVersion {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = New-Object System.Collections.Generic.List[byte]
    Get-ChildItem $PiFiles -File | Sort-Object Name | ForEach-Object { $bytes.AddRange([IO.File]::ReadAllBytes($_.FullName)) }
    $hash = $sha.ComputeHash($bytes.ToArray())
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
}
function InstalledPiVersion {
    $all = $SshOpts + @($Pi, 'cat /etc/ftc-pi-bridge/version 2>/dev/null || echo none')
    $v = & ssh @all 2>$null
    if ($LASTEXITCODE -eq 255) { Die "can't reach the Pi. Is it plugged into this computer?" }
    return "$v".Trim()
}

# ---- commands ---------------------------------------------------------------
$cmd = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
$arg1 = if ($Rest.Count -gt 1) { $Rest[1] } else { '' }
$arg2 = if ($Rest.Count -gt 2) { $Rest[2] } else { '' }

switch ($cmd) {
    'status' { $st = GetStatus; Write-Output $st.Msg; if (-not $st.Ok) { exit 1 } }
    'robots' { PiRun @('list') }
    'scan' { PiRun @('scan') }
    'add' {
        CheckName $arg1; if (-not $arg2) { Die "usage: ftc-bridge add NAME WIFI_NAME" }
        if ([Console]::IsInputRedirected) { $psk = [Console]::In.ReadLine() }
        else {
            $sec = Read-Host -AsSecureString "Wi-Fi password for $arg2"
            $psk = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        }
        PiRun @('add', $arg1) "$arg2`n$psk"
        if ($PiExit -ne 0) { exit 1 }
    }
    'use' {
        CheckName $arg1; PiRun @('use', $arg1); $e = $PiExit
        if ($Adb) { & $Adb disconnect $AdbSerial *> $null }   # don't keep talking to the last robot
        if ($e -ne 0) { exit 1 }
    }
    'forget' { CheckName $arg1; PiRun @('forget', $arg1); if ($PiExit -ne 0) { exit 1 } }
    'disconnect' { PiRun @('disconnect') }
    'reboot' { PiRun @('power', 'reboot') }
    'shutdown' { PiRun @('power', 'off') }
    'health' {
        $h = PiRun @('health'); $ok = $true
        $robot = Field $h 'robot'
        if (-not $robot) { Write-Output 'No robot chosen (ftc-bridge use NAME)'; exit 1 }
        Write-Output "Robot:     $robot"
        if (Field $h 'signal') { Write-Output ("Wi-Fi:     signal {0}/100, {1} (channel {2}), {3}" -f (Field $h 'signal'), (Field $h 'freq'), (Field $h 'channel'), (Field $h 'rate')) }
        else { Write-Output "Wi-Fi:     not connected to the robot's Wi-Fi. Is the robot on?"; $ok = $false }
        if ((Field $h 'rc_app') -eq 'up') { Write-Output ("Robot app: running (SDK {0}, config `"{1}`", hub Wi-Fi {2})" -f (Field $h 'sdkVersion'), (Field $h 'activeConfigName'), (Field $h 'hubChannel')) }
        else { Write-Output "Robot app: not answering (is the Robot Controller app running?)"; $ok = $false }
        $serial = Field $h 'serialNumber'
        switch (Field $h 'same_hub') {
            'yes' { Write-Output "Hub:       $serial, the same hub as before" }
            'first_time' { Write-Output "Hub:       $serial, saved as $robot's hub" }
            'no' { Write-Output ("Hub:       $serial, a DIFFERENT hub than $robot had before ({0}). Check you're on the right robot." -f (Field $h 'saved_serial')); $ok = $false }
        }
        if ((Field $h 'adb_port') -eq 'open') {
            & $Adb disconnect $AdbSerial *> $null
            if ((& $Adb connect $AdbSerial 2>&1 | Out-String) -match 'connected to') {
                $as = (& $Adb -s $AdbSerial shell getprop ro.serialno 2>$null | Out-String).Trim()
                if ($serial -and $as -ne $serial) { Write-Output "adb:       connected, but to hub $as, not $serial"; $ok = $false }
                else { Write-Output "adb:       connected to hub $as" }
            } else { Write-Output "adb:       the robot's adb port is open but adb couldn't connect"; $ok = $false }
        } else { Write-Output "adb:       not reachable (robot off, or its adb is off)"; $ok = $false }
        if (-not $ok) { exit 1 }
    }
    'speedtest' {
        QuickAdb
        $f = [IO.Path]::GetTempFileName()
        $buf = New-Object byte[] 8000000; (New-Object Random).NextBytes($buf); [IO.File]::WriteAllBytes($f, $buf)  # random: can't be compressed
        $out = & $Adb push $f /data/local/tmp/ftc-bridge-speedtest 2>&1 | Out-String
        Remove-Item $f; & $Adb shell rm -f /data/local/tmp/ftc-bridge-speedtest *> $null
        if ($out -match '([0-9.]+ MB/s \([0-9]+ bytes in [0-9.]+s\))') { Write-Output "Upload speed: $($Matches[1])" }
        else { Die "speed test failed: $out" }
    }
    'key' {
        if (-not (Test-Path $Key)) {
            New-Item -ItemType Directory -Force -Path (Split-Path $Key) | Out-Null
            # An empty passphrase: Windows PowerShell 5.1 drops empty arguments, so go through cmd there.
            if ($OnWindows) { & cmd /c "ssh-keygen -q -t ed25519 -N `"`" -C ftcpi-$env:COMPUTERNAME -f `"$Key`"" }
            else { & ssh-keygen -q -t ed25519 -N '' -C 'ftcpi' -f $Key }
        }
        Get-Content "$Key.pub"
    }
    'add-key' {
        $k = ($Rest | Select-Object -Skip 1) -join ' '
        if ($k -notmatch '^ssh-(ed25519|rsa) [A-Za-z0-9+/=]+( [A-Za-z0-9._@-]+)?$') {
            Die "that doesn't look like a public key (it starts with ssh-ed25519). Get it with: ftc-bridge key"
        }
        # The script goes over stdin: Windows PowerShell 5.1 mangles double quotes in ssh arguments.
        # (The key is safe to embed: the check above allows only letters, digits and + / = . _ @ -.)
        $script = "k='$k'; if grep -qxF ""`$k"" ~/.ssh/authorized_keys 2>/dev/null; then echo 'That computer already has access.'; " +
                  "else printf '%s\n' ""`$k"" >> ~/.ssh/authorized_keys; echo 'Added. That computer can use the Pi now.'; fi"
        $all = $SshOpts + @($Pi, "tr -d '\r' | bash -s")
        $script | & ssh @all
        if ($LASTEXITCODE -eq 255) { Die "can't reach the Pi. Is it plugged into this computer?" }
    }
    'pi-log' {
        $n = if ($arg1) { [int]$arg1 } else { 40 }
        # No double quotes in the remote command (Windows PowerShell 5.1 mangles them).
        $remote = "sudo journalctl -b -1 --no-pager -n $n -o short 2>/dev/null | grep . || echo 'No earlier run saved yet.'; " +
                  "sudo journalctl -b -1 --no-pager -n 3 2>/dev/null | grep -q 'Journal stopped' && echo '(That run ended with a normal shutdown or restart.)' || echo '(That run ended suddenly: a freeze, a power cut, or the cable was pulled.)'"
        $all = $SshOpts + @($Pi, $remote)
        & ssh @all
        if ($LASTEXITCODE -eq 255) { Die "can't reach the Pi. Is it plugged into this computer?" }
    }
    'pi-version' {
        $installed = InstalledPiVersion; $latest = LatestPiVersion
        Write-Output "installed=$installed"; Write-Output "latest=$latest"
        if ($installed -eq $latest) { Write-Output 'The Pi is up to date.' } else { Write-Output 'Update with: ftc-bridge update-pi' }
    }
    'update-pi' {
        if (-not (Test-Path (Join-Path $PiFiles 'install.sh'))) { Die "can't find the Pi's files ($PiFiles)" }
        $latest = LatestPiVersion
        $tgz = Join-Path ([IO.Path]::GetTempPath()) 'ftc-pi-update.tgz'
        & tar -czf $tgz -C $PiFiles .
        & scp -q @($SshOpts) $tgz "${Pi}:/tmp/ftc-pi-update.tgz"
        if ($LASTEXITCODE -ne 0) { Remove-Item $tgz -ErrorAction SilentlyContinue; Die "updating the Pi failed (is it plugged in?)" }
        Remove-Item $tgz
        # Also set the Pi's clock: it has no internet to set it.
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $remote = "sudo date -u -s @$now >/dev/null; rm -rf /tmp/ftc-pi-update && mkdir /tmp/ftc-pi-update && " +
                  "tar -xzf /tmp/ftc-pi-update.tgz -m --warning=no-unknown-keyword -C /tmp/ftc-pi-update && " +
                  "sudo bash /tmp/ftc-pi-update/install.sh $latest; rc=`$?; rm -rf /tmp/ftc-pi-update /tmp/ftc-pi-update.tgz; exit `$rc"
        $all = $SshOpts + @($Pi, $remote)
        & ssh @all
        if ($LASTEXITCODE -ne 0) { Die "updating the Pi failed" }
    }
    'upload' {
        $full = $false; $name = $arg1
        if ($arg1 -eq '--full') { $full = $true; $name = $arg2 }
        if ($name) { CheckName $name; PiRun @('use', $name); if ($PiExit -ne 0) { exit 1 } }
        ConnectAdb
        $robot = Field (PiRun @('status')) 'robot'
        if (-not $full -and (HasSloth)) {
            MarkLog "upload to $robot (Sloth)"
            Gradle @(':TeamCode:deploySloth')   # Sloth hot-reloads teamcode; applies when the OpMode stops
            Write-Output 'Uploaded with Sloth. Changes load when the current OpMode stops.'
        } else {
            BackupRobot
            MarkLog "upload to $robot (full install)"
            # Sloth's hot-loaded code survives installs and would override the new app, so clear it first.
            if (HasSloth) { Gradle @(':TeamCode:removeSlothRemote', ':TeamCode:installDebug') } else { Gradle @(':TeamCode:installDebug') }
            & $Adb shell am start -n $RcActivity *> $null
            Write-Output 'Full install done. Robot Controller app restarted.'
        }
    }
    'test' { Gradle @(':TeamCode:testDebugUnitTest') }
    'logs' {
        $errors = $false; $since = $false; $n = 300
        foreach ($a in ($Rest | Select-Object -Skip 1)) {
            if ($a -eq '--errors') { $errors = $true } elseif ($a -eq '--since-mark') { $since = $true } else { $n = [int]$a }
        }
        if ($since) {
            if (-not (Test-Path $RobotLog)) { Die "no recorded log yet (run: ftc-bridge record)" }
            $lines = @(Get-Content $RobotLog); $start = 0
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith('=== ftc-bridge: ')) { $start = $i } }
            $out = $lines[$start..($lines.Count - 1)]
        } else { $out = RecentLog $n }
        # threadtime lines: "MM-DD hh:mm:ss.mmm  PID  TID L Tag: message"; keep E(rror), F(atal) and markers.
        if ($errors) { $out = $out | Where-Object { $_ -match '^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ [EF] |^=== ftc-bridge' } }
        $out | Select-Object -Last $n
    }
    'search' {
        if (-not $arg1) { Die "usage: ftc-bridge search PATTERN [LINES]" }
        $n = if ($arg2) { [int]$arg2 } else { 20000 }
        $m = RecentLog $n | Select-String -Pattern $arg1 -Context 2, 2
        if ($m) { ($m | ForEach-Object { $_.Context.PreContext; $_.Line; $_.Context.PostContext }) | Select-Object -Last 200 }
        else { Write-Output "No lines match `"$arg1`"." }
    }
    'crashes' {
        $n = if ($arg1) { [int]$arg1 } else { 3000 }
        $lines = RecentLog $n; $left = 0; $found = $false
        foreach ($l in $lines) {
            if ($l -match $CrashPattern) { $left = 14; $found = $true; Write-Output '----' }
            if ($left -gt 0) { Write-Output $l; $left-- }
        }
        if (-not $found) { Write-Output 'No crashes in the recent log.' }
    }
    'mark' {
        $text = ($Rest | Select-Object -Skip 1) -join ' '
        if (-not $text) { Die "usage: ftc-bridge mark TEXT" }
        MarkLog $text; Write-Output "Marked: $text"
    }
    'record' {
        New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
        if (Recording) { Write-Output "Already recording (pid $((Get-Content $RecorderPid -Raw).Trim()))."; exit 0 }
        Set-Content -Path $RecorderPid -Value $PID
        [Console]::Error.WriteLine("Recording the robot's log to $RobotLog (Ctrl-C to stop).")
        try {
            while ($true) {
                & $Adb connect $AdbSerial *> $null
                if ((AdbState) -eq 'device') {
                    # Resume from the last recorded line's time, so a reconnect doesn't lose or repeat much.
                    $since = ''
                    if (Test-Path $RobotLog) { $last = Get-Content $RobotLog -Tail 1; if ($last -and $last.Length -ge 18) { $since = $last.Substring(0, 18) } }
                    if ($since -match '^\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}$') { $from = "-T `"$since`"" } else { $from = '-T 2000' }
                    $p = New-Object System.Diagnostics.Process
                    $p.StartInfo.FileName = $Adb
                    $p.StartInfo.Arguments = "-s $AdbSerial logcat -v threadtime $from"
                    $p.StartInfo.UseShellExecute = $false
                    $p.StartInfo.RedirectStandardOutput = $true
                    [void]$p.Start()
                    $w = New-Object IO.StreamWriter($RobotLog, $true)
                    try {
                        $count = 0
                        while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
                            $w.WriteLine($line.TrimEnd("`r")); $w.Flush(); $count++
                            if ($count % 1000 -eq 0 -and (Get-Item $RobotLog).Length -gt 20000000) {   # rotate at 20 MB
                                $w.Close(); Move-Item -Force $RobotLog "$RobotLog.1"; $w = New-Object IO.StreamWriter($RobotLog, $true)
                            }
                        }
                    } finally { $w.Close(); if (-not $p.HasExited) { $p.Kill() } }
                }
                Start-Sleep -Seconds 3
            }
        } finally { Remove-Item $RecorderPid -ErrorAction SilentlyContinue }
    }
    'data' {
        $sub = if ($arg1) { $arg1 } else { 'list' }
        # Runs on the robot as size + name, newest first (toybox ls -l: perms links owner group size date time name).
        function RobotRuns {
            QuickAdb
            $out = @()
            foreach ($l in (& $Adb shell "ls -l $RobotData 2>/dev/null" 2>$null)) {
                $p = ("$l".Trim()) -split '\s+'
                if ($p.Count -ge 8 -and $p[-1] -like '*.csv') { $out += New-Object PSObject -Property @{ Size = [long]$p[4]; Name = $p[-1] } }
            }
            return @($out | Sort-Object Name -Descending)
        }
        switch ($sub) {
            'list' {
                $runs = RobotRuns
                if ($runs.Count -eq 0) { Write-Output 'No runs on the robot yet. Add robot\BridgeLog.java to TeamCode and run an OpMode.' }
                else { $runs | ForEach-Object { '{0}  ({1:N0} KB)' -f $_.Name, ($_.Size / 1024) } }
            }
            'pull' {
                $runs = RobotRuns
                if ($runs.Count -eq 0) { Die 'no runs on the robot yet (add robot\BridgeLog.java to TeamCode and run an OpMode)' }
                $robot = Field (PiRun @('status')) 'robot'; if (-not $robot) { $robot = 'unknown' }
                $dest = Join-Path $RunData $robot; New-Item -ItemType Directory -Force -Path $dest | Out-Null
                $which = if ($arg2) { $arg2 } else { 'latest' }
                if ($which -eq 'latest') { $wanted = @($runs[0]) }
                elseif ($which -eq 'all') { $wanted = $runs }
                else { $wanted = @($runs | Where-Object { $_.Name -eq $which -or $_.Name -eq "$which.csv" }); if ($wanted.Count -eq 0) { Die "no run called $which (ftc-bridge data lists them)" } }
                foreach ($r in $wanted) {
                    $local = Join-Path $dest $r.Name
                    # Already here with the same size: skip (a finished run never changes).
                    if (-not ((Test-Path $local) -and (Get-Item $local).Length -eq $r.Size)) {
                        & $Adb pull "$RobotData/$($r.Name)" $local *> $null
                        if ($LASTEXITCODE -ne 0) { Die "couldn't copy $($r.Name)" }
                    }
                    Write-Output $local
                }
            }
            'summary' {
                $f = if ($arg2) { $arg2 } else { 'latest' }
                if ($f -eq 'latest') {
                    $f = (Get-ChildItem $RunData -Recurse -Filter *.csv -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
                    if (-not $f) { Die 'nothing pulled yet: ftc-bridge data pull' }
                }
                if (-not (Test-Path $f)) { Die "no file $f" }
                Write-Output $f
                $reader = New-Object IO.StreamReader($f)
                $names = $reader.ReadLine().Split(',')
                $min = @{}; $max = @{}; $sum = @{}; $n = @{}; $rows = 0; $lastT = 0.0
                $inv = [Globalization.CultureInfo]::InvariantCulture
                while ($null -ne ($line = $reader.ReadLine())) {
                    $v = $line.Split(','); $rows++
                    for ($i = 0; $i -lt $names.Count -and $i -lt $v.Count; $i++) {
                        $x = 0.0
                        if ([double]::TryParse($v[$i], [Globalization.NumberStyles]::Float, $inv, [ref]$x)) {
                            if (-not $n.ContainsKey($i)) { $min[$i] = $x; $max[$i] = $x; $sum[$i] = 0.0; $n[$i] = 0 }
                            if ($x -lt $min[$i]) { $min[$i] = $x }; if ($x -gt $max[$i]) { $max[$i] = $x }
                            $sum[$i] += $x; $n[$i]++
                            if ($i -eq 0) { $lastT = $x }
                        }
                    }
                }
                $reader.Close()
                Write-Output ("{0} rows, {1:F1} s" -f $rows, $lastT)
                Write-Output ('{0,-28} {1,12} {2,12} {3,12}' -f 'column', 'min', 'max', 'mean')
                for ($i = 0; $i -lt $names.Count; $i++) {
                    if ($n.ContainsKey($i)) { Write-Output ([string]::Format($inv, '{0,-28} {1,12:F3} {2,12:F3} {3,12:F3}', $names[$i], $min[$i], $max[$i], $sum[$i] / $n[$i])) }
                }
            }
            default { Die 'usage: ftc-bridge data [list | pull [latest|all|NAME] | summary [latest|FILE]]' }
        }
    }
    'backup' { ConnectAdb; BackupRobot }
    'backups' {
        if (-not (Test-Path $Backups)) { Write-Output 'No backups yet.'; exit 0 }
        Get-ChildItem $Backups -Directory | ForEach-Object {
            $robot = $_.Name
            Get-ChildItem $_.FullName -Directory | ForEach-Object {
                $n = @(Get-ChildItem (Join-Path $_.FullName 'configs') -ErrorAction SilentlyContinue).Count
                $app = if (Test-Path (Join-Path $_.FullName 'robot-app.apk')) { ', app' } else { '' }
                "$robot/$($_.Name)  ($n configs$app)"
            }
        } | Sort-Object -Descending
    }
    'restore' {
        if (-not $arg1) { Die "usage: ftc-bridge restore ROBOT/TIME [--force]   (ftc-bridge backups lists them)" }
        $dir = Join-Path $Backups ($arg1 -replace '/', '\')
        if (-not $OnWindows) { $dir = Join-Path $Backups $arg1 }
        if (-not (Test-Path (Join-Path $dir 'info.txt'))) { Die "no backup called $arg1 (ftc-bridge backups lists them)" }
        $force = ($arg2 -eq '--force')
        ConnectAdb
        $want = Field (Get-Content (Join-Path $dir 'info.txt')) 'hub_serial'; $have = HubSerial
        if ($want -and $want -ne $have -and -not $force) { Die "that backup is from a different hub ($want; this one is $have). Add --force to restore it anyway." }
        $apk = Join-Path $dir 'robot-app.apk'
        if (Test-Path $apk) {
            $out = & $Adb install -r -d $apk 2>&1 | Out-String
            if ($out -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
                if (-not $force) { Die "the robot's app was built on another computer, so it has to be removed first. Add --force to do that (configs stay)." }
                & $Adb uninstall $App *> $null
                $out = & $Adb install $apk 2>&1 | Out-String
            }
            if ($out -notmatch 'Success') { Die "install failed: $out" }
        }
        Get-ChildItem (Join-Path $dir 'configs') -Filter *.xml -ErrorAction SilentlyContinue | ForEach-Object { & $Adb push $_.FullName /sdcard/FIRST/ *> $null }
        & $Adb shell am start -n $RcActivity *> $null
        Write-Output "Restored $arg1."
    }
    'panels' {
        if ($arg1 -eq '--stop') {
            foreach ($p in $PanelsPorts) { & $Adb forward --remove "tcp:$p" *> $null }
            Write-Output 'Panels tunnels closed.'; exit 0
        }
        QuickAdb
        foreach ($p in $PanelsPorts) {
            & $Adb forward "tcp:$p" "tcp:$p" *> $null
            if ($LASTEXITCODE -ne 0) { Die "port $p is busy on this computer (close whatever uses it)" }
        }
        Write-Output 'Panels: http://localhost:8001'
        if ($arg1 -ne '--no-open') { Start-Process 'http://localhost:8001' }
    }
    'adb' { QuickAdb; $a = @($Rest | Select-Object -Skip 1); & $Adb @a; exit $LASTEXITCODE }
    default { Write-Output $Help; exit 2 }
}
