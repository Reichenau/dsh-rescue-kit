# DSH Rescue Kit

> Unofficial tool, not affiliated with DeepSeek.

> When your AI assistant breaks, double-click once and it photographs the scene into a zip you can hand to another AI.

Your AI hangs, throws an error, or just goes quiet — and all you have is "it stopped working".
The logs, the error, the context size, the config you changed last night: all of it is on that
machine, and the AI that could help you cannot see any of it.

This script does one thing: **it photographs the scene and packs it into a zip.**

## Privacy: what is masked and what is not

**This is a scene photograph, not a sanitized document. Do not hand it to strangers, public
groups, forums or issue trackers.**

**Masked:**

| Item | Handling |
|---|---|
| User name | Replaced with `%USERNAME%` everywhere (the real name is not searchable in the package) |
| User profile path | Replaced with `%USERPROFILE%` |
| token / key / cookie / password / API credentials | Replaced with placeholders; `credentials.yaml` is only reported as "how many keys are configured", never key names or values |
| MAC address | Only the vendor OUI is kept; the last three octets become `xx:xx:xx` |

**Not masked (needed for diagnosis, but it exposes machine details):**

| Item | Where | Example |
|---|---|---|
| LAN / loopback IP | `network.txt` | `192.168.x.x`, `127.0.0.1` |
| Ports, PIDs, process names | `network.txt`, `processes.tsv` | `3443  pid=22868  DeepSeek Harness` |
| Machine model | `system.txt` | `LENOVO 82XX` |
| Session ids | `sessions.txt`, `session-tail.txt` | `session-d4747a37-…` |
| Drive letters and capacity | `system.txt` | `C: free=12.8GB` |
| Install path | `system.txt`, `processes.tsv` | `D:\deepseek\DeepSeek Harness.exe` |
| Raw Windows event log text | `recent-errors.txt` | includes faulting app names and paths |
| Log tail fragments | `logs/` | may contain pieces of your own conversation |

## Before you hand it over

1. Send it only to people you trust, or to an AI service you trust;
2. Do not post it in public groups, forums or issues;
3. Open `session-tail.txt` and `logs/` and glance through them — they may contain things you said;
4. If you want one more layer of removal, delete `network.txt`, `sessions.txt` and `logs/` before
   handing it over, at the cost of less diagnostic evidence.

---

## Quick start

1. Put these files in any empty folder (anywhere works; the script locates itself).
2. Double-click `rescue-kit.bat`. It first asks: **what do you see on screen?** (one line; press
   Enter to skip).
3. Wait thirty to sixty seconds (about 36–52s on our test machines); the window prints one line per step and ends with:

   ```
   OK C:\...\reports\11-04 20点18分 2026.zip (79.6 KB)
   ```

4. Open `reports\`, **read `index.md` yourself first**, then drag the whole zip to another AI. Old zips can be deleted; keep the newest one.

The zip is named after the moment it was made: **date, hour and minute, year**. Running twice in the
same minute does not overwrite: the second becomes `... (2).zip` — people double-click when things go
wrong, and losing one scene would waste the capture.

**If collection fails halfway**, nothing already collected is thrown away: the script writes
`PARTIAL-11-04 20点18分 2026.zip`, a half-finished but readable package. If even packaging fails
(disk full, path too long), it stops, **does not delete** the temp folder, and prints its full path —
zip it by hand, the evidence is still there.

### Bring the sentence you saw

The best use includes the exact error you were given:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File make-rescue-kit.ps1 -Symptom "window is white, messages will not send"
```

That sentence goes into the top of `index.md`. Whoever reads it knows where to look instead of guessing.

The double-click prompt does the same thing: the PowerShell side asks with `Read-Host`, which is
Unicode-native, instead of cmd's `set /p` plus `chcp` — so a GBK console cannot mangle the text. On the
command line, `-SymptomFile <path>` takes the same route.

