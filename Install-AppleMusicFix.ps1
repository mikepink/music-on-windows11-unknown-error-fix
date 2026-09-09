# Install-AppleMusicFix.ps1
# SPDX-License-Identifier: MIT
#
# Run once as your normal Windows user (no admin needed):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-AppleMusicFix.ps1
# Remove everything it installed:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-AppleMusicFix.ps1 -Uninstall
#
# What it installs
#   1. %LOCALAPPDATA%\AppleMusic-fix\Reset-AppleMusicCertCache.ps1
#      While Apple Music is NOT running, it deletes the app's cached copy of Apple's Mescal store-signing
#      certificate file from the app's own WinINet HTTP cache:
#        %LOCALAPPDATA%\Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa\AC\INetCache\<subfolder>\setupCert*.xml
#      The app fetches a fresh 3 KB copy on its next launch. Details and evidence are in the script itself
#      and in UnknownErrorInvestigation.md ("Correction (2026-09-09)").
#   2. A user-level scheduled task that runs that script a few seconds after any packaged desktop app exits
#      (deliberately not just Apple Music; see the comment at "Trigger 3" below for the trade-off),
#      30 seconds after logon, and hourly.
#
# Earlier versions of this installer (2026-09-07) deleted a different file, the MediaServices "data"
# database, under the task name "Apple Music - MediaServices cache reset". That did not prevent the error.
# This installer removes that task and script if they are present.
#
# How the task launches the script (no console flash)
#   Task Scheduler starts the action in your interactive session, and a plain "powershell.exe
#   -WindowStyle Hidden" still flashes a console window for a fraction of a second on every run.
#   To avoid that, the task runs it through "conhost.exe --headless". That switch is an implementation
#   detail of the Windows console host, not a documented interface. If a future Windows build removes
#   it, the task will fail visibly (a non-zero "Last Run Result" in Task Scheduler) rather than do
#   anything harmful. Set $UseHeadlessConhost = $false below to use the documented launcher instead and
#   accept the brief flash.

param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$UseHeadlessConhost = $true

$dir         = Join-Path $env:LOCALAPPDATA 'AppleMusic-fix'
$script      = Join-Path $dir 'Reset-AppleMusicCertCache.ps1'
$taskName    = 'Apple Music - certificate cache reset'
$oldTaskName = 'Apple Music - MediaServices cache reset'
$oldFiles    = @('Reset-AppleMusicMediaServicesCache.ps1', 'last-delete.txt', 'layout-warning.txt')

if ($Uninstall) {
    foreach ($n in @($taskName, $oldTaskName)) { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $dir) { [System.IO.Directory]::Delete($dir, $true) }
    "removed scheduled tasks '$taskName' / '$oldTaskName' and $dir"
    return
}

New-Item -ItemType Directory -Force $dir | Out-Null

# Clean up the 2026-09-07 version, if present.
if (Get-ScheduledTask -TaskName $oldTaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $oldTaskName -Confirm:$false
    "removed the earlier task '$oldTaskName'"
}
foreach ($n in $oldFiles) { $p = Join-Path $dir $n; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; "removed $p" } }

