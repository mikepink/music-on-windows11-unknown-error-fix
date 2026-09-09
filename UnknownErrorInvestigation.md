# Apple Music for Windows: "An unknown error has occurred" — root-cause investigation

*Date of investigation: 2026-09-07. Single machine. Personal identifiers redacted (`<user>`, `<DSID>`, `<machineID>`).*

---

## Correction (2026-09-09): the trigger is the app's WinINet cache entry, not the `data` file

Two days after this investigation, with the preventive task from this repo installed, the error came back. The
`data` file named below as the culprit **did not exist** at the time: it had been absent since the 2026-09-07
bisection, the app never recreated it, and the scheduled task had never deleted anything. So the root cause stated in
sections 9, 11 and 13 is wrong, or at best incomplete. Everything in this section was established on the same machine
on 2026-09-09, using the same methods (flushed ETW logs, one-change-at-a-time relaunches, window captures).

**The failure was identical.** Both the UI process and the backend logged `StoreMescalSessionCert` → store-request
error 7504, `Error initializing Mescal session. Invalid data received`, then the 7502 cascade, exactly as on 9/7.

**The certificate was coming from the app's own HTTP cache.** The app's WinINet cache lives under the package folder:

```
%LOCALAPPDATA%\Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa\AC\INetCache\<random subfolder>\setupCert[1].xml
```

Timing of the `setupCert.plist` request, from URL line to "Processing base response", tells a cache hit from a fetch:

| Session | Time to response | Outcome |
|---|---|---|
| 2026-08-31 | 91 ms | network fetch, OK |
| 2026-09-02 | 10 ms | cache hit, OK |
| 2026-09-04 | 8 ms | cache hit, OK |
| 2026-09-08 (UI, then backend) | 115 ms, then 6 ms | fetch, then cache hit, OK |
| 2026-09-09 12:13 (UI, then backend) | 101 ms, then 6 ms | revalidation (cache file untouched), then cache hit, **7504** |
| 2026-09-09 control relaunch | 6 ms | cache hit, **7504** |
| 2026-09-09 with the cache entry moved aside | 82 ms, then 7 ms | fetch, then cache hit, **OK** |

**Bisection.** A control relaunch with nothing changed failed again. Moving only the `setupCert[1].xml` file aside made
the next launch fetch the certificate from the network, set up the Mescal session, and render Home with personalised
content and zero 7504/7502 errors. The app immediately wrote a new cache entry, and later launches used it fine.

**What was in the bad entry.** The file moved aside was 2171 bytes and started with the gzip magic bytes `1F 8B`. It is
byte-for-byte the CDN's compressed response body: its SHA-256 (`1926ed96e6c55b81…`) equals that of
`curl -H "Accept-Encoding: gzip" https://s.mzstatic.com/sap/setupCert.plist`. Decompressed, it is the correct plist
(SHA-256 `059b5061d8c54bc1…`, identical to the uncompressed body the CDN serves). The entry the app wrote on the
successful launch is the plain 3257-byte plist. So nothing was corrupt or expired: the app read gzip-compressed bytes
back out of its own HTTP cache and tried to parse them as the plist. That is what "Invalid data received" means here.

**Why it sticks until a Reset.** `setupCert.plist` has not changed since 2016, so every revalidation returns
`304 Not Modified` and the cached entry survives. Try Again re-reads the same entry. A full app Reset wipes the `AC`
folder along with everything else, which is why only Reset ever cleared it.

**Reinterpreting 9/7.** The `AC\INetCache` folder's own modification time is 2026-09-07 14:31:09, the same second as
the successful launch in section 10, which means a cache entry was created or removed at that moment. Moving the
`data` file coincided with that. The `data` file was never shown to be necessary or sufficient, and the "expiry margin"
reasoning in sections 9, 11 and 12 should be disregarded.

**The cache evicts the entry on its own.** Later the same day, while the app was running and nothing else touched
the folder, the fresh `setupCert[1].xml` disappeared from the cache at 12:38:39, ten minutes after the app had written
about 30 MB of video-preview files into the same cache (single files up to 18 MB). That is consistent with WinINet's
size-based scavenging of the per-app cache. So whether the entry exists at a given launch, and which of the app's HTTP
clients last (re)wrote it, depends on eviction timing. That is a plausible reason the failure is intermittent rather
than permanent, and it is why the workaround below deletes the entry at every opportunity instead of trying to
predict when it is bad.