Before starting, the script also checks free space on the drive holding `reports\`: under 200 MB it
warns immediately. Spending 30–60 seconds collecting and then failing to package because the disk is full
is the most pointless way to waste a run.

---

---

## Versions

**v5.2** · 2026-11-08 (first stable release)

Compared with the last published release (v5.0.3), this version moves from "collects evidence" to "tells you what it means, and reproduces config errors itself":

- **A health-check verdict**: the zip now carries `checks.json`, and `index.md` opens with a PASS / WARN / FAIL table — read a few lines instead of digging through dozens of files.
- **It re-runs your configuration**: for every profile that works from the CLI it runs `dsh --profile <name> --dump-config` and surfaces YAML errors and missing patch entries (e.g. `patch: entry "tool-ralph" not found`). This is the biggest upgrade in this release.
- **Better secret detection**: alongside `sk-` and `AKIA`, it now masks `ak-`, `org-`, `lin_api_`, `xai-` and friends, then re-scans the whole package before zipping so an API key cannot ride along.
- **Automatic channel fallback**: when cmd returns nothing, the kit retries through PowerShell; a 30-second hang is killed instead of stalling the whole run. Dump headers record the channel, whether a retry happened, and the exit code.
- **The Chinese prompt no longer breaks**: the question moved into PowerShell (English + Chinese), so cmd's `set /p` and `chcp` can't mangle it; genuine mojibake still raises a warning.
- **It announces the result**: the console always ends with `checks: X ok / Y warn / Z fail`; if the window is force-closed and only `_tmp` remains, the bat tells you how to pack it manually.
- **More detail where it matters**: free space on the system / DSH / report drives, crash-dump counts inside and outside the 48-hour window, and a warning when the desktop and CLI versions disagree.
- **23 regression probes ship with the repo** (`tests/`), so fixing one thing cannot silently break another (23 checks / 0 mismatch this round).

**v5.1.5** · 2026-11-08

Marvis reviewed v5.1.4 as **ship (0 P0 / 0 P1)**; two small P2 cleanups followed:

- **Symptom warning parity**: pressing Enter at the prompt now also records a `symptom` WARN (detail says `skipped at the prompt` vs `non-interactive run`), so downstream readers can tell "user skipped" from "tool never asked".
- **`_tmp` salvage hint**: the bat now says up front that a mid-run close may leave a `_tmp` folder worth zipping by hand, and the success path re-checks for it.
- **Docs wording**: the bat opens the `reports` folder, not a specific report file.

**v5.1.4** · 2026-11-08

Another round from Marvis's black-box review of v5.1.3 (0 P0 / 2 P1 / 7 P2):

- **`exit_note` only when stdout is actually empty**: the old condition fired for any non-ok status with exit 0, so a profile with 417 lines of stdout and a stderr warning was labelled "stdout was empty". The note now keys off empty output and carries the real exit code.
- **`retry` field in the dump header**: `0`, or `1 (powershell empty -> cmd)`.
- **Bilingual prompt**: the `Read-Host` question now prints English and Chinese.
- **Non-interactive runs get a `symptom` WARN**: no `-Symptom` plus redirected stdin no longer disappears silently.
- **Truncation noted**: the stdout separator reads `first 250 of N lines`.
- **README cleanup**: removed the obsolete `chcp 65001` / `set /p` / `DSH_RESCUE_SYMPTOM` wording; noted that old report zips can be deleted.

**v5.1.3** · 2026-11-08

A round driven by Marvis's black-box review of v5.1.2. The point is the CLI evidence path:

- **dump-config now runs through PowerShell first (`dsh.ps1`)**: on Marvis's machine every `cmd.exe` / `dsh.cmd` call returned 0 bytes while `dsh --profile <p> --dump-config` through PowerShell printed a stable 407-line tree. PowerShell is tried first; cmd is retried once only when the PowerShell capture is empty. FAIL is reported only after both channels come back empty, and the wording now says it is a kit capture failure, not proof that the install is broken.
- **Real timeout and real cleanup**: both channels get a hard 30s timeout and a process-tree kill (the old code killed only `cmd.exe`, so the node child could survive).
- **Channel fields in the dump file**: `cli_exe`, `channel` (with retry flag) and `exit_note`, so nobody has to guess from `exit_code=0`.
- **CLI version from the same source**: version detection prefers `dsh.ps1`; when it cannot be read, `system.txt` says `dsh_cli = (not detected)` and the version check reports WARN instead of a false PASS.
- **Credential sweep is always visible**: the `credentials` check now appears on every run (WARN on hits, PASS otherwise) instead of only existing when something was found.
- **Crash-dump summary accounts for every file**: the check reports both the unrelated dumps in the 48h window and the total on disk (including unnamed dumps outside the window).
- **Chinese symptoms no longer turn into mojibake**: the prompt moved to PowerShell's `Read-Host` (Unicode-native) and the bat stays ASCII; a U+FFFD symptom still raises a `symptom` WARN and suggests `-Symptom`.
- **Console summary**: after packaging the kit prints `checks: X ok / Y warn / Z fail` and points at `index.md` when there are failures.

**v5.1.2** · 2026-11-08

Two ideas borrowed from the community's `dsh-doctor` — not its auto-repair. This kit stays read-only
forensics; what got harder is the judgement:

- **Structured checks**: each check carries `kind / status / detail / fix_hint` and lands in
  `checks.json`; `index.md` opens with a PASS / WARN / FAIL table and a summary line such as
  `N passed, N warnings, N failures`.
- **Reproduce config errors up front**: for every profile the CLI can reproduce, run
  `dsh --profile <p> --dump-config` and surface the first `Error:` / `YAMLException:` line in triage.
  `desktop` is owned by Electron; it is skipped and recorded as a warning.
- **When the exit code lies, stderr wins**: `dsh.cmd` does not propagate node's exit code (a broken
  YAML still reports 0), so FAIL / WARN is decided from stderr; `dump-config-*.txt` records an
  `exit_note`.
- **Raw output no longer ships**: the dump `.out/.err` go to a temp directory, are masked into the
  report and deleted; the zip only carries the masked `dump-config-*.txt`.
- **False FAILs removed**: bundle resolution is left to the compose result instead of guessing from
  `profiles\<name>\node_modules`; triage no longer mistakes `timeoutMs` inside dump files for a timeout.
- More environment checks: parseable `package.json`, `link:` dependencies that actually exist, compose
  results, free disk space, crash dumps.

**v5.0.3** · 2026-11-05

This round came from a third-party review (Marvis testing v5.0.2); the theme is "stop producing
false alarms about yourself":

- **The event log no longer reports "nothing in range" as "could not read"**: `Get-WinEvent`
  throws `NoMatchingEventsFound` when no event matches, and the old code recorded every catch as
  a read failure, so almost every healthy machine carried a fake NOTE. It is now distinguished by
  `FullyQualifiedErrorId`; only real failures are recorded.
- **The port-table degradation note now keys off the source**: the condition changed from
  "fewer than 5 rows" to `$portSource -ne 'Get-NetTCPConnection'`. With the `IPGlobalProperties`
  fallback, pid and process name are empty — exactly the case that needs saying out loud.
- **DSH's port is found by pid now**: on a real machine the command line carries no port (the host
  listens on a LAN address, e.g. `192.168.x.x:3443`), so the old probe never hit. Matching the DSH
  pid against `OwningProcess` marks the row `[dsh]`; the command-line probe stays as a supplement.
- **`TreeOf` also skips reparse points while enumerating subdirectories**: a junction loop no longer
  leaves `loop\loop` entries in the tree.
- **`system.txt` time uses the shared `$CapturedAt`** instead of its own clock.
- **Tabs inside event messages are flattened**, so a message containing a TAB cannot shift TSV columns.

**v5.0.2** · 2026-11-05

A self-audit (1,700 lines reviewing themselves), fixing the "the zip was written but the tool says it
failed" class of bugs:

- **`$ok` no longer means two things**: the port probe result moved to `$probeOk`. When the host was
  frozen and the probe port refused, the zip was already written but the script exited 1, the bat
  printed FAILED and did not open reports — precisely the situation the kit exists for.
- **Empty `APPDATA` / `LOCALAPPDATA` no longer crash**: under SYSTEM or some scheduled tasks those
  variables are empty, `Join-Path` throws a parameter-binding exception and takes every later section
  with it. Everything now goes through `EnvDir`; when a value is missing the step is skipped and logged.
- **Directory sizes can no longer hang on junctions**: `TreeOf` used `Get-ChildItem -Recurse`; an
  `-ExtraDirs` folder containing a junction loop would walk forever. It uses `DirSize` with reparse
  skipping and both a file-count and a wall-clock cap.
- **`tree-extra-*.txt` names no longer leak folder names**: they are `tree-extra-1.txt`; the real path
  lives inside the file (path in clear, only the user name becomes `%USERNAME%`).
- **The event log now distinguishes "could not read" from "nothing there"**: when `Get-WinEvent`
  fails, `recent-errors.txt` says so in its header instead of calling a permission problem "no errors".
- **The bat no longer reports `PARTIAL-*.zip` as the latest report.**

**v5.0.1** · 2026-11-05

Fixes from a real user report (v5.0.0 output from a friend's machine); the first three directly
distorted "hand the zip to another AI":

- **`processes.tsv` now has a real tab in its header.** The old single-quoted `'name`tpid...'` wrote a
  literal backtick-t, so `Import-Csv` produced one column.
- **Newlines and tabs inside command lines are flattened**, so one process no longer folds into two
  rows and shifts every later column.
- **The port table gained a fallback and a disclosure**: in a low-integrity context
  `Get-NetTCPConnection` is denied and it falls back to `IPGlobalProperties`; if that fails too, the
  report says "this table is incomplete". It also probes `--port` / `127.0.0.1:<port>` found in the
  DSH command line to recover the web port when possible.
- **Timestamps split**: `captured_at` is when collection started, `packaged_at` is when the zip was
  written; `index.md` lists both instead of using the latter as the former.
- **Automatic triage states its scope**: it only claims "no error strings in the DSH state/logs that
  were scanned" and points to `recent-errors.txt`; Windows event logs were never in scope.
- **`recent-errors.txt` gained a header** (time / channel / provider / id / message) and an aggregation
  note; when there is nothing, it says so explicitly.
- **Chinese keywords were added to the automatic triage**: all nine groups used to be English-only,
  which produced "no errors found" on mostly-Chinese logs. 内存不足 / 连接被重置 / 超时 / 未响应 /
  端口占用 and friends now match too.
- The `tree-dsh.txt` description now says "two-level directory overview" instead of claiming a full tree.

**v5.0.0** · 2026-11-04

This version closed the places where "the package you got might be wrong":

- **Chinese logs over 32 MB no longer turn into mojibake** (a regression introduced by the v5 beta).
  When tailing the last 8 MB, the cut could land in the middle of a multi-byte character; strict
  UTF-8 decoding threw, the code fell back to GBK, and the whole file became `浜嬩欢缂栧彿`. It now
  aligns to a line boundary before decoding, and UTF-16 tails use an even offset.
- **The `[tail of N MB file, last 8 MB only]` note is no longer cut off**: it used to be prepended
  before taking the last 300 lines, and cut itself away.
- `soul-md` is no longer scanned as an ordinary log directory — before, memory `.txt` files leaked
  into `logs\` even with `-IncludeMemory` off.
- Text files whose names contain `cookie` / `token` / `secret` / `password` / `credential` are no
  longer collected as logs: one plugin stored a live 6 KB `sessionid` in `.dsh\douyin-duty\douyin_cookie.txt`.
- 8.3 short names (`C:\Users\LAIYUH~1\...`) are replaced as a whole with `%USERNAME%`, no more
  malformed `%USERNAME%~1`.
- `environment.txt` no longer contains self-referential lines like `COMPUTERNAME = %COMPUTERNAME%`;
  long values are cut on `;` / `\` boundaries so PATH cannot end mid-directory-name.
- The triage `module missing` rule no longer counts 62 `level=info` toggles from the plugin market as failures.
- `Mask-Secrets` calls gained parentheses: under PowerShell 7 the old form raised a parameter-binding
  error and the user name leaked.
- Version numbers are one semantic version (script header, `$KitVersion`, README, `index.md`), no more
  `v0.3.0` mixed with `5`.

The v5 beta features are now officially part of the record: short log aliases (no more `..` long
prefixes), crash logs renamed from `crash_<time>_<role>.log` (shorter without losing the timestamp),
log scanning extended to `.ndjson` / `.jsonl` and sibling `.dsh-*` directories, `-Minimal` keeping only
DSH processes, and the symptom moved to an environment variable (so `&` and `%` are not eaten by cmd).

Earlier (v0.4): long-path packaging, multi-frame session-tail decoding, environment variable allowlist,
crash logs keep their timestamps.
Before that (v0.3.x): secret masking extended to JWT / non-HTTP schemes / `*_KEY=`, triage requires
context around numeric error codes, and a `PARTIAL` zip is written before discussing exit codes.

**Known limit**: on Windows, a third-party archiver that has taken over the `.zip` association can
block packaging. If that happens the script prints a `PARTIAL: ...` line and writes `PARTIAL-*.zip`;
that line means the main path failed and the zip is the fallback.

---
## Start with `index.md`

Every file in the package is raw evidence; `index.md` is the **guide** to that evidence:

- capture time / DSH version / **was it running at that moment**
- the symptom you typed
- a file navigation table (which file answers which question)
- **automatic triage**: counts traces of `out of memory` / `port in use` / `unauthorized` /
  `rate limit` / `context window` / `timeout` / `module missing` in the logs, grouped by file,
  **with the first matching line quoted** — no need to open files to tell a real error from noise.
  (Bare-number matches require HTTP context, so a `401` inside a UUID, a port number, or `592.3 MB`
  is not counted as a 401/592 error.)
- **threshold warnings**: a few GB left on disk, low memory, a process with `Responding=False`,
  crash dumps in the last 48 hours

A reader usually knows within thirty seconds whether to keep reading.

---

## What it collects

| File | Contents |
|---|---|
| `index.md` | **guide + automatic triage + warnings** — read this first |
| `dsh-status.txt` | was DSH running at capture, version, how many logs were found |
| `session-tail.txt` | the last 25 session events — "where did it get stuck"; **contains fragments of your conversation, see the privacy section** |
| `timeline.txt` | fresh install or long history; what changed in the last 48 hours |
| `dsh-process-tree.txt` | process tree rooted at DSH — which plugin spawned which helper |
| `logs\` | last 300 lines of each log: **crash logs first**, then `.log` / `.txt` / `.ndjson` / `.jsonl` |
| `crash-dumps.txt` | whether a dump file was actually written, and when |
| `network.txt` | proxy, adapters/gateway/MAC, local listening ports, DNS |
| `processes.tsv` | every process + command line + **responding state + working set** (secrets masked) |
| `system.txt` | OS build, free space per drive, memory, boot time, **GPU model + driver version**, DSH version |
| `environment.txt` | environment variables (**values masked**) — a broken `PATH` / `NODE_OPTIONS` / `DSH_HOME` is the most common "it suddenly stopped working" |
| `tree-dsh.txt` | two-level overview of `.dsh`: level one is full path + size, level two is names only |
| `tree-extra-*.txt` | extra project directories you named (optional) |
| `sessions.txt` | all workspaces, all session folders and sizes |
| `recent-errors.txt` | Windows errors from the last 24 hours (Application + System, repeats collapsed, each cut at 500 chars) |
| `credentials-meta.txt` | **how many** credentials are configured (count only, not even provider names) |
| `memory-head.txt` | memory file (**only with `-IncludeMemory`**) |
| config copies | `cordis.patch.yml`, `package.json`, guardian state |

Logs are not only under `.dsh\logs`. Since 0.2.1-rc.3 the runtime logs are **not written** to
`.dsh\logs` at all — what you see there is left over from older versions. The real writers are crash
logs under `%APPDATA%\@deepseek-ai\dsh-desktop\logs\crash-*.log`, which is why those come first.
Some plugins write `.ndjson`, some put traces in a sibling directory **next to** `.dsh` (for example
`.dsh-wallpaper-engine\diag\`); the script scans all three places.

It is **read-only**, changes nothing, needs no administrator rights, and never touches the network.

---

## What it does **not** collect

- **Credential files**: `.credentials.yaml` is never copied; `credentials-meta.txt` reports
  "exists / size / how many keys", not even provider or key names.
- **API keys**: strings that look like keys in command lines and logs are replaced with `***`.
  Recognized shapes include OpenAI / Anthropic / Google / Volcano / AWS / GitHub / Slack / JWT /
  various `*_KEY=` `*_TOKEN=` environment variables / `user:pass@` in URLs / PEM private key blocks.
- **Your user name and paths**: `%USERPROFILE%` and the user name are replaced before anything is written.
- **Your memory**: not packaged by default. To include it:

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File make-rescue-kit.ps1 -IncludeMemory
  ```