@'
# Reset-AppleMusicCertCache.ps1
#
# WHAT THIS DOES
#   While Apple Music is not running, delete the app's cached copy of Apple's "Mescal" store-signing
#   certificate file from the app's own WinINet HTTP cache:
#     %LOCALAPPDATA%\Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa\AC\INetCache\<subfolder>\setupCert*.xml
#   The app fetches a fresh copy of https://s.mzstatic.com/sap/setupCert.plist (3 KB) on its next launch.
#
# WHY (diagnosed on this PC on 2026-09-09; see UnknownErrorInvestigation.md, "Correction (2026-09-09)")
#   When that cache entry holds the gzip-compressed variant of the response, the app reads the compressed
#   bytes back and cannot parse them. AMPLibraryAgent logs
#     "Error initializing Mescal session. Invalid data received"  (store-request error 7504)
#   every store request then fails with error 7502, and the UI shows "An unknown error has occurred /
#   Try Again". The file on Apple's CDN has not changed since 2016, so revalidation always answers
#   304 Not Modified and the bad entry never goes away by itself; only a full app Reset (which wipes the
#   whole AC folder) used to clear it. Deleting this one file with the app closed fixed it immediately,
#   with no re-sign-in. The bad entry was byte-for-byte the CDN's gzip body; decompressed it is the
#   correct certificate, so nothing is corrupt or expired.
#
# WHY DELETING IT IS SAFE
#   It is a cache of a public, static 3 KB file. WinINet treats a missing cache file as a cache miss
#   and refetches. Sign-in state and the library live elsewhere and are not touched. The app already
#   contacts Apple on every launch (config bag, Mescal handshake), so this adds no new network dependency.
#   Deleting the entry even when it is the good (plain-text) variant is deliberate: it costs one 3 KB
#   fetch per launch and removes any dependence on telling the two variants apart.
#
# WHEN IT RUNS
#   The scheduled task runs this a few seconds after any packaged desktop app exits (Windows logs one
#   event, AppModel-Runtime 217, for all of them, so this script checks whether there is anything to do),
#   30 seconds after logon, and hourly. It always exits without doing anything while Apple Music is running.
#
# FILES NEXT TO THIS SCRIPT
#   cleanup.log         one line per deletion or failure, with the entry's size and whether it was
#                       gzip-compressed ("gzip"), plain text ("plain"), empty, or unknown. The "gzip"
#                       lines are the evidence that the bad variant was present on your machine.
#   layout-warning.txt  written once if the app's INetCache folder is missing (layout changed; this
#                       workaround is then doing nothing)

$ErrorActionPreference = 'SilentlyContinue'
$here  = $PSScriptRoot
$log   = Join-Path $here 'cleanup.log'
$pkg   = Join-Path $env:LOCALAPPDATA 'Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa'
$cache = Join-Path $pkg 'AC\INetCache'

function Log($m) { Add-Content -LiteralPath $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

if (-not (Test-Path -LiteralPath $pkg)) { exit 0 }   # Apple Music is not installed for this user
if (-not (Test-Path -LiteralPath $cache)) {
    $flag = Join-Path $here 'layout-warning.txt'
    if (-not (Test-Path -LiteralPath $flag)) {
        Log "WARNING: $cache does not exist. The cache location may have changed; this workaround is currently doing nothing."
        Set-Content -LiteralPath $flag -Value (Get-Date -Format 'o')
    }
    exit 0
}
if (Get-Process -Name AMPLibraryAgent, AppleMusic -ErrorAction SilentlyContinue) { exit 0 }

$entries = @(Get-ChildItem -LiteralPath $cache -Recurse -Force -File -Filter 'setupCert*' -ErrorAction SilentlyContinue)
if ($entries.Count -eq 0) { exit 0 }

foreach ($f in $entries) {
    $kind = 'unknown'
    try {
        $fs = [System.IO.File]::OpenRead($f.FullName)
        $b = New-Object byte[] 2
        $n = $fs.Read($b, 0, 2)
        $fs.Close()
        if ($n -eq 2 -and $b[0] -eq 0x1F -and $b[1] -eq 0x8B) { $kind = 'gzip' }
        elseif ($n -ge 1 -and $b[0] -eq 0x3C)                  { $kind = 'plain' }   # '<'
        elseif ($n -eq 0)                                      { $kind = 'empty' }
    } catch { }
    try { [System.IO.File]::Delete($f.FullName) } catch { }
    if (Test-Path -LiteralPath $f.FullName) {
        Log ("FAILED to delete {0} ({1}, {2} bytes); probably in use" -f $f.Name, $kind, $f.Length)
    } else {
        Log ("deleted {0} ({1}, {2} bytes)" -f $f.Name, $kind, $f.Length)
    }
}

$lines = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue)
if ($lines.Count -gt 300) { $lines | Select-Object -Last 200 | Set-Content -LiteralPath $log }
'@ | Set-Content -LiteralPath $script -Encoding UTF8
"wrote $script"

