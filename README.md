# Apple Music for Windows: "An unknown error has occurred" fix

*Unofficial. Not affiliated with or endorsed by Apple.*

Root-cause investigation and a preventive workaround for the Apple Music for Windows (Microsoft Store) failure
where, after a successful sign-in, every page shows **"An unknown error has occurred."** with a **Try Again**
button that never helps. Only a full app Reset plus re-sign-in clears it, and it comes back every few weeks.

## Why this repo exists

The failure leaves nothing in the Windows event logs, and the usual advice (reset the app, reinstall, check the
clock) treats symptoms. This repo records what actually goes wrong, so others with the same symptom can confirm it
on their own machine and fix it without a Reset, and so the pointers can be handed to Apple.

**Short version:** at launch the app fetches Apple's "Mescal" store-request signing certificate
(`setupCert.plist`, a 3 KB file unchanged since 2016) through its own WinINet HTTP cache. When that cache holds the
gzip-compressed variant of the response, the app reads the compressed bytes back and cannot parse them. It reports
store-request error 7504 ("Invalid data received"), every dependent store request then fails with error 7502, and
the UI shows the generic error. Because the file never changes, revalidation always answers 304 Not Modified and
the bad entry stays until something deletes it. Deleting one cache file with the app closed fixes it immediately,
with no re-sign-in:

```
%LOCALAPPDATA%\Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa\AC\INetCache\<subfolder>\setupCert[1].xml
```

> **History.** The first version of this repo (2026-09-07) blamed a different file, the MediaServices `data`
> database, and its scheduled task deleted that. Two days later the error returned with that file absent, which
> disproved it. The investigation keeps the original analysis with a dated correction. If you installed the earlier
> task, re-run the installer below; it replaces the old task and script.

## Contents

- [UnknownErrorInvestigation.md](UnknownErrorInvestigation.md): the full investigation. Environment ruled out,
  the app's own ETW logs decoded, failing vs. good request sequences, the original (wrong) cached-state theory, and
  the 2026-09-09 correction with the bisection that found the real trigger, what remains uncertain, and steps to
  check your own machine.
- [Install-AppleMusicFix.ps1](Install-AppleMusicFix.ps1): installs a user-level scheduled task that keeps the
  problem from coming back. See below.

## One-time manual fix

With Apple Music closed:

```powershell
Get-ChildItem "$env:LOCALAPPDATA\Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa\AC\INetCache" -Recurse -Force -Filter "setupCert*" | Remove-Item -Force
```

Then relaunch the app. No sign-out or library loss.

## Preventive fix: install the scheduled task

The installer registers a scheduled task under your own user account (no admin rights needed) that deletes the
cache entry while Apple Music is closed, so the next launch always fetches a fresh copy and the compressed variant
never survives to the next launch.

Download or clone this repo, open PowerShell in the repo folder, and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-AppleMusicFix.ps1
```

`-ExecutionPolicy Bypass` is needed because Windows blocks unsigned scripts by default. It applies only to this one
command and does not change your system's execution policy.

What it installs:

- `%LOCALAPPDATA%\AppleMusic-fix\Reset-AppleMusicCertCache.ps1`, the script that does the deletion.
- A scheduled task named **Apple Music - certificate cache reset** with three triggers: a few seconds after a
  packaged desktop app exits (Windows logs one event for all such apps, so the script checks whether Apple Music is
  running and whether the entry exists, and quits in a fraction of a second otherwise), 30 seconds after logon, and
  every hour. It never touches anything while Apple Music is running.
- A `cleanup.log` next to the script with one line per deletion. Each line says whether the deleted entry was
  gzip-compressed or plain text, which is the evidence that the bad variant was present on your machine.

The installer also runs the reset once right away, which is a harmless no-op if Apple Music is open.

**Why the exit trigger is broad.** Windows identifies the exiting app only by its versioned package name, and the
event-log filter language that scheduled tasks use accepts an exact match on that string but has no "starts with".
An exact match would stop firing, silently, at the next Store update of Apple Music. Firing on every packaged desktop
app and letting the script decide costs about 25 short hidden runs a day on the diagnosed PC, mostly from background
components, each well under a second. The comment at the trigger definition in the installer has the tested filter
results and the exact-match alternative if you prefer that trade.

To remove the task and everything it installed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-AppleMusicFix.ps1 -Uninstall
```

## Who did the work

All of the investigation and all of the code in this repository were done by Claude Fable 5.1, Anthropic's AI
model, working on the affected machine. The findings were verified on that one machine only, and the first
conclusion (2026-09-07) turned out to be wrong and was corrected on 2026-09-09 after the error recurred. Read the
investigation's correction section and its "Still not established" list before generalizing.

## License

MIT. See [LICENSE](LICENSE).