- **Directories outside `.dsh`**: only log files in sibling `.dsh-*` directories next to `.dsh` are
  read; no other directory is touched. To add your own project directory, name it with `-ExtraDirs`:

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File make-rescue-kit.ps1 -ExtraDirs "D:\my-project","C:\my-work"
  ```

- **Your own txt files**: text files under `.dsh` whose names contain `cookie` / `token` / `secret` /
  `password` / `credential` (for example a plugin storing a cookie jar in `douyin_cookie.txt`) are not
  collected as logs. They are not "credential files" by format, but the content is a live credential.
  How many were skipped is recorded in `dsh-status.txt` as `skipped_secret_named_logs`.

### About `session-tail.txt` — read it before handing the package over

This file is the only evidence of "where it got stuck", so it **inevitably contains your own words**:
the last 25 session events, each cut at 600 characters. Secrets and the user name are masked, but the
conversation itself cannot be — masking it would remove the diagnostic value.

So: **before giving the package to anyone, open `session-tail.txt` and read it.** If there is something
you would rather not share, delete that part; the rest of the files stay useful.

### The smallest possible package

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File make-rescue-kit.ps1 -Minimal
```

`-Minimal` keeps only processes whose **command line** contains `dsh` / `deepseek` / `electron` /
`cordis` (matched by command line, not by process name); `processes.tsv` shrinks from a couple hundred
rows to a few dozen — what other software is doing is irrelevant to this failure. (-Minimal only trims the process table; network, timeline and environment are still collected.)