$user   = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$psExe  = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psArgs = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $script + '"'
if ($UseHeadlessConhost) {
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') -Argument ('--headless ' + $psExe + ' ' + $psArgs)
} else {
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs
}

# Trigger 1: 30 s after logon (covers a Windows shutdown while Apple Music was open).
$tLogon = New-ScheduledTaskTrigger -AtLogOn -User $user
$tLogon.Delay = 'PT30S'

# Trigger 2: hourly, indefinitely (repetition interval with no duration = repeat forever).
$tHourly = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddHours((Get-Date).Hour + 1)) -RepetitionInterval (New-TimeSpan -Hours 1)

# Trigger 3: 5 s after a packaged desktop app's container is destroyed (Microsoft-Windows-AppModel-Runtime
# event 217). This fires for EVERY packaged desktop app, not just Apple Music, and the script does the
# checking. That is deliberate:
#   - The event identifies the app only by its versioned package full name
#     (e.g. AppleInc.AppleMusicWin_1.1540.23042.0_x64__nzyj5cx40ttqa). Task Scheduler evaluates event
#     triggers with the event log's XPath subset, which (tested 2026-09-09 against the live log) accepts an
#     exact match on that string but rejects contains() and starts-with() as invalid, and matches nothing
#     for a string range or for the version-free family name.
#   - An exact match would therefore stop firing, silently, at the next Store update of Apple Music,
#     leaving only the hourly and logon triggers until someone re-ran this installer.
#   - The cost of the broad trigger is small: on the diagnosed PC about 25 firings a day, mostly from
#     background components (Store, Xbox overlay, Phone Link, Widgets, GPU software), each a hidden
#     PowerShell that checks two things and exits in well under a second with no disk writes.
# If you would rather have a precise trigger and accept re-running this installer after every Apple Music
# update, replace the XPath in the Subscription below with
#   *[System[Provider[@Name='Microsoft-Windows-AppModel-Runtime'] and EventID=217] and EventData[Data[@Name='PackageName']='<PackageFullName>']]
# where <PackageFullName> is the output of (Get-AppxPackage AppleInc.AppleMusicWin).PackageFullName.
$evtClass = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
$tExit = New-CimInstance -CimClass $evtClass -ClientOnly
$tExit.Enabled = $true
$tExit.Delay = 'PT5S'
$tExit.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-AppModel-Runtime/Admin"><Select Path="Microsoft-Windows-AppModel-Runtime/Admin">*[System[Provider[@Name=''Microsoft-Windows-AppModel-Runtime''] and EventID=217]]</Select></Query></QueryList>'

$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
$desc      = 'Workaround for Apple Music "An unknown error has occurred / Try Again" (store-request errors 7504/7502). Runs ' + $script + ' after a packaged desktop app exits, 30 s after logon, and hourly; while Apple Music is closed it deletes the app''s cached copy of setupCert.plist under %LOCALAPPDATA%\Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa\AC\INetCache (a gzip-compressed copy there makes the app fail to parse its Mescal signing certificate). Log: cleanup.log next to the script. Installed ' + (Get-Date -Format 'yyyy-MM-dd') + '. Uninstall: run Install-AppleMusicFix.ps1 -Uninstall'

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($tLogon, $tHourly, $tExit) -Principal $principal -Settings $settings -Description $desc -Force | Out-Null
"registered scheduled task '$taskName' for $user"
(Get-ScheduledTask -TaskName $taskName).Triggers | ForEach-Object { "  trigger: " + $_.CimClass.CimClassName + "  delay=" + $_.Delay + "  repeat=" + $_.Repetition.Interval }

# Run the reset once now. Harmless no-op if Apple Music is open or there is no cache entry.
& $script
"done. Log: $dir\cleanup.log"
