# Apple Music for Windows: "An unknown error has occurred" fix

Root-cause investigation and a preventive workaround for the Apple Music for Windows (Microsoft Store) failure
where, after a successful sign-in, every page shows **"An unknown error has occurred."** with a **Try Again**
button that never helps. Only a full app Reset plus re-sign-in clears it, and it comes back every few weeks.

## Why this repo exists

The failure leaves nothing in the Windows event logs, and the usual advice (reset the app, reinstall, check the
clock) treats symptoms. This repo records what actually goes wrong, so others with the same symptom can confirm it
on their own machine and fix it without a Reset, and so the pointers can be handed to Apple.

**Short version:** the app caches Apple's "Mescal" store-request signing certificate in a small SQLite file, with
an expiration derived from CDN response headers. When the app launches with that entry several days past its
expiration, it reports the cached data as invalid (store-request error 7504) instead of refetching it, every
dependent store request then fails with error 7502, and the UI shows the generic error. The cached certificate is
byte-for-byte identical to Apple's live copy. Deleting one file with the app closed fixes it immediately, with no
re-sign-in:

```
%LOCALAPPDATA%\Publishers\nzyj5cx40ttqa\com.apple.MediaServices\data
```

## Contents

- [UnknownErrorInvestigation.md](UnknownErrorInvestigation.md): the full investigation. Environment ruled out,
  the app's own ETW logs decoded, failing vs. good request sequences, the cached state located, bisection, root-cause
  statement, what remains uncertain, and steps to check your own machine.
- [Install-AppleMusicFix.ps1](Install-AppleMusicFix.ps1): installs a user-level scheduled task that keeps the
  problem from coming back. See below.

## One-time manual fix

With Apple Music closed:

```powershell
Remove-Item "$env:LOCALAPPDATA\Publishers\nzyj5cx40ttqa\com.apple.MediaServices\data" -Force
```

Then relaunch the app. No sign-out or library loss.

## Preventive fix: install the scheduled task

The installer registers a scheduled task under your own user account (no admin rights needed) that deletes the
cache file while Apple Music is closed, at most once per 24 hours. The app fetches a fresh certificate on its next
launch, so the cached copy never gets stale enough to trigger the error.

Download or clone this repo, open PowerShell in the repo folder, and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-AppleMusicFix.ps1
```

`-ExecutionPolicy Bypass` is needed because Windows blocks unsigned scripts by default. It applies only to this one
command and does not change your system's execution policy.

What it installs:

- `%LOCALAPPDATA%\AppleMusic-fix\Reset-AppleMusicMediaServicesCache.ps1`, the script that does the deletion.
- A scheduled task named **Apple Music - MediaServices cache reset** that runs it one minute after logon and then
  every hour. The task exits immediately if Apple Music is running or the file was already deleted in the last
  24 hours.
- A `cleanup.log` next to the script with one line per deletion.

The installer also runs the reset once right away, which is a harmless no-op if Apple Music is open.

To remove the task and everything it installed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-AppleMusicFix.ps1 -Uninstall
```

## Who did the work

All of the investigation and all of the code in this repository were done by Claude Fable 5.1, Anthropic's AI
model, working on the affected machine. The findings were verified on that one machine only; read the
investigation's "What remains uncertain" section before generalizing.

## License

MIT. See [LICENSE](LICENSE).