**Still not established.**

- Which component stores the compressed variant. The bad entry carried a write time of 2026-09-08 13:11:33, an hour
  into a good session, and neither process logged a certificate request at that time. The app has more than one HTTP
  client (the native store-request layer and the JavaScript "JetEngine" UI layer), and a plausible mechanism is one
  client caching the response with `Content-Encoding: gzip` and the other not decoding on cache hits. Not proven.
- The reverse test (putting the compressed entry back and confirming the failure returns) was not run.
- Whether the `data` file plays any role at all. The workaround no longer touches it.

**Fix that matches the evidence.** With Apple Music closed, delete every `setupCert*.xml` under
`%LOCALAPPDATA%\Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa\AC\INetCache\`. The next launch fetches a fresh copy.
The installer in this repo now does exactly that after every app exit, at logon, and hourly; see the README.

---

## Summary

> **Superseded on 2026-09-09.** The conclusion below was disproved when the error returned with the `data` file
> absent. The actual trigger is a gzip-compressed copy of the certificate response in the app's WinINet cache. See the
> [Correction](#correction-2026-09-09-the-trigger-is-the-apps-wininet-cache-entry-not-the-data-file) section, which
> follows the summary. The observations in sections 1–8 and 10 stand; the interpretation in 9, 11 and 13 does not.

Apple Music for Windows (Microsoft Store app, version 1.1540.23042.0) periodically stopped working with
**"An unknown error has occurred."** and a **Try Again** button that never helped. Only a full app Reset plus
re-sign-in cleared it, and the problem returned every few weeks.

The cause is inside the app. It caches Apple's "Mescal" store-request signing certificate in a small SQLite
database, together with an expiration derived from the CDN's HTTP headers. When the app launched with that cached
entry several days past its expiration, its backend process logged
`Error initializing Mescal session. Invalid data received` (store-request error **7504**) and did not refetch the
certificate. Every store request that depends on the Mescal session then failed with error **7502**, and the UI
rendered the generic error. The cached certificate bytes were **identical** to the copy Apple serves, so this is an
expiry-handling bug, not data corruption.

Deleting one file while the app was closed fixed it immediately, with no re-sign-in:

```
%LOCALAPPDATA%\Publishers\nzyj5cx40ttqa\com.apple.MediaServices\data
```

Nothing about the machine (Windows build, clock, DNS, TLS, antivirus, GPU driver, Store version, injected DLLs)
contributed. The app never crashed; Windows holds no crash records for it.

---

## 1. Symptom and environment

| Item | Value |
|---|---|
| OS | Windows 11 Pro 25H2, build 26200.9278 |
| App | Apple Music (Store), package `AppleInc.AppleMusicWin_nzyj5cx40ttqa`, version 1.1540.23042.0, binaries 1.6.4.90 dated 2026-03-31. Confirmed current release (published April 2026). |
| Other Apple software | None (no iTunes, iCloud for Windows, or Apple Devices) |
| Security software | Microsoft Defender only; Controlled Folder Access off; no cleaner utilities |
| Hardware | Desktop, AMD CPU, NVIDIA and AMD display adapters, healthy SSDs, ample free space |
| Symptom | After a successful sign-in, Home/Browse/etc. show "An unknown error has occurred." + Try Again. Recurs every few weeks. Reset + re-sign-in is the only known cure. |

At the start of the investigation the app was open and showing the error (confirmed by capturing its window).

---

## 2. Approach

1. Rule out the environment with Windows-side evidence (event logs, services, network, security).
2. Find the app's **own** diagnostic logs and read the failing request sequence.
3. Compare a failing session with a known-good one from days earlier.
4. Verify externally (with `curl`) that the network endpoints involved behave correctly.
5. Diff the app's on-disk state between the last good session and the first bad launch.
6. Bisect: remove one candidate piece of state at a time, relaunch, and check the log and the window.
7. Confirm the fix and package a workaround.

---

## 3. Ruling out the environment

Everything below was checked and found normal. Listed so others don't repeat it.

| Area | Evidence | Result |
|---|---|---|
| App crashes | Application log, Windows Error Reporting folders, `Win32_ReliabilityRecords`: zero entries for `AppleMusic.exe` / `AMPLibraryAgent.exe` in 60 days | Not a crash; an in-app failure |
| Store / install | Package registered OK; only Store operations were user-initiated Resets (see timeline); installed version is the latest published | Not a bad install or stale build |
| Dependencies | `Microsoft.VCLibs.140.00` 14.0.33519.0 and `.UWPDesktop` 14.0.33728.0 installed, meeting the manifest's MinVersions | OK |
| Clock | W32Time running; drift vs `time.windows.com` measured at **−1.8 s** | OK |
| DNS / proxy / hosts | Router DNS; every `*.apple.com` / `mzstatic.com` host resolved to Apple/Akamai/Fastly addresses; no hosts-file entries; no WinHTTP or user proxy | OK |
| TLS interception | Live chains for `s.mzstatic.com`, `init.itunes.apple.com`, `buy.itunes.apple.com` issued by Apple Public EV Server CAs over TLS 1.3; no third-party roots in the user or machine Root stores | OK |
| Defender | Real-time on, no detections, no Apple-related events, CFA off, firewall has the app's own Allow rule | OK |
| Drivers / software | GPU drivers stable for months; no third-party DLLs loaded in either Apple process (checked with `Get-Process … .Modules`) despite ASUS/Nahimic services on the system | OK |
| Storage | Both SSDs healthy; >1.5 TB free; AppData not redirected; Music folder not on OneDrive | OK |
| Power | All shutdowns in 60 days were clean (`User32` 1074 / Kernel-General 13); no Kernel-Power 41 or EventLog 6008 | Not power-loss corruption |

Useful negative result: the Windows event logs contain **nothing** about this failure. Diagnosis had to come from the
app's own logs.

---

## 4. The app's own logs

The app writes Event Tracing for Windows (`.etl`) files under its package folder:

```
%LOCALAPPDATA%\Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa\LocalState\Logs\
    AMPLibraryAgent_<date>_<time>.etl   rotated backend logs (~285 KB each)
    Log-AMPLibraryAgent-N.etl           live backend log (flushed on clean exit)
    Log-AppleMusic-1.etl                UI process log