---

## Why a standalone kit

Because **when it breaks you cannot open the AI, so you cannot ask it**.

Another AI (Doubao, Kimi, Claude, whoever) can read this zip and tell: whether the context hit the
window, which process is stuck, whether a config is wrong, what the last log line says. No remote
connection to your machine, no copying and pasting line by line.

---

## Requirements

- Windows 10 / 11
- PowerShell 5.1 (built in, nothing to install)

No third-party modules, no Node, no Python.
`session-tail.txt` needs some node to unpack `.zstd` session files — the script looks in the runtime
bundled with DSH and skips that file if it cannot find one; everything else is still packaged.

---

## Pitfalls we hit (all fixed, written down so you do not repeat them)

1. **The script must be saved as UTF-8 with BOM.** Windows PowerShell 5.1 reads scripts in the ANSI
   code page by default; UTF-8 without BOM turns every Chinese string into mojibake — file names become
   `.zip`, format strings become question marks. The version in this repo has a BOM; **after editing
   with any editor, make sure the BOM is still there** (VS Code: `UTF-8 with BOM` in the bottom right).
2. **Do not read logs with `Get-Content`.** Half the Chinese logs are UTF-8, half are GBK; `Get-Content`
   guesses ANSI and turns a whole file into garbage when it guesses wrong. The script uses
   `Read-TextAuto`: check for a UTF-16 BOM, decode strictly as UTF-8, fall back to GBK, and open files
   with a shared read so live logs can still be read.
3. **Throwing again inside `catch` escapes the whole script.** The first version called
   `[IO.File]::Open` again inside the decode-failure `catch`; that call failed too, and the exception
   passed straight out of the `catch` and killed the script — one unreadable file could prevent the
   whole report from being generated. Now every `catch` has its own `try`, and the main flow is wrapped
   in `try/catch/finally`, so a failure still produces a report.
4. **Chinese file names are fine**, but zip stores UTF-8 file names and a few old unzip tools show them
   as mojibake — the built-in Windows extractor is fine. Packaging explicitly sets the UTF-8 flag.
5. **Do not sort logs by file size.** Chromium LevelDB logs can be several MB of binary; sorting by size
   pushes the useful `desktop-next.log` out — the package grows to 890 KB and is still all garbage. The
   script uses "core logs unconditionally + the most recent of the rest by mtime + noise filtering".
