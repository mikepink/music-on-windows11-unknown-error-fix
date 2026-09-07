# Install-AppleMusicFix.ps1
# SPDX-License-Identifier: MIT
#
# Run once as your normal Windows user (no admin needed):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-AppleMusicFix.ps1
# Remove everything it installed:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-AppleMusicFix.ps1 -Uninstall
#
# What it installs
#   1. %LOCALAPPDATA%\AppleMusic-fix\Reset-AppleMusicMediaServicesCache.ps1
#      A rate-limited preventive reset: while Apple Music is NOT running, and at most once per 24 hours,
#      it deletes the Apple MediaServices cache database
#        %LOCALAPPDATA%\Publishers\nzyj5cx40ttqa\com.apple.MediaServices\data
#      which is where Apple Music keeps its cached "Mescal" store-signing certificate. It does not read
#      the database or check the certificate's expiration. Details and evidence are in the script itself.
#   2. A user-level scheduled task that runs that script 1 minute after logon and then hourly.
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

$dir      = Join-Path $env:LOCALAPPDATA 'AppleMusic-fix'
$script   = Join-Path $dir 'Reset-AppleMusicMediaServicesCache.ps1'
$taskName = 'Apple Music - MediaServices cache reset'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $dir) { [System.IO.Directory]::Delete($dir, $true) }
    "removed scheduled task '$taskName' and $dir"
    return
}

New-Item -ItemType Directory -Force $dir | Out-Null

@'
# Reset-AppleMusicMediaServicesCache.ps1
#
# WHAT THIS DOES
#   While Apple Music is not running, and at most once every 24 hours, delete the Apple MediaServices
#   cache database:
#     %LOCALAPPDATA%\Publishers\nzyj5cx40ttqa\com.apple.MediaServices\data
#   This is a rate-limited preventive reset of the whole file. It does NOT open the database, does NOT
#   check the cached certificate's expiration, and does NOT delete individual rows.
#
# WHY (diagnosed on this PC on 2026-09-07)
#   Apple Music for Windows caches Apple's "Mescal" store-signing certificate in that file, with an
#   expiration copied from the CDN response (Date header + 24h max-age). When the app launched with that
#   entry several days past its expiration, its AMPLibraryAgent logged
#     "Error initializing Mescal session. Invalid data received"  (store-request error 7504)
#   and never refetched; every store request then failed with error 7502 and the UI showed
#   "An unknown error has occurred / Try Again". The cached certificate bytes were identical to Apple's
#   live copy, so this is an expiry-handling bug in the app, not corruption. Deleting the file with the
#   app closed fixed it immediately, with no re-sign-in. A fresh copy is fetched at the next launch; the
#   app already contacts Apple on every launch for its config bag and for the Mescal session setup, so
#   this adds no new network dependency.
#
# WHY DELETING THE WHOLE FILE IS SAFE
#   On 2026-09-07 the file contained exactly four rows, all caches:
#     AMSBagCacheProviderCurrentPlatformVersion ("10.0"), a storefront-suffix string,
#     mescal-certificate, mescal-certificate-expiration.
#   Sign-in state lives in the sibling "accounts" database, which this script never touches. With the
#   file absent, the app started, signed-in content loaded, and it did not even recreate the file during
#   a test session.
#
# LIMITS
#   - The running-process check is best effort. If Apple Music starts in the moment between the check and
#     the delete, either Windows refuses the delete because the file is open (logged as FAILED), or the
#     app starts with no cache, which is the same state as after a normal reset. Neither case harms data.
#   - The cache file being absent is normal (the app writes it rarely). The whole MediaServices folder
#     being absent is not: it means the layout changed and this workaround is a no-op. That is logged once.
#     (It also fires once, harmlessly, if you ever run a full app Reset, which recreates that folder.)
#
# FILES NEXT TO THIS SCRIPT
#   cleanup.log        one line per deletion or failure
#   last-delete.txt    timestamp of the last deletion (the 24-hour throttle)
#   layout-warning.txt written once if the MediaServices folder is missing

$ErrorActionPreference = 'SilentlyContinue'
$here        = $PSScriptRoot
$log         = Join-Path $here 'cleanup.log'
$marker      = Join-Path $here 'last-delete.txt'
$msDir       = Join-Path $env:LOCALAPPDATA 'Publishers\nzyj5cx40ttqa\com.apple.MediaServices'
$target      = Join-Path $msDir 'data'
$minInterval = [TimeSpan]::FromHours(24)

function Log($m) { Add-Content -LiteralPath $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

if (-not (Test-Path -LiteralPath $msDir)) {
    $flag = Join-Path $here 'layout-warning.txt'
    if (-not (Test-Path -LiteralPath $flag)) {
        Log "WARNING: $msDir does not exist. The cache location may have changed; this workaround is currently doing nothing."
        Set-Content -LiteralPath $flag -Value (Get-Date -Format 'o')
    }
    exit 0
}
if (Get-Process -Name AMPLibraryAgent, AppleMusic -ErrorAction SilentlyContinue) { exit 0 }
if (-not (Test-Path -LiteralPath $target)) { exit 0 }
if (Test-Path -LiteralPath $marker) {
    $sinceLast = [DateTime]::UtcNow - [System.IO.File]::GetLastWriteTimeUtc($marker)
    if ($sinceLast -lt $minInterval) { exit 0 }
}

$removed = @(); $failed = @()
foreach ($f in @($target, "$target-journal", "$target-wal", "$target-shm")) {
    if (Test-Path -LiteralPath $f) {
        try { [System.IO.File]::Delete($f) } catch { }
        if (Test-Path -LiteralPath $f) { $failed += (Split-Path $f -Leaf) } else { $removed += (Split-Path $f -Leaf) }
    }
}
if ($removed -contains 'data') { [System.IO.File]::WriteAllText($marker, [DateTime]::UtcNow.ToString('o')) }
if ($removed.Count -gt 0) { Log ("deleted MediaServices cache: " + ($removed -join ', ')) }
if ($failed.Count  -gt 0) { Log ("FAILED to delete (probably in use): " + ($failed -join ', ')) }

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

$tLogon  = New-ScheduledTaskTrigger -AtLogOn -User $user
$tLogon.Delay = 'PT1M'
# Repetition interval with no duration = repeat indefinitely.
$tHourly = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddHours((Get-Date).Hour + 1)) -RepetitionInterval (New-TimeSpan -Hours 1)

$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew
$desc      = 'Workaround for Apple Music "An unknown error has occurred / Try Again" (store-request errors 7504/7502). Runs ' + $script + ' 1 min after logon and hourly; while Apple Music is closed, and at most once per 24h, it deletes the Apple MediaServices cache database %LOCALAPPDATA%\Publishers\nzyj5cx40ttqa\com.apple.MediaServices\data (holds the cached Mescal signing certificate). Log: cleanup.log next to the script. Installed ' + (Get-Date -Format 'yyyy-MM-dd') + '. Uninstall: run Install-AppleMusicFix.ps1 -Uninstall'

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($tLogon, $tHourly) -Principal $principal -Settings $settings -Description $desc -Force | Out-Null
"registered scheduled task '$taskName' for $user"
(Get-ScheduledTask -TaskName $taskName).Triggers | ForEach-Object { "  trigger: " + $_.CimClass.CimClassName + "  delay=" + $_.Delay + "  repeat=" + $_.Repetition.Interval }

# Run the reset once now. Harmless no-op if Apple Music is open or the cache file is absent.
& $script
"done. Log: $dir\cleanup.log"