```

They decode with the built-in `tracerpt`:

```powershell
tracerpt "<file>.etl" -o "<file>.csv" -of CSV -y
```

In the CSV, column 6 is the level (2 = error, 4 = info), column 17 is the timestamp as a FILETIME, and the message
begins at column 19. The events are self-describing TraceLogging, so no provider manifest is needed.

Two other text logs exist under `LocalCache\Local\Logs\AuthKitWin.*.log`. They show a push-token check-in failing
on every launch (`Failed to create kccadp instance … KCCAError error 4`). That appeared in good and bad sessions alike,
so it is noise for this problem.

Important operational note: the live log is only flushed when the backend exits cleanly. Force-killing
`AMPLibraryAgent.exe` loses the buffered log. Close the app through its window and wait.

---

## 5. Timeline reconstructed from Windows and the logs

| When | Event | Source |
|---|---|---|
| 2026-07-27 13:08 | User performs app **Reset** (`ResetPackageOperation`) | AppXDeployment log |
| 2026-08-24 09:57–10:05 | Four launch attempts, then **Repair**, then **Reset**; fresh sign-in at 10:07 | TWinUI activation log, AppXDeployment log, AuthKit log |
| 2026-08-26, 08-28, 08-31 | Normal sessions | Rotated backend logs (no 7504/7502) |
| 2026-09-02 10:45–11:49 | Normal session; at 11:49:15 the app writes its MediaServices cache files, including the certificate cache | File timestamps on `data`, `HTTPCache2`, `itfes` |
| 2026-09-04 10:39 | Normal session; Mescal session set up fine despite the cached certificate having "expired" at 2026-09-03 00:01 UTC | Rotated backend log |
| 2026-09-04 11:50:32 | Windows shut down while the app was open (app container destroyed the same second) | AppModel-Runtime log, Kernel-General 13 |
| 2026-09-07 14:05:43 | Launch → fails with 7504/7502; UI shows the error | Live backend log, UI log |
| 2026-09-07 14:05:55 | Relaunch 12 s later → same failure | UI log, activation log |
| 2026-09-07 14:31 | Launch with the `data` file moved aside → works, zero errors | Bisection harness |

Between the last good session (9/4) and the first bad launch (9/7), the only files under the app's package folder
or its Publishers folder that changed were two registry-hive files written at the moment of the 9/4 shutdown
(`Settings\settings.dat`, `SystemAppData\Helium\User.dat`). The certificate cache itself was untouched since 9/2.

---

## 6. The failing request sequence

Backend log, first failing launch (identifiers trimmed):

```
Successfully parsed bag response.
Successfully set new bag with timestamp 0.000000. Is new bag? = 0. Notifying listeners.
storereq> StoreMachineAuthorize(…). Created.
Request StoreMachineAuthorize(…) needs bag.
Request StoreMachineAuthorize(…) needs Mescal session.
storereq> StoreMescalSessionCert(…). Created.
Request StoreMescalSessionCert(…) needs bag.
storereq> StoreMescalSessionCert(…). URL is 'https://s.mzstatic.com/sap/setupCert.plist'
storereq> StoreMescalSessionCert(…). Processing base response.
storereq> ***ERROR*** StoreMescalSessionCert(…). Processed base response. Found error
          The operation couldn't be completed. (com.apple.iTunes.errors.store-request error 7504.)
Error requesting Mescal setup cert. Error details: <pointer>
storereq> ***ERROR*** StoreMachineAuthorize(…). Ignored base response due to error
          The operation couldn't be completed. (com.apple.iTunes.errors.store-request error 7502.)
token request failed! (… store-request error 7502.)
**ERROR**: Handling UNEXPECTED error from server failing silently with 7502 for request. clientID:100
**ERROR**: CloudLibraryManager::NotifyCloudLibraryTurnOnIsComplete(N) - Failed with status:7502 enrollment state:Enrolled-4
```

The same 7504 → 7502 pattern repeated for `StoreGetAppleMusicAccountSubscriptionStatus`,
`StoreRegisterPushNotificationToken`, `MediaAPI`, `StoreGenericRequest`, and `StoreJetEngineFetchRequest`.
The UI log added the decisive line and the consequence:

```
Error initializing Mescal session. Invalid data received.
DispatchIntentAsync: JetEngine::ScriptError caught for intent …
```

Reading of the sequence: "Mescal" is the client-side signing of store requests (the `X-Apple-ActionSignature`
mechanism inherited from iTunes). Its setup needs a certificate (`setupCert.plist`), then a handshake with
`fpinit.itunes.apple.com/v1/signSapSetup`. Here the certificate step reports 7504 while "processing" the response,
so no session exists, and every dependent request short-circuits with 7502 ("dependency failed"). The Try Again
button re-issues the same requests, which fail the same way.

---

## 7. The same sequence in a good session (2026-09-04)

```
storereq> StoreMescalSessionCert(…). URL is 'https://s.mzstatic.com/sap/setupCert.plist'
storereq> StoreMescalSessionCert(…). Processing base response.
storereq> StoreMescalSessionCert(…). Calling completion.
storereq> StoreMescalSessionSetup(…). URL is 'https://fpinit.itunes.apple.com/v1/signSapSetup'
storereq> StoreMescalSessionSetup(…). Processing base response.
storereq> StoreMescalSessionSetup(…). Calling completion.
storereq> StoreMachineAuthorize(…). URL is 'https://p19-buy.itunes.apple.com/commerce/machine/authorize'
storereq> StoreMachineAuthorize(…). Calling completion.
```

Across nine rotated logs from 8/26 to 9/4 there were **zero** occurrences of 7504 or 7502. The bag step logged
`Is new bag? = 0` in every session, good and bad, so the bag was not the differentiator.

---

## 8. Verifying the network path externally

From the same machine, moments after the failure:

```
GET https://s.mzstatic.com/sap/setupCert.plist
HTTP/1.1 200 OK
Content-Type: text/xml            Content-Length: 3257
Last-Modified: Tue, 30 Aug 2016 23:08:34 GMT
Cache-Control: public,max-age=86400,no-transform
Etag: "cb9-53b520f52e080"
Date: Mon, 07 Sep 2026 00:01:19 GMT      Age: 77100      X-Cache: hit-fresh
```

The body is a valid plist with one key, `sign-sap-setup-cert`, whose 2385-byte blob is a 6-byte header followed by
an X.509 certificate ("Apple System Integration Certification Authority", issued by Apple Root CA, validity
2011-01-26 to 2019-01-26). A conditional request with the ETag returned `304 Not Modified`. The other endpoints in
the sequence (`init.itunes.apple.com/bag.xml`, `buy.itunes.apple.com`, `fpinit.itunes.apple.com`) were reachable
with legitimate Apple TLS certificates.

Two things worth noting for later: the file has not changed since 2016, and the CDN edge returns a `Date` header from
when the edge cached the object (about 00:01 UTC each day) with a large `Age`.

---

## 9. Locating the cached state

The app's MediaServices state lives outside the package folder, in the publisher cache folder that survives
app updates (but not a full Reset):

```
%LOCALAPPDATA%\Publishers\nzyj5cx40ttqa\com.apple.MediaServices\
    accounts     SQLite  (account records)
    cookies      SQLite  (store cookies, per-account tables)
    data         SQLite  (DataProvider key/value cache)   ← the culprit
    HTTPCache2   SQLite  (HTTP cache; held only two bag.xml responses)
    itfes        SQLite
%LOCALAPPDATA%\Publishers\nzyj5cx40ttqa\com.apple.AuthKitWin\ckd.dat
```

A printable-strings pass over the SQLite files surfaced two key names in `data`: `mescal-certificate` and
`mescal-certificate-expiration`. Reading the database properly (via `winsqlite3.dll`, which ships with Windows,
called from PowerShell; no third-party tools) gave:

| domain | key | value |
|---|---|---|
| com.apple.MediaServices.default | AMSBagCacheProviderCurrentPlatformVersion | `<string>10.0</string>` |
| com.apple.MediaServices.default | com.apple.AppleMediaServicesKit.storefront-suffix.com.apple.Music | a storefront suffix string |
| com.apple.MediaServices.default | mescal-certificate | `<data>AQIAAAQWMIIEEjCCAvqg…</data>` (3193 bytes) |
| com.apple.MediaServices.default | mescal-certificate-expiration | `<date>2026-09-03T00:01:14Z</date>` |

Three observations tie this together:

1. **The expiration equals the CDN response's `Date` + `max-age`.** The file was written on 2026-09-02; the edge's
   `Date` that day would have been about 02 Sep 00:01 UTC, and 00:01:14 + 24 h = 2026-09-03T00:01:14Z exactly.
   The app does not account for `Age`, so a freshly fetched certificate can already be near or past "expiration".
2. **The cached certificate is bit-for-bit the server's.** Base64-decoding the cached blob yields 2385 bytes with the
   same SHA-256 as the file fetched with `curl`. Nothing was corrupted.
3. **The file was last written 2026-09-02 11:49:15**, unchanged through the good 9/4 session and the bad 9/7 launch.

---

## 10. Bisection

A small harness script did, per step: close the app gracefully → move one candidate file/folder to a backup
directory → launch the app → wait 40 s → capture the window with `PrintWindow` (works even when occluded) → close
the app so its log flushes → decode the new log → count Mescal requests, 7504s, 7502s, and error lines.

**Step 1: move only `…\com.apple.MediaServices\data`.**

Result: `StoreMescalSessionCert` → `StoreMescalSessionSetup` → `StoreMachineAuthorize` all completed; subscription
status fetched; **zero** 7504/7502; six benign errors identical to every good session (AirPlay device manager,
ADI one-time-password provisioning, two assertions). The window showed Home with personalized content. The account
was still signed in. The app did not recreate the `data` file during the session.

No further steps were needed. Before step 1, three launches that day with the file present had all failed.

---

## 11. Root cause statement

> **Superseded on 2026-09-09.** See the Correction section near the top. Kept for the record.

Apple Music for Windows caches the Mescal signing certificate with an expiration computed from the CDN response's
`Date` header plus `max-age`. On launch, when the cached entry is stale by some margin, the client reports the cached
data as invalid (7504) instead of refetching it, and the missing Mescal session makes every store request fail (7502).
The UI surfaces this as "An unknown error has occurred." The Try Again button cannot help because the stale cache
persists. A full app Reset "fixes" it only because it deletes this file along with everything else.

---

## 12. What remains uncertain

- **The exact trigger margin.** The same expired entry was accepted on 9/4 (about 1.7 days past expiration) and
  rejected on 9/7 (about 4.9 days past). A staleness threshold of a few days fits every observation and the user's
  "every few weeks" cadence, but it was inferred from one good and one bad data point, not proven.
- **When the app persists this cache.** In two weeks it wrote the file twice (first sign-in, and at the end of one
  long session). A session that ended by Windows shutting down did not write it.
- **Reverse test.** Putting the original file back to confirm the error returns (an A/B/A test) was proposed but not
  run at the time of writing. The three consecutive failures with the file present and immediate success without it
  are strong but not the last word.
- **Generality.** One machine. The mechanism is app logic with universal inputs, and public reports of identical
  symptoms and identical "only Reset works" workarounds exist from 2024–2026, but no other machine was examined.

---

## 13. Fix and workaround

> **Superseded on 2026-09-09.** The workaround below deleted the wrong file and did not prevent the recurrence. The
> current fix is in the Correction section and in the README.

**Immediate fix (what was done):** quit Apple Music, move
`%LOCALAPPDATA%\Publishers\nzyj5cx40ttqa\com.apple.MediaServices\data` to a backup folder, relaunch. No sign-out,
no library loss.

**Manual fix if it recurs** (app closed):

```powershell
Remove-Item "$env:LOCALAPPDATA\Publishers\nzyj5cx40ttqa\com.apple.MediaServices\data" -Force
```

**Preventive workaround:** a user-level scheduled task (`Install-AppleMusicFix.ps1`) that, while Apple Music is not
running and at most once per 24 hours, deletes that one file. The next launch fetches a fresh certificate; the app
already contacts Apple on every launch for its config bag and the Mescal handshake, so this adds no new dependency.
The file's other contents (a platform-version string and a storefront suffix) are caches the app rebuilds.

**Report to Apple:** the actionable pointers are the log line `Error initializing Mescal session. Invalid data
received` with store-request errors 7504/7502, the file path above, the `mescal-certificate-expiration` key, and the
fact that the cached blob matches the server copy.

---

## 14. Checking your own machine (for others with the same symptom)

1. Quit Apple Music. Open the folder
   `%LOCALAPPDATA%\Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa\LocalState\Logs`.
2. Decode the newest `Log-AMPLibraryAgent-*.etl` with
   `tracerpt <file> -o out.csv -of CSV -y` and search `out.csv` for `7504` and `Invalid data received`.
3. If they are there, look under `%LOCALAPPDATA%\Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa\AC\INetCache\`
   (every subfolder) for a file named `setupCert*.xml`. On the affected machine the bad copy was 2171 bytes and began
   with the bytes `1F 8B` (gzip); a good copy is a 3257-byte plain-text plist beginning with `<plist>`.
4. Delete that file with the app closed, then relaunch. Nothing else needs to be reset and you stay signed in:

   ```powershell
   Get-ChildItem "$env:LOCALAPPDATA\Packages\AppleInc.AppleMusicWin_nzyj5cx40ttqa\AC\INetCache" -Recurse -Force -Filter "setupCert*" | Remove-Item -Force
   ```

## Appendix A: benign errors present in every session

These appear in good and bad sessions alike and can be ignored when hunting this problem:

```
**ERROR**: AirPlayDeviceManager::Create() failed! status:9039
ADIOTPRequest failed with error -45061.
Assertion failure: (domainInfo != nullptr)
Assertion failure: (inIdentifier.valid())
edit> WARN 'radi' track modified outside of a transaction …      (radio playback, high volume)
AuthKitWin: Failed to create kccadp instance … KCCAError error 4  (push token; text log)
```

## Appendix B: tools used

PowerShell 5.1 (`Get-WinEvent`, `Get-AppxPackage`, `Get-NetTCPConnection`, `Get-ScheduledTask`), `tracerpt`,
`w32tm`, `curl` and `openssl` from Git for Windows, `winsqlite3.dll` via P/Invoke for read-only SQLite queries,
`PrintWindow` via P/Invoke for window captures. No third-party software was installed.

## Appendix C: redactions

Windows user name, email address, Apple account DSID, cloud-library machine ID, Windows SID, local IP addresses,
playlist and station names, and workspace paths were removed or replaced with placeholders. The publisher ID
`nzyj5cx40ttqa` is Apple's Store publisher hash and is the same on every machine.
