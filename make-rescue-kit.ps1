#requires -Version 5.1
<#
  DSH Rescue Kit  v5.1.1
  =======================
  Snapshot whatever your AI agent workspace looked like when it broke, into one
  zip. Hand the zip to another AI (or a human) and it can read the evidence
  without touching your machine.

  Read-only. No admin rights. Nothing is uploaded anywhere.

  Usage:
      powershell -NoProfile -ExecutionPolicy Bypass -File make-rescue-kit.ps1
      powershell ... -File make-rescue-kit.ps1 -Symptom "window went white"
      powershell ... -File make-rescue-kit.ps1 -IncludeMemory   # also include memory
      powershell ... -File make-rescue-kit.ps1 -ExtraDirs "C:\proj1","D:\proj2"
      powershell ... -File make-rescue-kit.ps1 -Minimal         # DSH processes only

  Output lands in ./reports/ next to this script.

  IMPORTANT: save this file as UTF-8 *with BOM*. Windows PowerShell 5.1 reads
  scripts in the ANSI codepage by default and would garble every Chinese string
  in here.

  Where the evidence actually lives (0.2.1-rc.3 and later):
      <dsh>\logs\desktop-next.log      STOPPED being written around rc.3. If it
                                       exists it is a leftover from an older
                                       build, and its last line is the best clue
                                       for "which build wrote it".
      %APPDATA%\@deepseek-ai\dsh-desktop\logs\crash-*.log
                                       written on every failed host start.
      <dsh>\sessions\<ws>\<session>\session.v4.jsonl.zstd
                                       the only recording of what the agent was
                                       doing. Compressed; we decode the tail.
#>

[CmdletBinding()]
param(
    # Include the agent's long-term memory files. OFF by default: memory is
    # personal, and this zip is meant to be handed to someone else.
    [switch]$IncludeMemory,

    # Extra directories to map (your projects). Nothing outside .dsh is read
    # unless you name it here.
    [string[]]$ExtraDirs = @(),

    # One line about what actually went wrong. Worth more than 90 KB of logs:
    # "window went white" and "history is gone" lead to different investigations.
    [string]$Symptom = '',

    # Same thing, read from a file instead. The .bat uses this: a symptom typed
    # into a cmd window arrives through %* in the console's codepage, which
    # mangles non-ASCII text before the script ever sees it.
    [string]$SymptomFile = '',

    # Collect only agent-related processes. Use this when the zip may end up
    # somewhere public: processes.tsv otherwise carries every command line on
    # the machine.
    [switch]$Minimal
)

$ErrorActionPreference = 'Continue'

$KitVersion = '5.2'
# One clock for the whole kit. "captured" must mean "when the evidence was
# gathered", not "when the zip was written two minutes later". ISO 8601 keeps
# timezone offset, so two captures from different zones stay comparable.
$CapturedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')

# --- where things live -------------------------------------------------------

# DSH home: honour DSH_HOME, else the default under the user profile.
# No hard-coded user name, so this works on any machine.
# A host started from a service context can have neither variable. In that case
# a sentinel keeps every later Join-Path/Test-Path working and the report still
# explains the real problem instead of dying inside Test-Path $null.
$dshHomeMissing = $false
$Dsh = $env:DSH_HOME
if ([string]::IsNullOrWhiteSpace($Dsh)) {
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $dshHomeMissing = $true
        $Dsh = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-home-missing-' + $PID)
    } else {
        $Dsh = Join-Path $env:USERPROFILE '.dsh'
    }
}

# $PSScriptRoot is the reliable one: $PSCommandPath is empty when the script is
# dot-sourced or wrapped in -Command.
$KitDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($KitDir)) { $KitDir = Split-Path -Parent $PSCommandPath }
if ([string]::IsNullOrWhiteSpace($KitDir)) { $KitDir = (Get-Location).Path }
$OutDir = Join-Path $KitDir 'reports'
$OutDrive = Split-Path -Qualifier $OutDir

$Now     = Get-Date
$Stamp   = $Now.ToString('yyyyMMdd-HHmmss')
$ZipName = '{0}点{1}分 {2}' -f $Now.ToString('MM-dd HH'), $Now.ToString('mm'), $Now.ToString('yyyy')

# Scratch space next to the script, NOT under %TEMP%: a full system drive is one
# of the situations this kit is supposed to diagnose, and building the report in
# %TEMP% would then be the thing that fails.
$TmpRoot = Join-Path $KitDir '_tmp'
$Tmp     = Join-Path $TmpRoot ('rk-' + $Now.ToString('HHmmss') + '-' + $PID)

# Artefacts that could not be written. Surfaced in index.md instead of aborting.
$script:WriteFailures = @()

# Long paths cannot go through the *-Item cmdlets, so create these two with the
# .NET API (see LongPath below for why).
function LongPath($p) {
    if ([string]::IsNullOrEmpty($p)) { return $p }
    if ($p.StartsWith('\\?\')) { return $p }
    if ($p.StartsWith('\\')) { return '\\?\UNC\' + $p.Substring(2) }
    if ($p.Length -ge 200 -and [System.IO.Path]::IsPathRooted($p)) { return '\\?\' + $p }
    return $p
}

# Creating the working and output folders is the one step with no fallback: if
# it fails (drive gone, folder is a file, permission denied) the rest of the run
# is pointless, so say why instead of dying on a raw .NET exception.
try {
    [System.IO.Directory]::CreateDirectory((LongPath $Tmp))    | Out-Null
    [System.IO.Directory]::CreateDirectory((LongPath $OutDir)) | Out-Null
} catch {
    Write-Host ''
    Write-Host '  Cannot create the report folders:' -ForegroundColor Red
    Write-Host "    $OutDir" -ForegroundColor Red
    Write-Host "    $Tmp" -ForegroundColor Red
    Write-Host "    $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    exit 1
}

# Collecting into a full disk is the classic way to lose the evidence you just
# spent half a minute gathering: everything works until the zip write. Check the
# free space up front and say it out loud while the user can still move the kit.
$outFreeMB = $null
try {
    $outRoot = [System.IO.Path]::GetPathRoot($OutDir)
    if ($outRoot) {
        $outDi = New-Object System.IO.DriveInfo($outRoot)
        if ($outDi.IsReady) { $outFreeMB = [math]::Round($outDi.AvailableFreeSpace / 1MB, 0) }
    }
} catch { }
if ($null -ne $outFreeMB -and $outFreeMB -lt 200) {
    Write-Host ''
    Write-Host ("  WARNING: only {0} MB free on {1} (the drive that holds the report)." -f $outFreeMB, $OutDrive) -ForegroundColor Yellow
    Write-Host ("           {0}" -f $OutDir) -ForegroundColor Yellow
    Write-Host '           The collection may finish and the zip still fail to write.' -ForegroundColor Yellow
    Write-Host '           Free some space, or move this whole folder to another drive first.' -ForegroundColor Yellow
    Write-Host ''
}

# --- helpers -----------------------------------------------------------------

# Progress. The run takes 35-50 seconds now (it also boots the real composer
# once per profile); a silent console reads as a hang, and people kill it right
# before the part that matters.
function Step([string]$msg) { Write-Host ('  ' + $msg) -ForegroundColor DarkGray }

# Joining a null folder variable throws a PARAMETER BINDING error, which is
# terminating and would take the rest of the collection with it. APPDATA and
# LOCALAPPDATA are empty under SYSTEM / some scheduled-task contexts, so every
# use of them goes through here and skips the entry instead.
function EnvDir([string]$name) {
    $v = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v
}

# Directory size without following junctions. Get-ChildItem -Recurse follows
# reparse points on PowerShell 5.1, so one link loop under an -ExtraDirs folder
# walks forever; a plain full walk also turns a 200k-file node_modules into a
# minute of silence. Bounded by file count and wall clock on purpose: a size in
# the tree is a hint, not an audit.
function DirSize([string]$path) {
    $sum = 0L
    $seen = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $stack = New-Object System.Collections.Stack
    $stack.Push($path)
    while ($stack.Count -gt 0 -and $seen -lt 50000 -and $sw.ElapsedMilliseconds -lt 4000) {
        $d = [string]$stack.Pop()
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue)) {
                $sum += $f.Length; $seen++
            }
            foreach ($sd in @(Get-ChildItem -LiteralPath $d -Directory -Force -ErrorAction SilentlyContinue)) {
                if (($sd.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($sd.FullName)
            }
        } catch { }
    }
    return $sum
}

function Add-Text($name, $text) {
    $plain = Join-Path $Tmp $name
    $dir   = Split-Path $plain -Parent
    $dirL  = LongPath $dir
    if (-not [System.IO.Directory]::Exists($dirL)) { [System.IO.Directory]::CreateDirectory($dirL) | Out-Null }
    # Two source paths can flatten to the same file name (a\b.log vs a_b.log).
    # Never let the second write silently erase the first.
    $p = LongPath $plain
    if ([System.IO.File]::Exists($p)) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($plain)
        $ext  = [System.IO.Path]::GetExtension($plain)
        $i    = 2
        while ([System.IO.File]::Exists($p)) { $p = LongPath (Join-Path $dir ("{0}-{1}{2}" -f $base, $i, $ext)); $i++ }
    }
    # Masked twice on purpose: call sites mask early so no line is ever written
    # raw by accident, and this one catches anything that skipped them. Masking
    # an already-masked string is a no-op, so the belt is cheap.
    $masked = Mask-Secrets ([string]$text)
    # Written without a BOM on purpose: a leading U+FEFF makes JSON/YAML parsers
    # choke, and this zip is meant to be machine-read by another agent.
    # A single unwritable artefact must not destroy the whole report: record it
    # and let the run finish.
    try {
        [System.IO.File]::WriteAllText($p, $masked, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        $script:WriteFailures += ("{0} ({1})" -f $name, $_.Exception.GetType().Name)
    }
}

function Add-Bytes($name, $bytes) {
    $plain = Join-Path $Tmp $name
    $dir   = Split-Path $plain -Parent
    $dirL  = LongPath $dir
    if (-not [System.IO.Directory]::Exists($dirL)) { [System.IO.Directory]::CreateDirectory($dirL) | Out-Null }
    try {
        [System.IO.File]::WriteAllBytes((LongPath $plain), $bytes)
    } catch {
        $script:WriteFailures += ("{0} ({1})" -f $name, $_.Exception.GetType().Name)
    }
}

# Logs are a mix of UTF-8 (with or without BOM) and legacy GBK. PowerShell 5.1's
# Get-Content guesses by the ANSI codepage and turns non-ASCII into mojibake, so
# read bytes and sniff: BOM first, then strict UTF-8, then GBK.
function Read-TextAuto($path, $maxLines) {
    # ReadAllBytes on a multi-hundred-MB log throws OutOfMemory, and it throws
    # LATE - after the log section - so the PARTIAL fallback ends up without an
    # index.md. Anything large is tail-read instead; the half line at the cut is
    # dropped after decoding.
    $tailOnly = $false
    $len = 0
    try {
        $len = (New-Object System.IO.FileInfo($path)).Length
        if ($len -gt 32MB) { $tailOnly = $true }
    } catch { }

    # A tail read starts in the middle of the file, so it never contains the BOM
    # - the encoding has to be read from the first four bytes separately. UTF-16
    # also needs an even seek offset, or every code unit comes out byte-swapped.
    $utf16 = 'none'
    if ($tailOnly) {
        try {
            $hfs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            $hb = New-Object byte[] 4
            $hn = $hfs.Read($hb, 0, 4)
            $hfs.Close()
            if ($hn -ge 2 -and $hb[0] -eq 0xFF -and $hb[1] -eq 0xFE) { $utf16 = 'le' }
            elseif ($hn -ge 2 -and $hb[0] -eq 0xFE -and $hb[1] -eq 0xFF) { $utf16 = 'be' }
            # BOM-less UTF-16 still shows a NUL in every high byte of ASCII text.
            elseif ($hn -ge 4 -and $hb[1] -eq 0 -and $hb[3] -eq 0) { $utf16 = 'le' }
            elseif ($hn -ge 4 -and $hb[0] -eq 0 -and $hb[2] -eq 0) { $utf16 = 'be' }
        } catch { }
    }

    $bytes = $null
    if ($tailOnly) {
        try {
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            $keep = [int][Math]::Min($len, 8MB)
            if ($utf16 -ne 'none' -and ((($len - $keep) % 2) -ne 0)) { $keep++ }
            [void]$fs.Seek(-$keep, [System.IO.SeekOrigin]::End)
            $ms = New-Object System.IO.MemoryStream
            $fs.CopyTo($ms)
            $fs.Close()
            $bytes = $ms.ToArray()
            $ms.Close()
        } catch {
            return "<unreadable: $($_.Exception.GetType().Name)>"
        }
    } else {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
    } catch {
        # File is open in another process: reopen with shared read. This second
        # attempt can fail too (vanished, locked exclusively, path too long), and
        # an exception thrown from a catch block escapes the whole script, so it
        # gets its own guard.
        try {
            $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
            $ms = New-Object System.IO.MemoryStream
            $fs.CopyTo($ms)
            $fs.Close()
            $bytes = $ms.ToArray()
            $ms.Close()
        } catch {
            return "<unreadable: $($_.Exception.GetType().Name)>"
        }
    }
    }
    if ($null -eq $bytes) { return '<unreadable: null buffer>' }

    # Where the text starts in the buffer, and whether the first line is the tail
    # of a record whose beginning was cut off.
    $start = 0
    $cutMidLine = $false
    if ($tailOnly -and $utf16 -eq 'none') {
        # Align to a line start BEFORE decoding. 0x0A cannot occur inside a
        # multibyte UTF-8 or GBK character, so the first newline is a real
        # boundary. Without this, a cut that split a Chinese character made the
        # strict UTF-8 decode throw, the GBK fallback swallowed the whole 8 MB,
        # and every UTF-8 log over 32 MB came out as mojibake.
        $nl0 = [Array]::IndexOf($bytes, [byte]10)
        if ($nl0 -ge 0) {
            $start = $nl0 + 1
            $cutMidLine = $true
        } else {
            # A single record longer than the whole tail: at least skip the
            # continuation bytes of the character the cut went through.
            while ($start -lt 3 -and $start -lt $bytes.Length -and ($bytes[$start] -band 0xC0) -eq 0x80) { $start++ }
        }
    }

    # UTF-16. Strict UTF-8 decoding would throw on this and the GBK fallback
    # would turn the whole file into mojibake, which then looks like an encoding
    # bug in the agent rather than in this reader. Note that this path still goes
    # through the maxLines cut below - a UTF-16 file is exactly as likely to be a
    # 50 MB log as a UTF-8 one.
    $text = $null
    if ($utf16 -eq 'le') {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes, 0, $bytes.Length)
    } elseif ($utf16 -eq 'be') {
        $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 0, $bytes.Length)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    } else {
        if ($start -eq 0 -and $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $start = 3 }
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        try {
            $text = $strict.GetString($bytes, $start, $bytes.Length - $start)
        } catch {
            try {
                # GetEncoding(936) throws on PowerShell 6+ / .NET Core unless the
                # code-page provider is registered first (Windows PowerShell 5.1
                # has it built in, and has no CodePagesEncodingProvider at all -
                # hence the separate try around the registration itself).
                try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }
                $text = [System.Text.Encoding]::GetEncoding(936).GetString($bytes, $start, $bytes.Length - $start)
            } catch {
                return "<undecodable: $($_.Exception.GetType().Name)>"
            }
        }
    }
    if ($tailOnly) {
        if (-not $cutMidLine -and $utf16 -ne 'none') {
            # UTF-16 was cut on a code-unit boundary, not a line boundary: drop
            # the half record that precedes the first newline.
            $nl = $text.IndexOf("`n")
            if ($nl -ge 0) { $text = $text.Substring($nl + 1) }
        }
        # The marker goes in AFTER the line cut. Prepending it first meant it was
        # the very line thrown away by the last callers, who ask for the last N
        # lines - the note was invisible exactly where it mattered.
        if ($maxLines -gt 0) {
            $lines = $text -split "`r?`n"
            if ($lines.Count -gt $maxLines) {
                $lines = $lines[($lines.Count - $maxLines)..($lines.Count - 1)]
            }
            $text = ($lines -join "`r`n")
        }
        return ("[tail of $([math]::Round($len / 1MB, 1)) MB file, last 8 MB only]`r`n" + $text)
    }
    if ($maxLines -gt 0) {
        $lines = $text -split "`r?`n"
        if ($lines.Count -gt $maxLines) {
            $lines = $lines[($lines.Count - $maxLines)..($lines.Count - 1)]
        }
        return ($lines -join "`r`n")
    }
    return $text
}

# Get-ChildItem -Recurse follows directory junctions under PowerShell 5.1, so a
# link inside the tree being scanned can pull files from an unrelated folder into
# the report - and a link loop walks forever. This walks the tree by hand and
# refuses to descend into reparse points. Depth counts from the root, like -Depth.
function Find-Files($root, $patterns, $maxDepth) {
    $out = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    if (-not $root -or -not [System.IO.Directory]::Exists($root)) { return $out }
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($root, 0))
    while ($stack.Count -gt 0) {
        $frame = $stack.Pop()
        $dir = [string]$frame[0]
        $lvl = [int]$frame[1]
        try {
            foreach ($fp in [System.IO.Directory]::GetFiles($dir)) {
                $leaf = [System.IO.Path]::GetFileName($fp)
                foreach ($pat in $patterns) {
                    if ($leaf -like $pat) {
                        try { $out.Add((New-Object System.IO.FileInfo($fp))) } catch { }
                        break
                    }
                }
            }
        } catch { }
        if ($lvl -ge $maxDepth) { continue }
        try {
            foreach ($sub in [System.IO.Directory]::GetDirectories($dir)) {
                try {
                    $di = New-Object System.IO.DirectoryInfo($sub)
                    if ($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push(@($sub, $lvl + 1))
                } catch { }
            }
        } catch { }
    }
    return $out
}

# The .bat's way in. It prefers the environment variable: "echo %SYMPTOM% > file"
# inside cmd.exe breaks the moment the typed text contains & | < > ^ %, and the
# answers to "what did you see on screen" are exactly that kind of text.
if ([string]::IsNullOrWhiteSpace($Symptom) -and -not [string]::IsNullOrWhiteSpace($env:DSH_RESCUE_SYMPTOM)) {
    $Symptom = $env:DSH_RESCUE_SYMPTOM.Trim()
}
# -SymptomFile stays supported for callers that hand the kit a text file instead.
if ([string]::IsNullOrWhiteSpace($Symptom) -and $SymptomFile -and (Test-Path -LiteralPath $SymptomFile)) {
    try {
        # Whole file, then the first non-blank line: such a file usually ends
        # with a newline, and cutting to "last 1 line" would return that blank.
        $sfRaw = [string](Read-TextAuto $SymptomFile 0)
        if ($sfRaw -notmatch '^<un(decodable|readable):') {
            $sf = @($sfRaw -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 1
            if ($sf) { $Symptom = ([string]$sf).Trim() }
        }
    } catch { }
}

# Ask for the symptom here, in PowerShell, not in the .bat: cmd.exe's
# "set /p" plus "chcp 65001" does not round-trip non-ASCII text reliably
# (that is how the whole answer turned into U+FFFD on one review box), while
# Read-Host is Unicode-native. Skipped when stdin is redirected so scripts
# and automated runs never block on a prompt.
if ([string]::IsNullOrWhiteSpace($Symptom) -and -not [Console]::IsInputRedirected) {
    try {
        Write-Output ''
        Write-Output 'What did you actually see on screen? (one line, or press Enter to skip)'
        Write-Output '屏幕上看到的是什么？（一行；直接回车跳过）'
        Write-Output '  e.g. the window went white / the chat stopped replying / it closes on start'
        Write-Output '  例：窗口白屏 / 消息发不出去 / 一启动就闪退'
        $answer = [string](Read-Host '> ')
        if (-not [string]::IsNullOrWhiteSpace($answer)) { $Symptom = $answer.Trim() }
        Write-Output ''
    } catch { }
}

# A rescue zip is meant to be shared, so never ship credentials in it.
# Command lines and log lines are the two places keys leak into by accident.
function Mask-Secrets([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return $s }

    $rules = @()

    # Machine identity first: the profile path lands in every command line, tree
    # listing and log line, so a shared kit would otherwise broadcast the user
    # name a few hundred times. Guarded: if USERPROFILE is empty the escaped
    # pattern becomes an empty string, which matches between every character and
    # would shred the whole report.
    $profile = $env:USERPROFILE
    if (-not [string]::IsNullOrWhiteSpace($profile)) {
        $rules += @{ p = ('(?i)' + [regex]::Escape($profile)); r = '%USERPROFILE%' }
    }

    $rules += @(
        # token-shaped prefixes
        @{ p = '(?i)(?<![A-Za-z0-9])sk-[A-Za-z0-9_\-]{20,}';      r = '***' },
        @{ p = '(?i)AIza[0-9A-Za-z_\-]{20,}';                      r = '***' },
        @{ p = '(?i)ark-[0-9a-fA-F\-]{20,}';                       r = '***' },
        @{ p = '(?i)gh[pousr]_[A-Za-z0-9]{20,}';                   r = '***' },
        @{ p = '(?i)github_pat_[A-Za-z0-9_]{20,}';                 r = '***' },
        @{ p = '(?i)hf_[A-Za-z0-9]{20,}';                          r = '***' },
        @{ p = '(?i)xox[baprs]-[A-Za-z0-9\-]{10,}';                r = '***' },
        @{ p = '(?i)(?<![A-Z0-9])AKIA[0-9A-Z]{16}';                r = '***' },
        # Account / access identifiers that leak through provider error bodies:
        # Moonshot prints "ak-<id>" and "org-<id>" verbatim in 429 responses.
        @{ p = '(?i)(?<![A-Za-z0-9_])ak-[A-Za-z0-9_\-]{16,}';     r = '***' },
        @{ p = '(?i)(?<![A-Za-z0-9_])org-[0-9a-f]{16,}';          r = '***' },
        @{ p = '(?i)lin_api_[A-Za-z0-9]{20,}';                    r = '***' },
        @{ p = '(?i)xai-[A-Za-z0-9_\-]{20,}';                     r = '***' },
        # JWT: header.payload.signature, all base64url
        @{ p = '(?i)eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}'; r = '***' },
        # auth headers and url userinfo
        # 20+ chars and at least one non-letter: "Bearer authentication failed"
        # is prose, not a token, and masking it would hurt the log's readability.
        @{ p = '(?i)(Bearer\s+)(?=[A-Za-z0-9._\-]*[0-9._\-])[A-Za-z0-9._\-]{20,}'; r = '$1***' },
        @{ p = '(?i)(Authorization:\s*(?:Basic|Token|Bot)\s+)\S+'; r = '$1***' },
        @{ p = '(?i)(https?://[^/\s:@]+:)[^/\s@]+(@)';             r = '$1***$2' },
        # non-http schemes carry credentials the same way
        @{ p = '(?i)((?:mongodb(?:\+srv)?|redis|amqps?|smtps?|ftps?)://[^/\s:@]+:)[^/\s@]+(@)'; r = '$1***$2' },
        # command-line flags: --password hunter2, and the --api-key=sk-... form,
        # which the whitespace-only pattern used to miss entirely
        @{ p = '(?i)((?:--|/)(?:password|passwd|secret|token|api-key)[=\s]+)[^\s]{6,}'; r = '$1***' },
        # PEM private key blocks
        @{ p = '(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----'; r = '***' },
        # key = value / "key": "value" / KEY=value
        @{ p = '(?i)((?:api[_-]?key|apikey|access[_-]?token|token|secret|client[_-]?secret|password|passwd)"?\s*[=:]\s*"?)[^"\s,;}]{6,}'; r = '$1***' },
        # ENV-style: OPENAI_API_KEY=sk-... (the name stays, the value goes)
        # Horizontal whitespace only - "\s*" could swallow a newline when the
        # value was empty, and the next line's variable NAME got eaten as if it
        # were the secret.
        @{ p = '(?i)([A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)[ \t]*[=:][ \t]*)[^\s"'']{6,}'; r = '$1***' },
        # Azure SAS: the sig= query parameter IS the credential
        @{ p = '(?i)([?&;]sig=)[A-Za-z0-9%+/=]{10,}'; r = '$1***' },
        # Slack incoming webhook: the URL itself is the credential
        @{ p = '(?i)(https://hooks\.slack\.com/(?:services|workflows)/)[A-Za-z0-9/]+'; r = '$1***' },
        # Telegram bot token: <bot id>:<35-char secret>, no prefix to key off
        @{ p = '(?<![A-Za-z0-9])[0-9]{8,10}:AA[A-Za-z0-9_\-]{30,}'; r = '***' }
    )

    # The bare user name also survives in escaped folder names
    # (--C-Users-name-.dsh-bili-duty--) and in URL paths, where the profile
    # prefix above no longer matches.
    $userName = $env:USERNAME
    if (-not [string]::IsNullOrWhiteSpace($userName)) {
        # Names like "admin", "user", "test" or "home" appear inside ordinary
        # paths and modules; masking them everywhere would rewrite the report
        # into nonsense. For those - and for very short names, which match far
        # too much - mask only the shapes a user name really takes on disk.
        $commonNames = @('admin', 'administrator', 'user', 'users', 'test', 'root', 'guest',
                         'pc', 'home', 'owner', 'desktop', 'laptop', 'dell', 'hp', 'lenovo',
                         'asus', 'acer', 'msi', 'work', 'win', 'windows', 'public', 'default')
        $isCommon = $commonNames -contains $userName.ToLower()
        if (-not $isCommon -and $userName.Length -ge 4) {
            $rules += @{ p = ('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($userName) + '(?![A-Za-z0-9])'); r = '%USERNAME%' }
        }
        if ($isCommon -or $userName.Length -lt 4) {
            $esc = [regex]::Escape($userName)
            $rules += @{ p = ('(?i)([\\/]Users[\\/]+)' + $esc + '(?=[\\/])');          r = '$1%USERNAME%' }
            $rules += @{ p = ('(?i)(--[A-Za-z]-Users-)' + $esc + '(?=-)');            r = '$1%USERNAME%' }
        }
        # 8.3 short names: TEMP often reads C:\Users\LAIYUH~1\AppData\... and that
        # leaks the first six letters of the name no other rule can catch. Scoped
        # to the Users folder so PROGRA~1 and friends stay untouched. The ~N is
        # part of the alias, not a path component: leaving it behind produced
        # C:\Users\%USERNAME%~1\AppData\... - a path that looks malformed.
        $rules += @{ p = '(?i)([\\/]Users[\\/]+)[A-Z0-9]{1,6}~[0-9](?=[\\/])'; r = '$1%USERNAME%' }
    }

    # The machine name identifies one physical PC on its own (DESKTOP-7QK2L9M
    # appears in crash reports, network listings and install logs), and the
    # user-name rules above never touch it because it is not a path component.
    # Guarded the same way: an empty pattern would shred the report.
    $computerName = $env:COMPUTERNAME
    if (-not [string]::IsNullOrWhiteSpace($computerName) -and $computerName.Length -ge 4) {
        $rules += @{ p = ('(?i)(?<![A-Za-z0-9_\-])' + [regex]::Escape($computerName) + '(?![A-Za-z0-9_\-])'); r = '%COMPUTERNAME%' }
    }

    foreach ($rule in $rules) {
        $s = [regex]::Replace($s, $rule.p, $rule.r)
    }
    return $s
}

# --- checks -----------------------------------------------------------------
# A short list of statements that can be checked without a human reading logs.
# status: ok = nothing to do; warn = works, but the evidence is thinner than it
# should be; fail = something in the installation is wrong right now.
# The list is rendered twice: as a table in index.md and as checks.json for a
# machine reader. Keeping one source means the two can never disagree.
$script:Checks = New-Object System.Collections.ArrayList

function Add-Check([string]$kind, [string]$status, [string]$detail, [string]$fixHint = '') {
    [void]$script:Checks.Add([pscustomobject][ordered]@{
        kind    = $kind
        status  = $status
        detail  = [string]$detail
        fixHint = [string]$fixHint
    })
}

# Long single-line details turn the checks table into a wall. The full text is
# still in the evidence file the check points at.
function Short([string]$s, [int]$n) {
    $s = ([string]$s) -replace "`r?`n", ' '
    if ($s.Length -gt $n) { return $s.Substring(0, $n) + '...' }
    return $s
}

# Directory sizes under a root. Skipping the heavy generated subtrees matters:
# dsh-runtimes and electron hold hundreds of MB in tens of thousands of tiny
# files, take seconds to walk, and say nothing about a crash.
function TreeOf($root, $depth, $skip) {
    if (-not (Test-Path $root)) { return "missing: $root" }
    $out = @()
    Get-ChildItem $root -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($skip -contains $_.Name) -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object {
            # DirSize, not Get-ChildItem -Recurse: a junction loop inside an
            # -ExtraDirs folder would otherwise walk forever.
            $size = DirSize $_.FullName
            $out += ("{0}`t{1:N1} MB" -f $_.FullName, ($size / 1MB))
            if ($depth -gt 1) {
                Get-ChildItem $_.FullName -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not ($skip -contains $_.Name) -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                    ForEach-Object { $out += ("  " + $_.FullName) }
            }
        }
    return ($out -join "`r`n")
}

# --- main --------------------------------------------------------------------
# Everything runs inside one try: any unexpected terminating error used to abort
# the script half-way, leaving a scratch folder behind and no zip at all.
# Now the report still gets written, with the failure recorded inside it.

$ok = $true
# Set when even the salvage package cannot be written: the scratch folder then
# stays on disk so the user can zip it by hand.
$script:KeepTmp = $false
$sections = New-Object System.Collections.ArrayList

try {

Step 'system + environment'

# --- 1. system snapshot ------------------------------------------------------

$os  = Get-CimInstance Win32_OperatingSystem
$cs  = Get-CimInstance Win32_ComputerSystem
$sys = @()
$sys += "kit_version = $KitVersion"
$sys += "time        = $CapturedAt"
$sys += "timezone    = $((Get-TimeZone).Id) / offset $((Get-TimeZone).BaseUtcOffset)"
$sys += "os          = $($os.Caption) build $($os.BuildNumber)"
$sys += "machine     = $($cs.Manufacturer) $($cs.Model)"
# Electron white screens are very often the GPU process dying, and the driver
# build is the first thing to compare once a reader has the model name.
$gpuLine = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    ForEach-Object { "$($_.Name) driver $($_.DriverVersion)" }) -join '; '
$sys += "gpu         = $(if ($gpuLine) { $gpuLine } else { '(unavailable)' })"
$sys += "user        = %USERNAME%"
$sys += "memory_gb   = $([math]::Round($cs.TotalPhysicalMemory / 1GB, 1))"
$sys += "boot_time   = $(try { ([datetime]$os.LastBootUpTime).ToString('yyyy-MM-ddTHH:mm:sszzz') } catch { '' })"
$sys += "powershell  = $($PSVersionTable.PSVersion)"
$sys += "dsh_home    = $Dsh"
$sys += "dsh_home_exists = $(Test-Path $Dsh)"

# A wrong clock breaks TLS and every API call in confusing ways, and nobody
# thinks to check it.
$sys += "utc_now     = $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"

# Agent version. The desktop app ships a runtime manifest next to its exe, and
# whether a warning is a real bug or a known limitation almost always depends on
# the build. Without the version the reader is guessing.
$hostExe = $null
foreach ($gp in @(Get-Process -ErrorAction SilentlyContinue)) {
    if ($gp.ProcessName -match '(?i)DeepSeek Harness|dsh-desktop') {
        try { if ($gp.Path) { $hostExe = $gp.Path; break } } catch { }
    }
}
$hostVer = 'unknown (agent not running, or path not readable)'
if ($hostExe) {
    $sys += "agent_exe   = $hostExe"
    $manifest = Join-Path (Split-Path $hostExe -Parent) 'resources\runtime\primary-runtime\runtime.json'
    if (Test-Path $manifest) {
        try {
            $m = Get-Content $manifest -Raw -ErrorAction Stop | ConvertFrom-Json
            $hostVer = "desktop=$($m.desktopVersion) node=$($m.node) pnpm=$($m.pnpm) python=$($m.python)"
        } catch {
            $hostVer = "manifest unreadable: $manifest"
        }
    }
}
$sys += "agent_ver   = $hostVer"
$sys += ""
$sys += "--- disks ---"
# Mapped network drives report Free slowly (and hang for seconds when the share
# is gone), so they are left out.
foreach ($d in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
    if ($null -ne $d.Free -and ($d.DisplayRoot -notmatch '^\\\\')) {
        $sys += ("{0}: free={1:N1}GB used={2:N1}GB" -f $d.Name, ($d.Free / 1GB), ($d.Used / 1GB))
    }
}
# The CLI and the desktop app are separate builds, and "works in the terminal,
# fails in the app" is usually a version mismatch. Detect the CLI version while
# the environment is still at hand; the version check compares them later.
$cliVer = ''
$cliCmd = $null
foreach ($c in @(Get-Command 'dsh' -ErrorAction SilentlyContinue)) {
    if ([string]$c.Source -match '(?i)\.ps1$') { $cliCmd = $c; break }
}
if (-not $cliCmd) { $cliCmd = Get-Command 'dsh.cmd' -ErrorAction SilentlyContinue }
if (-not $cliCmd) { $cliCmd = Get-Command 'dsh.exe' -ErrorAction SilentlyContinue }
if ($cliCmd) {
    try {
        $cliOut = @(& ([string]$cliCmd.Source) --version 2>&1 |
            ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        if ($cliOut.Count -gt 0) { $cliVer = [string]$cliOut[0] }
    } catch { }
}
if ($cliVer) { $sys += "dsh_cli     = $cliVer" } else { $sys += "dsh_cli     = (not detected)" }
Add-Text 'system.txt' (Mask-Secrets ($sys -join "`r`n"))

# Environment variables are among the most common causes of "the agent suddenly
# stopped working": a hijacked PATH prefix, a broken NODE_OPTIONS, a stray
# DSH_HOME. Names matter, values get masked and capped.
# A full dump of the environment is mostly the HOST app's business (a chat
# client's telemetry keys, its install paths), not the agent's. Record the ones
# that can actually change how DSH behaves, and report the rest as a count.
$envKeep = @('PATH','PATHEXT','NODE_OPTIONS','NODE_PATH','HTTP_PROXY','HTTPS_PROXY',
             'ALL_PROXY','NO_PROXY','LANG','LC_ALL','TZ','TEMP','TMP',
             'OS','PROCESSOR_ARCHITECTURE','APPDATA','LOCALAPPDATA',
             'HOMEDRIVE','HOMEPATH','COMSPEC')
$envLines = @()
$envOther = 0
Get-ChildItem Env: -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
    $en = [string]$_.Name
    if ($envKeep -notcontains $en -and $en -notmatch '(?i)^DSH_') { $envOther++; return }
    $v = Mask-Secrets ([string]$_.Value)
    # The machine name is masked to %COMPUTERNAME%, so writing it back as
    # "COMPUTERNAME = %COMPUTERNAME%" is a dead line that explains nothing.
    if ($en -eq 'COMPUTERNAME' -and $v -eq '%COMPUTERNAME%') { return }
    # A long value breaks at the END, not the start: a reinstall appends to PATH,
    # and a new tool lands in the tail. Keep both ends so the interesting half
    # survives - but cut on a separator (';' for PATH, '\' otherwise), so neither
    # half ends in the middle of a folder name.
    if ($v.Length -gt 300) {
        $head = $v.Substring(0, 150)
        $tailv = $v.Substring($v.Length - 150)
        # A ';' is a PATH entry boundary; only when there is none fall back to a
        # folder separator. Taking whichever sits later would cut mid-entry.
        $hj = $head.LastIndexOf(';')
        if ($hj -lt 0) { $hj = $head.LastIndexOf('\') }
        if ($hj -gt 60) { $head = $head.Substring(0, $hj) }
        # The tail likewise may only start at an entry boundary, never in the
        # middle of a folder name.
        $tj = $tailv.IndexOf(';')
        if ($tj -ge 0 -and $tj -lt 120) { $tailv = $tailv.Substring($tj + 1) }
        $v = $head.TrimEnd([char[]]@('\', ' ')) + ' ... ' + $tailv.TrimStart([char[]]@(';', ' '))
    }
    $envLines += ('{0} = {1}' -f $en, $v)
}
if ($envOther -gt 0) {
    $envLines += ''
    $envLines += "# other variables not recorded: $envOther"
}
Add-Text 'environment.txt' ($envLines -join "`r`n")

Step 'timeline'

# --- 1b. timeline: is this a fresh install or a broken one? ------------------
# A machine where <dsh> was created in the same second the agent started has no
# history at all: no crash, no old sessions, nothing to recover. Saying that out
# loud saves a reader from hunting for evidence that was never there.

$tl = @()
if (Test-Path $Dsh) {
    $dshItem = Get-Item $Dsh -Force
    $tl += "dsh_dir_created   = $($dshItem.CreationTime)"
    $tl += "dsh_dir_modified  = $($dshItem.LastWriteTime)"
} else {
    $tl += 'dsh_dir_created   = (missing)'
}
if ($hostExe) {
    # System / Idle / protected processes throw on .Path; one of them is enough to
    # kill the whole pipeline, so the property is read one process at a time.
    $hp = $null
    foreach ($gp in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { if ($gp.Path -eq $hostExe) { $hp = $gp; break } } catch { }
    }
    if ($hp) { $tl += "agent_started     = $($hp.StartTime)" }
}
$tl += ''
$tl += '--- newest 25 files under .dsh, last 48h (plugins and configs change right before a break) ---'
if (Test-Path $Dsh) {
    $since48 = (Get-Date).AddHours(-48)
    # Walking all of .dsh costs real seconds and finds nothing: dsh-runtimes alone
    # is tens of thousands of files that ship with the app and never explain a
    # break. Walk the places a user, a plugin or an update actually writes to.
    $tlSkip = @('node_modules', 'dsh-runtimes', 'electron', 'cache', 'attachments', '.git')
    $tlFiles = @(Get-ChildItem -LiteralPath $Dsh -File -Force -ErrorAction SilentlyContinue)
    foreach ($td in @(Get-ChildItem -LiteralPath $Dsh -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($tlSkip -contains $td.Name) { continue }
        $tlFiles += @(Find-Files $td.FullName @('*') 99)
    }
    $tlFiles |
        Where-Object { $_.LastWriteTime -gt $since48 -and $_.FullName -notmatch '\\node_modules\\' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 25 |
        ForEach-Object { $tl += ("{0}`t{1}`t{2:N1} KB" -f $_.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:sszzz'), $_.FullName, ($_.Length / 1KB)) }
}
Add-Text 'timeline.txt' (Mask-Secrets ($tl -join "`r`n"))

Step 'processes'

# --- 2. running processes ----------------------------------------------------

$procs_all = Get-CimInstance Win32_Process
if ($Minimal) {
    # Only what could plausibly be part of the agent's process family.
    $procs_all = @($procs_all | Where-Object {
        $_.CommandLine -and ($_.CommandLine -match '(?i)dsh|deepseek|electron|cordis')
    })
}
$liveMap = @{}
foreach ($lp in @(Get-Process -ErrorAction SilentlyContinue)) {
    try {
        $liveMap[[int]$lp.Id] = @{
            Responding = $lp.Responding
            WsMB       = [math]::Round($lp.WorkingSet64 / 1MB, 1)
        }
    } catch { }
}
$procs = @($procs_all) | Select-Object Name, ProcessId, ParentProcessId, CreationDate, CommandLine |
         Sort-Object Name
# A renderer stuck at Responding=False with a multi-GB working set is the whole
# diagnosis in one row; without these two columns the reader sees only a list of
# names and has to guess.
$procLines = @((('name','pid','ppid','created','responding','wsMB','commandline') -join "`t"))
foreach ($p in $procs) {
    $live = $liveMap[[int]$p.ProcessId]
    $resp = if ($live) { $live.Responding } else { '' }
    $ws   = if ($live) { $live.WsMB } else { '' }
    # A command line with embedded CR/LF or tabs would split one process into
    # several physical TSV rows and silently corrupt every following column.
    $cmd  = if ($p.CommandLine) { ((Mask-Secrets $p.CommandLine) -replace "`r?`n", ' ') -replace "`t", ' ' } else { '' }
    $procLines += ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $p.Name, $p.ProcessId, $p.ParentProcessId, $p.CreationDate, $resp, $ws, $cmd)
}
Add-Text 'processes.tsv' ($procLines -join "`r`n")

Step 'process tree'

# --- 2b. process tree under the agent ---------------------------------------
# A flat process list cannot answer "did that plugin actually load". The ppid
# chain can: a helper exe whose parent is the desktop host and whose command
# line points into a plugin folder is proof the plugin started, even when the
# loader reports it as missing.

$dshProc = @($procs | Where-Object {
    $_.CommandLine -and ($_.CommandLine -match '(?i)dsh-desktop|DeepSeek Harness|dsh-desktop-host')
})
$byParent = @{}
foreach ($p in $procs) {
    $k = [int]$p.ParentProcessId
    if (-not $byParent.ContainsKey($k)) { $byParent[$k] = New-Object System.Collections.ArrayList }
    [void]$byParent[$k].Add($p)
}
$treeLines = New-Object System.Collections.ArrayList
# PIDs get reused, so a parent chain can loop back on itself. Without a visited
# set that is infinite recursion, not a display glitch.
function Show-Node($node, $indent, $visited) {
    $id = [int]$node.ProcessId
    if ($visited.ContainsKey($id)) { return }
    $visited[$id] = $true
    $cmd = if ($node.CommandLine) { Mask-Secrets $node.CommandLine } else { '' }
    if ($cmd.Length -gt 150) { $cmd = $cmd.Substring(0, 150) + '...' }
    [void]$script:treeLines.Add(("{0}{1} [{2}] {3}" -f $indent, $node.Name, $node.ProcessId, $cmd))
    if ($byParent.ContainsKey($id)) {
        foreach ($kid in $byParent[$id]) { Show-Node $kid ($indent + '  ') $visited }
    }
}
$rootIds = @{}
foreach ($dp in $dshProc) { $rootIds[[int]$dp.ProcessId] = $true }
foreach ($dp in $dshProc) {
    # a node whose parent is also an agent process is drawn as a child already
    if (-not $rootIds.ContainsKey([int]$dp.ParentProcessId)) { Show-Node $dp '' @{} }
}
if ($treeLines.Count -eq 0) { [void]$treeLines.Add('no agent process found at capture time') }
Add-Text 'dsh-process-tree.txt' ($treeLines -join "`r`n")

Step 'workspace tree'

# --- 3. workspace tree -------------------------------------------------------

# See TreeOf: runtimes and electron caches are enormous and diagnostic-dead.
$treeSkip = @('node_modules', 'dsh-runtimes', 'electron', 'cache', 'attachments', '.git')
Add-Text 'tree-dsh.txt' (Mask-Secrets ((TreeOf $Dsh 2 $treeSkip) -join "`r`n"))
$extraIdx = 0
foreach ($extra in $ExtraDirs) {
    # NOT derived from the folder name: -ExtraDirs D:\work\客户名 would put that
    # name in the zip listing, and the zip is meant to be shared. Numbered here,
    # with the (masked) real path written inside the file.
    $extraIdx++
    Add-Text ("tree-extra-$extraIdx.txt") ("root: " + (Mask-Secrets ([string]$extra)) + "`r`n`r`n" + (Mask-Secrets ((TreeOf $extra 2 $treeSkip) -join "`r`n")))
}

Step 'config files'

# --- 4. config files worth diffing -------------------------------------------
# Credentials (.credentials.yaml) are deliberately NOT copied.

$cfgFiles = @(
    (Join-Path $Dsh 'profiles\desktop\cordis.patch.yml'),
    (Join-Path $Dsh 'profiles\desktop\package.json'),
    (Join-Path $Dsh 'profiles\headless\cordis.patch.yml'),
    (Join-Path $Dsh 'profiles\headless\cordis.yml'),
    (Join-Path $Dsh 'guardian\state.json'),
    (Join-Path $Dsh 'guardian\startup-issues.json')
)
foreach ($f in $cfgFiles) {
    if (Test-Path $f) {
        $flat = ($f.Substring($Dsh.Length).TrimStart('\') -replace '[\\/:*?"<>|]', '_')
        # Copied through Mask-Secrets, not Copy-Item: a config can hold a
        # literal key (apiKey: sk-...) and the zip is meant to be shared.
        Add-Text $flat (Mask-Secrets (Read-TextAuto $f 0))
    }
}

# Credentials: presence and shape only, never values. Whether the agent has a
# working key at all is a legitimate question. *Which* providers it has is not -
# this file goes to strangers, and "OPENROUTER_API_KEY" alone tells them which
# vendors you pay for. So: a count, never the names.
$cred = Join-Path $Dsh '.credentials.yaml'
$credLines = @()
if (Test-Path $cred) {
    $ci = Get-Item $cred
    $credLines += "exists   = yes"
    $credLines += "modified = $($ci.LastWriteTime)"
    $credLines += "size     = $($ci.Length) bytes"
    $raw = Read-TextAuto $cred 0
    $seen = @()
    # Only names that actually carry a secret. YAML structural keys (refs,
    # records, kind, payload, version) tell a reader nothing.
    foreach ($m in [regex]::Matches($raw, '(?m)^\s{0,6}([A-Za-z0-9_\-\.]+)\s*:')) {
        $key = $m.Groups[1].Value
        if ($key -notmatch '(?i)(_KEY|_TOKEN|_SECRET|_PASSWORD|_PASSWD|^api[_-]?key$|^apikey$|^token$|^secret$)') { continue }
        if ($seen -contains $key) { continue }
        $seen += $key
    }
    $credLines += "key_count = $($seen.Count)"
    $credLines += 'keys      = (count only; provider names and values deliberately not recorded)'
} else {
    $credLines += 'exists   = no'
}
Add-Text 'credentials-meta.txt' ($credLines -join "`r`n")

Step 'reproducing config compose (dump-config)'

# --- 4b. reproduce config compose (dump-config) ------------------------------
# A host that dies while composing cordis.patch.yml never writes a crash log
# that names the line; reading the YAML ourselves only guesses. `dsh
# --dump-config` runs the real composer and prints the exact first error, which
# is the one line a reader needs. Read-only: it composes and exits.
#
# `desktop` is skipped on purpose: the Electron app owns that profile and the
# CLI refuses it with "profile is managed exclusively by the Electron
# application". The other profiles exercise the same patch parser and bundle
# resolver, so a broken patch still reproduces there.

$dumpResults = @()
# Raw stdout/stderr live OUTSIDE $Tmp: they are unmasked, and anything left in
# $Tmp is zipped verbatim. Only the masked summary goes into the report.
$dumpScratch = Join-Path $TmpRoot ('dump-' + $PID)
$dumpScratchOk = $true
try { [void][System.IO.Directory]::CreateDirectory((LongPath $dumpScratch)) } catch { $dumpScratchOk = $false; $dumpScratch = $null }
$dshCmd = $null
foreach ($c in @(Get-Command 'dsh' -ErrorAction SilentlyContinue)) {
    if ([string]$c.Source -match '(?i)\.ps1$') { $dshCmd = $c; break }
}
if (-not $dshCmd) { $dshCmd = Get-Command 'dsh.cmd' -ErrorAction SilentlyContinue }
if (-not $dshCmd) { $dshCmd = Get-Command 'dsh.exe' -ErrorAction SilentlyContinue }
$dumpProfiles = @()
$dshProfilesRoot = Join-Path $Dsh 'profiles'
if (Test-Path $dshProfilesRoot) {
    $dumpProfiles = @(Get-ChildItem $dshProfilesRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'node_modules' } | Sort-Object Name)
}

# Two capture channels. cmd.exe can swallow a child's stdout on some hosts
# (Marvis reproduced it: dsh --dump-config printed 0 bytes through cmd and a
# 407-line tree through PowerShell), so PowerShell is the primary channel and
# cmd is only a retry. Both get a hard 30s timeout and a process-tree kill.
function Stop-ProcessTree([int]$ProcId) {
    try {
        foreach ($k in @(Get-CimInstance Win32_Process -Filter ('ParentProcessId=' + $ProcId) -ErrorAction SilentlyContinue)) {
            Stop-ProcessTree ([int]$k.ProcessId)
        }
    } catch { }
    try { Stop-Process -Id $ProcId -Force -ErrorAction SilentlyContinue } catch { }
}
function Invoke-DshCompose([string]$CliPath, [string]$ProfileName, [string]$OutFile, [string]$ErrFile, [string]$Channel) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rc = -1
    $timedOut = $false
    $runnerPath = $null
    try {
        if ($Channel -eq 'powershell') {
            $psExe = Join-Path $PSHOME 'powershell.exe'
            if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'powershell.exe' }
            $cmd = "& '" + ($CliPath -replace "'", "''") + "' --profile '" + ($ProfileName -replace "'", "''") + "' --dump-config"
            $proc = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile -NoNewWindow -PassThru
        } else {
            $runnerName = 'run-' + ($ProfileName -replace '[^\w.-]', '_') + '.cmd'
            $runnerPath = Join-Path $dumpScratch $runnerName
            $runnerBody = @(
                '@echo off',
                ('call "' + $CliPath + '" --profile "' + ($ProfileName -replace '%', '%%') + '" --dump-config')
            )
            [System.IO.File]::WriteAllLines($runnerPath, [string[]]$runnerBody, (New-Object System.Text.ASCIIEncoding))
            $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/c', ('"' + $runnerPath + '"')) -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile -NoNewWindow -PassThru
        }
        if (-not $proc.WaitForExit(30000)) {
            $timedOut = $true
            try { Stop-ProcessTree ([int]$proc.Id) } catch { }
            try { [void]$proc.WaitForExit(5000) } catch { }
        }
        if (-not $timedOut) {
            try { $rc = [int]$proc.ExitCode } catch { $rc = -1 }
        }
    } catch {
        $rc = -2
    } finally {
        $sw.Stop()
        if ($runnerPath) { try { Remove-Item -LiteralPath $runnerPath -Force -ErrorAction SilentlyContinue } catch { } }
    }
    [pscustomobject]@{ rc = $rc; timedOut = $timedOut; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2); channel = $Channel }
}

if (-not $dumpScratchOk) {
    # Falling back to $Tmp would put unmasked composer output inside the zip.
    Add-Check 'config compose' 'fail' 'cannot create a scratch folder for dsh output; compose reproduction skipped' 'Check free space and permissions on the kit folder.'
} elseif (-not $dshCmd) {
    Add-Check 'config compose' 'warn' 'dsh CLI not found on PATH; active config reproduce skipped' 'Run the kit from a terminal where `dsh --version` works, or add the DSH CLI to PATH.'
} elseif ($dumpProfiles.Count -eq 0) {
    Add-Check 'config compose' 'fail' ('no profiles under ' + (Mask-Secrets $dshProfilesRoot)) 'Check DSH_HOME; the agent has never been started with this home.'
} else {
    $dumped = 0
    foreach ($pd in $dumpProfiles) {
        if ($dumped -ge 6) { break }
        if ($pd.Name -eq 'desktop') {
            Add-Check 'config compose' 'warn' 'profile desktop: not reproducible from CLI (managed by the Electron app)' 'Start the app once and read its crash log, or reproduce the same patch under another profile.'
            continue
        }
        if (-not (Test-Path (Join-Path $pd.FullName 'cordis.patch.yml')) -and -not (Test-Path (Join-Path $pd.FullName 'cordis.yml'))) {
            Add-Check 'config compose' 'warn' ('profile ' + $pd.Name + ': no cordis config, skipped') ''
            continue
        }

        $outFile = Join-Path $dumpScratch ('dump-config-' + $pd.Name + '.out')
        $errFile = Join-Path $dumpScratch ('dump-config-' + $pd.Name + '.err')
        $dshPath = [string]$dshCmd.Source
        # PowerShell first: it is the channel that returns output where cmd.exe
        # silently swallows it. cmd is retried once, only when PS came back empty.
        $capture = Invoke-DshCompose -CliPath $dshPath -ProfileName $pd.Name -OutFile $outFile -ErrFile $errFile -Channel 'powershell'
        $timedOut = $capture.timedOut
        $rc = $capture.rc
        $swTotal = $capture.seconds
        $channelUsed = 'powershell'
        $retryUsed = $false
        $psOutText = ''
        try { if (Test-Path $outFile) { if ((Get-Item $outFile).Length -lt 8MB) { $psOutText = Read-TextAuto $outFile 0 } } } catch { }
        if (-not $timedOut -and [string]::IsNullOrWhiteSpace($psOutText) -and $capture.rc -ne -2) {
            $retryUsed = $true
            $second = Invoke-DshCompose -CliPath $dshPath -ProfileName $pd.Name -OutFile $outFile -ErrFile $errFile -Channel 'cmd'
            $timedOut = $second.timedOut
            $rc = $second.rc
            $swTotal = [math]::Round($swTotal + $second.seconds, 2)
            $channelUsed = 'cmd'
        }
        $dumped++

        $outText = ''
        $errText = ''
        try { if (Test-Path $outFile) { if ((Get-Item $outFile).Length -lt 8MB) { $outText = Read-TextAuto $outFile 0 } else { $outText = '<stdout larger than 8 MB; omitted>' } } } catch { }
        try { if (Test-Path $errFile) { if ((Get-Item $errFile).Length -lt 8MB) { $errText = Read-TextAuto $errFile 0 } else { $errText = '<stderr larger than 8 MB; omitted>' } } } catch { }

        $outEmpty = [string]::IsNullOrWhiteSpace($outText)
        $outLines = @($outText -split "`r?`n" | Where-Object { $_.Trim() })
        $errLines = @($errText -split "`r?`n" | Where-Object { $_.Trim() })
        # dsh.cmd swallows node's exit code (cmd /c dsh.cmd ... reports 0 even on
        # a YAML parse error), so stderr is the authoritative signal; the exit
        # code is only a bonus. A real failure prints a line starting with
        # "Error:" / "YAMLException:"; the "throw new Error(...)" source line
        # above it is noise.
        $firstErr = ''
        foreach ($line in $errLines) {
        # `dsh:` is how the CLI prefixes its own failures. The `patch: ...` lines
        # it also emits are warnings, not fatal (e.g. a removed bundle entry), so
        # lines that carry `patch: entry ... not found` are excluded.
        $patchWarn = $line -match '(?i)\bpatch:\s+entry\b.*\bnot found\b'
        if ($line -match '^\s*(Error|YAMLException|SyntaxError|TypeError|ReferenceError|RangeError):\s' -or
            (-not $patchWarn -and $line -match '^\s*dsh:\s+(?i:.*\b(failed|error|cannot|unable|invalid|parse|not found)\b)')) {
            $firstErr = $line.Trim(); break
        }
        }
        if (-not $firstErr) {
            foreach ($line in $errLines) {
                if ($line -match '(?i)failed to parse|Cannot find module|MODULE_NOT_FOUND|Unexpected token') { $firstErr = $line.Trim(); break }
            }
        }
        $matchedErr = $firstErr
        $looksFatal = ($matchedErr -ne '') -or ($rc -ne 0)
        if (-not $looksFatal -and $errLines.Count -gt 0 -and $outLines.Count -lt 5) { $looksFatal = $true }
        if (-not $firstErr -and $errLines.Count -gt 0) { $firstErr = $errLines[0].Trim() }

        $st = 'ok'
        $detail = ''
        if ($timedOut) {
            $st = 'fail'
            $detail = 'timed out after 30s'
        } elseif ($looksFatal) {
            $st = 'fail'
            $detail = (Short $firstErr 180)
        } elseif ($errLines.Count -gt 0) {
            $st = 'warn'
            $detail = (Short $firstErr 180)
        } elseif ($outEmpty) {
            # Both channels were already tried above. An empty capture is a kit
            # limitation, not proof that the install is broken: say so instead of
            # pointing the reader at an empty dump file.
            $st = 'fail'
            $detail = 'compose output not captured (0 lines via powershell and cmd channels)'
        } else {
            $detail = ('' + $outLines.Count + ' lines composed, no warnings')
        }
        $composeHint = ''
        if ($st -ne 'ok' -and $outLines.Count -eq 0) {
            $composeHint = 'Run `dsh --profile ' + $pd.Name + ' --dump-config` in a PowerShell window by hand; if that prints a tree, this is a kit capture failure, not proof that your install is broken.'
        } elseif ($st -ne 'ok') {
            $composeHint = 'Open dump-config-' + $pd.Name + '.txt; the first error line is at the top.'
        }
        Add-Check ('profile ' + $pd.Name + ' · compose') $st $detail $composeHint

        $dumpBody = @()
        $dumpBody += 'profile    = ' + $pd.Name
        $dumpBody += 'command    = dsh --profile ' + $pd.Name + ' --dump-config'
        $dumpBody += 'cli_exe    = ' + $dshPath
        $dumpBody += 'channel    = ' + $channelUsed + $(if ($retryUsed) { ' (powershell was empty; retried via cmd)' } else { '' })
        $dumpBody += 'retry      = ' + $(if ($retryUsed) { '1 (powershell empty -> cmd)' } else { '0' })
        $dumpBody += 'exit_code  = ' + $rc
        if ($outEmpty) { $dumpBody += 'exit_note  = stdout was empty (exit code ' + $rc + '); wrapper exit codes are unreliable, read channel/stderr' }
        $dumpBody += 'timed_out  = ' + $timedOut
        $dumpBody += 'duration   = ' + $swTotal + 's'
        $dumpBody += 'stdout     = ' + $outLines.Count + ' lines'
        $dumpBody += 'stderr     = ' + $errLines.Count + ' lines'
        $dumpBody += 'first_error= ' + $firstErr
        $dumpBody += ''
        if ($errLines.Count -gt 0) {
            $dumpBody += '== stderr =='
            $dumpBody += (@($errLines | Select-Object -First 80) -join "`r`n")
            $dumpBody += ''
        }
        $dumpBody += ('== stdout (first 250 of ' + $outLines.Count + ' lines; the full tree is not needed for triage) ==')
        $dumpBody += (@($outLines | Select-Object -First 250) -join "`r`n")
        Add-Text ('dump-config-' + $pd.Name + '.txt') ($dumpBody -join "`r`n")
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue

        $dumpResults += [pscustomobject]@{
            profile = $pd.Name
            status  = $st
            rc      = $rc
            first   = $firstErr
            seconds = $swTotal
        }
    }
}

Step 'sessions + conversation tail'

# --- 5. session list + session tail ------------------------------------------

$sessBase = Join-Path $Dsh 'sessions'
$rows = @()
$sessFiles = New-Object System.Collections.ArrayList
if (Test-Path $sessBase) {
    foreach ($ws in Get-ChildItem $sessBase -Directory -ErrorAction SilentlyContinue) {
        $rows += ("[" + $ws.Name + "]")
        foreach ($sd in Get-ChildItem $ws.FullName -Directory -ErrorAction SilentlyContinue) {
            $f  = Join-Path $sd.FullName 'session.v4.jsonl.zstd'
            $sz = if (Test-Path $f) { [math]::Round((Get-Item $f).Length / 1MB, 2) } else { 0 }
            $lm = if (Test-Path $f) { (Get-Item $f).LastWriteTime } else { $null }
            $rows += ("  {0}`t{1} MB`t{2}" -f $sd.Name, $sz, $lm)
            if (Test-Path $f) { [void]$sessFiles.Add((Get-Item $f)) }
        }
    }
}
Add-Text 'sessions.txt' (Mask-Secrets ($rows -join "`r`n"))

# The session file is the ONLY recording of what the agent was doing when it
# froze: user turns, tool calls, retries. Everything else in this kit describes
# the machine around it. It is zstd-compressed, so decode it with whatever Node
# the agent itself ships - and only keep the tail, because a 10 MB session
# decoded in full would dwarf the rest of the report.
# zstd arrived in Node 22.15. A node.exe on PATH that is older answers
# "zstdDecompressSync is not a function", so every candidate is test-fired
# instead of assumed.
function Test-NodeZstd($exe) {
    if (-not $exe) { return $false }
    try {
        $r = & $exe -e "process.stdout.write(typeof require('zlib').zstdDecompressSync)" 2>$null
        return (([string]$r).Trim() -eq 'function')
    } catch { return $false }
}

function Find-Node {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($hostExe) {
        $hostRoot = Split-Path $hostExe -Parent
        $cands.Add((Join-Path $hostRoot 'resources\runtime\primary-runtime\dependencies\node\bin\node.exe'))
        $cands.Add((Join-Path $hostRoot 'resources\runtime\primary-runtime\dependencies\node\node.exe'))
        $cands.Add((Join-Path $hostRoot 'resources\runtime\primary-runtime\node.exe'))
        $cands.Add((Join-Path $hostRoot 'resources\runtime\primary-runtime\node\node.exe'))
        $cands.Add((Join-Path $hostRoot 'resources\runtime\node.exe'))
    }
    # The desktop build ships its own runtimes here, and these are the ones that
    # match the agent's own version - prefer them over whatever is on PATH.
    foreach ($rt in @(Get-ChildItem (Join-Path $Dsh 'dsh-runtimes') -Directory -ErrorAction SilentlyContinue)) {
        $cands.Add((Join-Path $rt.FullName 'dependencies\node\bin\node.exe'))
        $cands.Add((Join-Path $rt.FullName 'dependencies\node\node.exe'))
    }
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { $cands.Add($cmd.Source) }
    foreach ($c in $cands) {
        if ([string]::IsNullOrEmpty($c)) { continue }
        if (-not (Test-Path $c)) { continue }
        if (Test-NodeZstd $c) { return $c }
    }
    return $null
}

$nodeExe = Find-Node
if ($sessFiles.Count -gt 0) {
    $sessNote = @()
    $sessNote += "node used = $(if ($nodeExe) { $nodeExe } else { '(not found)' })"
    if (-not $nodeExe) {
        $sessNote += ''
        $sessNote += 'Could not find a Node runtime to decompress session.v4.jsonl.zstd.'
        $sessNote += 'The session files are listed in sessions.txt (path + size + mtime).'
        $sessNote += 'To read one, hand it to the agent itself or use:'
        $sessNote += '  node -e "const z=require(\"zlib\");console.log(z.zstdDecompressSync(require(\"fs\").readFileSync(process.argv[1])).toString(\"utf8\"))" <file>'
    } else {
        $js = @'
const fs = require('fs'), zlib = require('zlib');
const src = process.argv[2], out = process.argv[3], n = parseInt(process.argv[4] || '25', 10);
const buf = fs.readFileSync(src);

// session.v4.jsonl.zstd is a CHAIN of zstd frames - one per append - not a
// single stream. A whole-file decode stops after the first frame on some Node
// builds, which would leave us with the 196-char session header and none of the
// events. Try the whole file first (fast path), then walk frame boundaries from
// the tail until enough events are collected.
function splitEvents(s) { return s.split('\n').filter(Boolean); }

// Count the frames before decoding anything. If the file really is a chain,
// a whole-file decode may stop after the first frame; its event count can still
// be >= n, and then we would happily report the *beginning* of the file as the
// last n events.
const MAGIC = [0x28, 0xB5, 0x2F, 0xFD];
const offs = [0];
for (let i = 1; i <= buf.length - 4; i++) {
  if (buf[i] === MAGIC[0] && buf[i+1] === MAGIC[1] && buf[i+2] === MAGIC[2] && buf[i+3] === MAGIC[3]) offs.push(i);
}
offs.push(buf.length);
const frameCount = offs.length - 1;

let lines = [];
let how = 'whole-file';
try {
  lines = splitEvents(zlib.zstdDecompressSync(buf).toString('utf8'));
} catch (e) { lines = []; }

if (lines.length < n || frameCount > 1) {
  const collected = [];
  let frames = 0;
  for (let k = offs.length - 2; k >= 0 && collected.length < n; k--) {
    try {
      const seg = buf.subarray(offs[k], offs[k+1]);
      const got = splitEvents(zlib.zstdDecompressSync(seg).toString('utf8'));
      for (let j = got.length - 1; j >= 0; j--) collected.unshift(got[j]);
      frames++;
    } catch (e) { /* split fell on a false magic inside compressed data */ }
  }
  if (collected.length > lines.length) { lines = collected; how = 'frame-chain (' + frames + ' frames)'; }
}

const tail = n > 0 ? lines.slice(-n) : lines;
// One tool result can be a megabyte of JSON. Cut each event so the tail stays
// readable and the report does not balloon. Kept short on purpose: this file
// carries fragments of the user's own conversation, so it must not become a
// transcript.
const cut = tail.map(function (l) {
  // The spliced inbox event carries the persona / system prompt: big, and made
  // of the user's own words. Keep its shape, never its text.
  if (l.indexOf('agent/inbox/spliced') !== -1) {
    try {
      const o = JSON.parse(l);
      return '{"type":"agent/inbox/spliced","seq":' + o.seq + ',"data":"<omitted: ' +
             (l.length) + ' chars of persona/system text>"}';
    } catch (e) { /* not JSON after all - fall through */ }
  }
  return l.length > 600 ? l.slice(0, 600) + '...[+' + (l.length - 600) + ' chars]' : l;
});
fs.writeFileSync(out, cut.join('\n'), 'utf8');
console.log('decoded via ' + how + ': ' + lines.length + ' events, kept ' + cut.length);
'@
        # Work files go outside $Tmp: anything left inside it ends up in the zip,
        # and a decoded session tail is the largest thing in this report.
        $workDir = Join-Path $TmpRoot ('work-' + $Stamp)
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        $jsFile = Join-Path $workDir 'zstd-tail.js'
        [System.IO.File]::WriteAllText($jsFile, $js, (New-Object System.Text.UTF8Encoding($false)))

        $take = @($sessFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 2)
        $idx = 0
        foreach ($sf in $take) {
            $idx++
            $outFile = Join-Path $workDir ("sess-tail-$idx.jsonl")
            try {
                $res = & $nodeExe $jsFile $sf.FullName $outFile 25 2>&1
                if (Test-Path $outFile) {
                    $body = Mask-Secrets (Read-TextAuto $outFile 0)
                    $sessNote += ''
                    $sessNote += "== session $idx : $($sf.Directory.Parent.Name) / $($sf.Directory.Name) =="
                    $sessNote += "size    = $([math]::Round($sf.Length / 1MB, 2)) MB"
                    $sessNote += "written = $($sf.LastWriteTime)"
                    $sessNote += "tail    = last 25 events, each cut at 600 chars"
                    # Say HOW it was decoded: a silent first-frame-only decode
                    # looks exactly like a complete tail until you count events.
                    $dl = @(([string]$res -split "`r?`n") | Where-Object { $_ -match '^decoded via ' }) | Select-Object -First 1
                    if ($dl) { $sessNote += "decode  = $dl" }
                    $sessNote += ''
                    $sessNote += $body
                } else {
                    # Keep the first line only: a RemoteException stack is 400+
                    # chars of noise and leaks the folder layout into the report.
                    $first = ([string]$res -split "`r?`n")[0]
                    if ($first.Length -gt 300) { $first = $first.Substring(0, 300) + '...' }
                    $sessNote += "session $idx : decode produced no output ($first)"
                }
            } catch {
                $sessNote += "session $idx : decode failed ($($_.Exception.GetType().Name))"
            } finally {
                if (Test-Path $outFile) { Remove-Item $outFile -Force -ErrorAction SilentlyContinue }
            }
        }
        Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Add-Text 'session-tail.txt' ($sessNote -join "`r`n")
} else {
    Add-Text 'session-tail.txt' 'no session files found under <dsh>\sessions'
}

Step 'log tails'

# --- 6. log tails ------------------------------------------------------------
# Since 0.2.1-rc.3 the desktop build no longer writes <dsh>\logs at all: the file
# you find there is a leftover from an older build. What it DOES write is one
# crash log per failed host start under the electron user-data folder. Both are
# collected, and the age of the .dsh one is reported, because "the newest log is
# ten days old" is a finding, not a detail.

$logDirs  = @((Join-Path $Dsh 'logs'), (Join-Path $Dsh 'log'))
$skipDirs = @('node_modules', 'dsh-runtimes', 'electron', 'cache', 'attachments', 'storages', 'sessions', '.git', 'soul-md')

# Not every plugin writes *.log. The market keeps *.ndjson, the desktop host
# keeps *.jsonl, and those two are often the only trace of what a plugin was
# doing when the window froze.
$logExts = @('.log', '.txt', '.ndjson', '.jsonl')

# Tier 0: crash logs written by the current desktop build.
$crashLogs = @()
$appDataDir   = EnvDir 'APPDATA'
$localAppDir  = EnvDir 'LOCALAPPDATA'
$crashRoots = @()
if ($appDataDir)  { $crashRoots += (Join-Path $appDataDir  '@deepseek-ai\dsh-desktop\logs') }
if ($localAppDir) { $crashRoots += (Join-Path $localAppDir '@deepseek-ai\dsh-desktop\logs') }
$crashAll = @()
foreach ($cr in $crashRoots) {
    if (Test-Path $cr) {
        $crashAll += Get-ChildItem $cr -File -Force -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like 'crash-*' }
    }
}
$crashAll = @($crashAll | Sort-Object LastWriteTime -Descending)
# A crash log from last year explains nothing about today's freeze and would push
# last night's crash out of the four slots. Prefer the last seven days; if there
# is nothing that recent, still take the newest two so an older crash is not lost.
$crashRecent = @($crashAll | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-7) })
if ($crashRecent.Count -gt 0) {
    $crashLogs = @($crashRecent | Select-Object -First 4)
} else {
    $crashLogs = @($crashAll | Select-Object -First 2)
}

# Tier 1: the agent's own log folder. Always kept, no competition for slots.
$coreLogs = @()
foreach ($ld in $logDirs) {
    if (Test-Path $ld) {
        $coreLogs += Get-ChildItem $ld -File -Force -ErrorAction SilentlyContinue |
                     Where-Object { $_.Extension -in $logExts }
    }
}
$coreLogs = @($coreLogs | Sort-Object FullName -Unique |
              Sort-Object LastWriteTime -Descending | Select-Object -First 8)

# Tier 2: logs anywhere else in the tree (some installs keep them under
# profiles\ or guardian\). Recent only, capped, and no browser profile noise:
# LevelDB / extension state is binary, huge, and says nothing about the agent.
$logNoise = '(?i)chrome-profile|\\LevelDB\\|Extension State|Sync Data|\\Cache\\|crashpad|\\GPUCache\\|\.plugin-manager\\'
# A file whose *name* says it holds credentials is never shipped as a log. Seen
# in the wild: douyin-duty keeps its cookie jar as douyin_cookie.txt next to
# douyin_duty.log - a plain .txt was enough to pull 6 KB of live
# sessionid/passport values into a package meant to be handed to someone else.
$logSecretNames = '(?i)(^|[._\-])(cookie|cookies|credential|credentials|secret|secrets|token|tokens|passwd|password|passwords)($|[._\-])'
$otherLogs = @()
if (Test-Path $Dsh) {
    foreach ($sub in Get-ChildItem $Dsh -Directory -Force -ErrorAction SilentlyContinue) {
        if ($skipDirs -contains $sub.Name) { continue }
        $otherLogs += Find-Files $sub.FullName @('*.log', '*.txt', '*.ndjson', '*.jsonl') 4 |
                      Where-Object { $_.FullName -notmatch '\\node_modules\\' }
    }
    $otherLogs += Get-ChildItem $Dsh -File -Force -ErrorAction SilentlyContinue |
                  Where-Object { $_.Extension -in $logExts }
}
$otherLogs = @($otherLogs | Sort-Object FullName -Unique |
               Where-Object { $_.FullName -notmatch $logNoise -and ($coreLogs.FullName -notcontains $_.FullName) } |
               Sort-Object LastWriteTime -Descending | Select-Object -First 6)

# Tier 3: sibling state folders next to .dsh (.dsh-wallpaper-engine, .dsh-pet,
# ...). Some plugins keep their trace outside the agent home entirely - the
# wallpaper engine alone writes a megabyte of request/beat records there, and
# nothing under .dsh hints that it exists.
$siblingLogs = @()
$profileRoot = Split-Path -Parent $Dsh
if ($profileRoot -and (Test-Path $profileRoot)) {
    $dshLeaf = Split-Path $Dsh -Leaf
    foreach ($sib in Get-ChildItem $profileRoot -Directory -Force -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like ($dshLeaf + '-*') }) {
        $siblingLogs += Find-Files $sib.FullName @('*.log', '*.txt', '*.ndjson', '*.jsonl') 3 |
                        Where-Object { $_.FullName -notmatch '\\node_modules\\' }
    }
}
$siblingLogs = @($siblingLogs | Sort-Object FullName -Unique |
                 Where-Object { $_.FullName -notmatch $logNoise } |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 4)

$logCandidates = @($crashLogs) + @($coreLogs) + @($otherLogs) + @($siblingLogs)
$logSecretSkipped = @($logCandidates | Where-Object { $_.Name -match $logSecretNames }).Count
$logFiles = @($logCandidates | Where-Object { $_.Name -notmatch $logSecretNames })

$found = 0
$logFresh = '(none)'
$logFreshTime = [datetime]::MinValue
foreach ($lf in $logFiles) {
    $tail = Mask-Secrets (Read-TextAuto $lf.FullName 300)
    # Keep enough of the path to tell the files apart, but drop the profile
    # prefix: a kit meant to be shared should not carry the user name.
    $relPath = $lf.FullName
    # StartsWith($null) throws ArgumentNullException, and USERPROFILE is legitimately
    # empty in some service accounts. TrimStart under an empty profile is a no-op.
    $profilePath = $env:USERPROFILE
    if (-not [string]::IsNullOrEmpty($profilePath) -and $relPath.StartsWith($profilePath, [StringComparison]::OrdinalIgnoreCase)) {
        $relPath = '~' + $relPath.Substring($profilePath.Length)
    }
    # The entry NAME never goes through Mask-Secrets on its own: Add-Text masks
    # the body and nothing else. A DSH_HOME outside the user profile
    # (D:\work\laowang\.dsh) or an -ExtraDirs folder would otherwise put a user
    # or client name straight into the zip listing - the first thing a reader
    # looks at. Mask before flattening, because the rules match on separators.
    # Parenthesised on purpose: as a bare argument PowerShell 5.1 quietly binds
    # -ErrorAction into the parameter list, while PS 7 throws a binding error and
    # leaves $relPath unmasked - a user name in the zip listing.
    $relPath = (Mask-Secrets $relPath)
    $flat = ($relPath -replace '[\\/:*?"<>|]', '_').TrimStart('_')
    # The crash-log path flattens to ~94 chars of which the useful part - the
    # timestamp and the process - is all at the END. Alias the known prefixes so
    # the tail survives the shortening below.
    # Known long prefixes get a short alias before any shortening: '..' in the
    # middle of a name reads like a broken path, and a 41-char name should not be
    # cut at all when a 4-char alias makes it fit.
    $logAlias = [ordered]@{
        '~_.dsh_soul-md_memory_global_topics_' = 'mem_'
        '~_.dsh_soul-md_memory_'         = 'mem_'
        '~_.dsh_soul-md_'                = 'soul_'
        '~_.dsh_profiles_desktop_ws_'    = 'ws_'
        '~_.dsh_profiles_desktop_'       = 'prof_'
        '~_.dsh_mobile-access_logs_'     = 'mobile_'
        '~_.dsh-wallpaper-engine_'       = 'wpe_'
        '~_.dsh_logs_'                   = 'logs_'
        '~_.dsh_douyin-duty_'            = 'douyin_'
        '~_.dsh_bili-duty_'              = 'bili_'
    }
    foreach ($alias in $logAlias.Keys) {
        if ($flat.StartsWith($alias, [StringComparison]::OrdinalIgnoreCase)) {
            $flat = $logAlias[$alias] + $flat.Substring($alias.Length); break
        }
    }
    $flat = $flat -replace '^~_AppData_Roaming_@deepseek-ai_dsh-desktop_logs_', 'crashlog_'
    $flat = $flat -replace '^~_AppData_Local_@deepseek-ai_dsh-desktop_logs_', 'crashlog-local_'
    # Crash logs carry a fixed shape: crash-<timestamp>-<role>.log. Rebuild the
    # leaf from those two fields so shortening can never eat the timestamp -
    # four crash logs that differ only by hash are useless for a timeline.
    if ($relPath -match '(?i)crash-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z)-(host|web-boot)\.log$') {
        $crashRole = if ($Matches[2] -eq 'web-boot') { 'web' } else { 'host' }
        $flat = 'crash_{0}_{1}.log' -f $Matches[1], $crashRole
    }
    # A flattened path is one long segment, and the zip writer resolves paths the
    # short way, so \\?\ does not save us at packaging time. Keep every leaf name
    # short enough that a kit unpacked into a deep folder still zips - keeping
    # BOTH ends, because a name that is all prefix noise identifies nothing.
    if ($flat.Length -gt 40) {
        $ext  = [System.IO.Path]::GetExtension($flat)
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($flat)
        if ($stem.Length -gt 28) {
            $head  = $stem.Substring(0, 10)
            $tailp = $stem.Substring($stem.Length - 14)
            $stem  = '{0}_{1}' -f $head, $tailp
        }
        $sha  = [System.Security.Cryptography.SHA1]::Create()
        $hash = [System.BitConverter]::ToString(
            $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($flat))
        ).Replace('-', '').Substring(0, 6).ToLowerInvariant()
        $sha.Dispose()
        $flat = '{0}-{1}{2}' -f $stem, $hash, $ext
    }
    Add-Text (Join-Path 'logs' $flat) $tail
    if ($found -eq 0 -or $lf.LastWriteTime -gt $logFreshTime) {
        $logFresh = $lf.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        $logFreshTime = $lf.LastWriteTime
    }
    $found++
}
if ($found -eq 0) {
    $crashHint = if ($appDataDir) { (Join-Path $appDataDir '@deepseek-ai\dsh-desktop\logs') } else { '%APPDATA%\@deepseek-ai\dsh-desktop\logs (APPDATA not set in this context)' }
    Add-Text 'logs\_no-logs-found.txt' ("No *.log / *.txt / *.ndjson / *.jsonl found under:`r`n  {0}`r`n  {1}`r`n  {2}`r`n`r`nSkipped these subfolders: {3}`r`n`r`nNOTE: 0.2.1-rc.3 and later do not write <dsh>\logs while running. If the folder is`r`nmissing entirely, that is expected, not a fault of this kit. Crash logs live in`r`n  {4}`r`nand are collected first when present." -f $Dsh, $profileRoot, (Join-Path $Dsh 'logs'), ($skipDirs -join ', '), $crashHint)
}

# Crash dumps: the files themselves are hundreds of MB, but the list answers
# "did it actually crash" without shipping them. Group by process: a dump from
# adb.exe says nothing about DSH and used to inflate the "DSH crashed" warning.
$dumpLines = @()
$dumpRoots = @()
$dumpEntries = @()
if ($localAppDir) { $dumpRoots += (Join-Path $localAppDir 'CrashDumps') }
if ($appDataDir)  { $dumpRoots += (Join-Path $appDataDir  '@deepseek-ai\dsh-desktop\Crashpad\reports') }
foreach ($dr in $dumpRoots) {
    # Dumps under DSH's own Crashpad root are DSH crashes even when Crashpad
    # names the file after its report UUID instead of the executable.
    $isDshRoot = ($dr -like '*dsh-desktop\Crashpad*')
    if (Test-Path $dr) {
        $dumpLines += "[$dr]"
        $items = @(Find-Files $dr @('*') 99 | Sort-Object LastWriteTime -Descending | Select-Object -First 30)
        if ($items.Count -eq 0) { $dumpLines += '  (no dump files)' }
        foreach ($it in $items) {
            $procName = if ($it.Name -match '(?i)^(.+?\.exe)\.') { $Matches[1] } else { ($it.Name -split '\.')[0] }
            if ($isDshRoot) { $procName = 'dsh' }
            $dumpLines += ("  {0}`t{1:N1} MB`t{2}`t{3}" -f $it.Name, ($it.Length / 1MB), $it.LastWriteTime, $procName)
            $dumpEntries += [pscustomobject]@{ Process = $procName; Time = $it.LastWriteTime; Name = $it.Name }
        }
    } else {
        $dumpLines += "[$dr] (missing)"
    }
}
$dshRelatedDumps = @($dumpEntries | Where-Object { $_.Process -match '(?i)^(dsh|deepseek|electron|node)(\.|$)' })
$otherDumps = @($dumpEntries | Where-Object { $_.Process -notmatch '(?i)^(dsh|deepseek|electron|node)(\.|$)' })
$dumpLines += ''
$dumpLines += ('DSH-related dumps: {0}' -f $dshRelatedDumps.Count)
if ($otherDumps.Count -gt 0) {
    $otherNames = @($otherDumps | Group-Object Process | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count })
    $dumpLines += ('Unrelated dumps (not counted as DSH): ' + ($otherNames -join ', '))
}
if ($dumpLines.Count -eq 0) { $dumpLines = @('no crash dump directories found') }
Add-Text 'crash-dumps.txt' ($dumpLines -join "`r`n")

Step 'network'

# --- 6b. network -------------------------------------------------------------
# A surprising share of "the agent froze" is DNS, a stale proxy, or an IP
# address conflict: the request leaves, nothing comes back, and the UI spins.
# None of that shows up in any log the agent writes, so ask the OS directly.

$net = @()
$net += '--- proxy ---'
try {
    $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    $net += "ProxyEnable    = $($ie.ProxyEnable)"
    $net += "ProxyServer    = $($ie.ProxyServer)"
    $net += "AutoConfigURL  = $($ie.AutoConfigURL)"
} catch {
    $net += "registry read failed: $($_.Exception.Message)"
}
$net += "HTTP_PROXY     = $($env:HTTP_PROXY)"
$net += "HTTPS_PROXY    = $($env:HTTPS_PROXY)"
$net += "ALL_PROXY      = $($env:ALL_PROXY)"
$net += "NO_PROXY       = $($env:NO_PROXY)"
$net += ''
$net += '--- interfaces ---'
foreach ($ni in Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
    $ips = ($ni.IPv4Address.IPAddress -join ', ')
    if (-not $ips) { $ips = '(none)' }
    $gw  = ($ni.IPv4DefaultGateway.NextHop -join ', ')
    if (-not $gw) { $gw = '-' }
    # Only the OUI: the first three octets say "which vendor", the last three
    # identify one specific machine and are used to track a laptop across networks.
    $mac = [string]$ni.NetAdapter.MacAddress
    if ($mac -match '^((?:[0-9A-Fa-f]{2}[:-]){2}[0-9A-Fa-f]{2})') { $mac = $Matches[1] + ':xx:xx:xx' }
    if (-not $mac) { $mac = '-' }
    $net += ("{0}  ip={1}  gw={2}  mac={3}" -f $ni.InterfaceAlias, $ips, $gw, $mac)
}
$net += ''
$net += '--- listening ports ---'
$net += 'Most of these belong to unrelated apps (chat clients, games, antivirus,'
$net += 'tunnels). Only two kinds matter here: the port your plugin configures, and'
$net += 'nothing listening on it at all.'
$portRows = @()
$portSource = 'Get-NetTCPConnection'
try { $portRows = @(Get-NetTCPConnection -State Listen -ErrorAction Stop) } catch { }
if ($portRows.Count -eq 0) {
    # Low-integrity collector: the cmdlet is denied, but the .NET listener API
    # sometimes still answers. If neither works we say so instead of printing an
    # empty table that reads as "nothing is listening".
    $portSource = 'IPGlobalProperties fallback'
    try {
        $portRows = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
            ForEach-Object { [pscustomobject]@{ LocalAddress = $_.Address.ToString(); LocalPort = $_.Port; OwningProcess = 0 } })
    } catch { }
}
# The DSH host listens on a LAN address and its command line carries no port,
# so pid matching beats guessing a port and probing it.
$dshPids = @($dshProc | ForEach-Object { [int]$_.ProcessId })
foreach ($r in ($portRows | Sort-Object LocalPort)) {
    $pname = ''
    if ($r.OwningProcess -gt 0) {
        try { $pname = (Get-Process -Id $r.OwningProcess -ErrorAction Stop).ProcessName } catch { }
    }
    $tag = if ($dshPids -contains [int]$r.OwningProcess) { '  [dsh]' } else { '' }
    $net += ("  {0}:{1}  pid={2}  {3}{4}" -f $r.LocalAddress, $r.LocalPort, $r.OwningProcess, $pname, $tag)
}
if ($portSource -ne 'Get-NetTCPConnection') {
    $net += ''
    $net += "  [note] listener table came from $portSource, so pid and name may be blank."
    $net += '  The collector likely runs at low integrity; treat this list as'
    $net += '  incomplete, not as "nothing is listening".'
} elseif ($portRows.Count -lt 5) {
    $net += ''
    $net += "  [note] only $($portRows.Count) listener(s) visible - the table may be filtered."
}
# DSH's own HTTP port is the one a reader actually needs, and it is often
# missing from a filtered table. Probe candidates taken from the agent's own
# command line instead of trusting the listener list.
$portHints = @()
foreach ($p in $dshProc) {
    if ($p.CommandLine -and ($p.CommandLine -match '(?i)--port[= ](\d{2,5})')) { $portHints += $Matches[1] }
    if ($p.CommandLine -and ($p.CommandLine -match '(?i)127\.0\.0\.1:(\d{2,5})')) { $portHints += $Matches[1] }
}
$portHints = @($portHints | Sort-Object -Unique)
foreach ($h in $portHints) {
    # Deliberately NOT $ok: that is the run's success flag, and a closed port on
    # a frozen host (exactly the case this kit exists for) used to flip it to
    # false and exit 1 - after the zip had already been written successfully.
    $probeOk = $false
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $probeOk = $c.ConnectAsync('127.0.0.1', [int]$h).Wait(400)
        $c.Close()
    } catch { }
    $verdict = if ($probeOk) { 'open' } else { 'closed' }
    $net += ("  [dsh] 127.0.0.1:{0}  probe={1}" -f $h, $verdict)
}
$net += ''
$net += '--- DNS servers ---'
foreach ($d in Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.ServerAddresses.Count -gt 0 }) {
    $net += ("  {0}: {1}" -f $d.InterfaceAlias, ($d.ServerAddresses -join ', '))
}
Add-Text 'network.txt' (Mask-Secrets ($net -join "`r`n"))

Step 'Windows event log'

# --- 7. recent Windows application errors ------------------------------------

$since = (Get-Date).AddHours(-24)
$ev = @()
$evErrors = @()
# Fetch more than we keep: filtering happens afterwards, and on a noisy machine
# the first 120 events are all Defender.
# -ErrorAction Stop + a per-query catch, on purpose: with SilentlyContinue an
# ACCESS DENIED log and a clean log both produce zero events, and the report then
# says "no errors" when it means "could not look".
try {
    $ev += Get-WinEvent -FilterHashtable @{LogName = 'Application'; Level = 1, 2; StartTime = $since } -MaxEvents 400 -ErrorAction Stop |
           Select-Object TimeCreated, LogName, ProviderName, Id, Message
} catch {
    # NoMatchingEventsFound is not a failure: it means "no such event in range".
    if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') {
        $evErrors += ('Application: ' + $_.Exception.GetType().Name + ' - ' + $_.Exception.Message)
    }
}
# Application Hang (1002) is level 3 on most builds, so it is pulled separately
# rather than opening the door to every Defender warning in existence.
try {
    $ev += Get-WinEvent -FilterHashtable @{LogName = 'Application'; Id = 1002; StartTime = $since } -MaxEvents 40 -ErrorAction Stop |
           Select-Object TimeCreated, LogName, ProviderName, Id, Message
} catch {
    if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') {
        $evErrors += ('Application hang: ' + $_.Exception.GetType().Name)
    }
}
# System too: a crashed service or a driver reset leaves its trace there and
# Application says nothing about it. But TPM / DCOM / PnP chatter drowns the
# signal, so those providers are dropped.
$sysNoise = '(?i)TPM-WMI|DistributedCOM|Kernel-PnP|Kernel-Boot|Kernel-Processor-Power|DriverFrameworks|Service Control Manager'
try {
    $ev += Get-WinEvent -FilterHashtable @{LogName = 'System'; Level = 1, 2; StartTime = $since } -MaxEvents 400 -ErrorAction Stop |
           Where-Object { $_.ProviderName -notmatch $sysNoise } |
           Select-Object TimeCreated, LogName, ProviderName, Id, Message
} catch {
    if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') {
        $evErrors += ('System: ' + $_.Exception.GetType().Name)
    }
}
# The same driver error can fire twenty times in one second and bury everything
# else. Collapse repeats from the same minute/provider/id into one line with a
# count, so the reader sees the shape of the traffic, not the flood.
$ev = @($ev | Where-Object { $null -ne $_.TimeCreated })
$evLines = @($ev |
    Group-Object { '{0:yyyy-MM-dd HH:mm}|{1}|{2}' -f $_.TimeCreated, $_.ProviderName, $_.Id } |
    Sort-Object { $_.Group[0].TimeCreated } -Descending |
    ForEach-Object {
        $f = $_.Group[0]
        # One Windows error message can be a few KB of stack text. Flatten the
        # newlines and cap it: the first 500 chars carry the failure, the rest
        # just makes the file unreadable.
        $msg = ($f.Message -replace "`r?`n", ' ' -replace "`t", ' ')
        if ($msg.Length -gt 500) { $msg = $msg.Substring(0, 500) + '...' }
        $line = "{0}`t{1}`t{2}`t{3}`t{4}" -f $f.TimeCreated, $f.LogName, $f.ProviderName, $f.Id, $msg
        if ($_.Count -gt 1) { $line += "  (x$($_.Count) in that minute)" }
        $line
    })
$evHead = @(
    '# Windows event log errors, last 24h (Application + System)',
    '# columns: time, channel, provider, id, message (TAB separated)',
    '# "(xN in that minute)" = N repeats of the same provider/id in that minute.'
)
if ($evErrors.Count -gt 0) {
    $evHead += ('# NOTE: {0} query/queries could not be read ({1}). "No matching events" below may mean "could not look", not "clean".' -f $evErrors.Count, ($evErrors -join '; '))
}
if ($evLines.Count -eq 0) {
    $emptyNote = if ($evErrors.Count -gt 0) { '# (nothing returned, but see the NOTE above - access may be denied)' } else { '# (no matching error events in the last 24h)' }
    $evLines = @($emptyNote)
}
Add-Text 'recent-errors.txt' (Mask-Secrets (($evHead + $evLines) -join "`r`n"))

# --- 8. memory (opt-in) ------------------------------------------------------

if ($IncludeMemory) {
    $memDir  = Join-Path $Dsh 'soul-md\memory'
    $memCore = Join-Path $memDir 'global\core.md'
    $memOld  = Join-Path $memDir 'global.md'
    $memLines = @()
    if (Test-Path $memCore) {
        $memLines += '== core.md (always injected) =='
        $memLines += (Read-TextAuto $memCore 0)
        $memLines += ''
    }
    if (Test-Path $memOld) {
        $memLines += '== global.md (legacy archive, first 40 lines) =='
        $memLines += (Read-TextAuto $memOld 40)
    }
    if ($memLines.Count -gt 0) {
        Add-Text 'memory-head.txt' (Mask-Secrets ($memLines -join "`r`n"))
    }
}

# --- 8b. checks: the machine-checkable part of the report --------------------
# Everything below answers one question without reading a log: is this install
# internally consistent? These are the same checks a maintainer runs by hand
# first: does the bundle list resolve, do the link: dependencies still exist,
# does the real composer accept the patch, is there room on disk.

$profileDirs = @()
if (Test-Path $dshProfilesRoot) {
    $profileDirs = @(Get-ChildItem $dshProfilesRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'node_modules' } | Sort-Object Name)
}

# --- post-write credential sweep --------------------------------------------
# The per-file masking above is best-effort by pattern. Before packaging, scan
# everything that is going into the zip once more and re-mask any remaining
# credential shape. A rescue kit that leaks a key is worse than one that misses
# a check, so this belt is not optional.
$credSweepHits = @()
$credSweepTotal = 0
$credSweepRe = '(?i)(?<![A-Za-z0-9])(sk-[A-Za-z0-9_\-]{20,}|ak-[A-Za-z0-9_\-]{16,}|org-[0-9a-f]{16,}|AIza[0-9A-Za-z_\-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|hf_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9\-]{10,}|lin_api_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,})'
try {
    foreach ($cf in @(Get-ChildItem -LiteralPath (LongPath $Tmp) -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($cf.Length -gt 8MB) { continue }
        if ($cf.Extension -notmatch '^\.(txt|json|tsv|md|log|ndjson|jsonl)$') { continue }
        $raw = Read-TextAuto $cf.FullName 0
        $mm = [regex]::Matches($raw, $credSweepRe)
        if ($mm.Count -gt 0) {
            $credSweepHits += $cf.Name
            $credSweepTotal += $mm.Count
            $maskedRaw = Mask-Secrets $raw
            [System.IO.File]::WriteAllText((LongPath $cf.FullName), $maskedRaw, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
} catch { }
if ($credSweepHits.Count -gt 0) {
    Add-Check 'credentials' 'warn' ('masked {0} credential-like string(s) again in {1} file(s) after the first pass' -f $credSweepTotal, $credSweepHits.Count) 'Treat the report as sensitive; the first masking pass missed these shapes.'
} else {
    Add-Check 'credentials' 'ok' 'post-write sweep found no credential-like strings in the packaged text files' ''
}

# 1. the basics
if ($dshProc.Count -gt 0) {
    Add-Check 'agent' 'ok' ('running (' + $dshProc.Count + ' process(es))') ''
} else {
    Add-Check 'agent' 'warn' 'not running at capture - no live evidence in this kit' 'Start DSH, reproduce the problem, and capture again while it is running.'
}
if ($hostVer -and $hostVer -notmatch '^unknown') {
    $verDetail = $hostVer
    if ($cliVer) { $verDetail += '; cli=' + $cliVer } else { $verDetail += '; cli not detected' }
    $desktopBase = if ($hostVer -match 'desktop=([0-9]+\.[0-9]+\.[0-9]+)') { $Matches[1] } else { '' }
    $cliBase = if ($cliVer -match '([0-9]+\.[0-9]+\.[0-9]+)') { $Matches[1] } else { '' }
    if ($desktopBase -and $cliBase -and $desktopBase -ne $cliBase) {
        Add-Check 'version' 'warn' $verDetail 'Desktop app and CLI are different builds; reproduce the problem in both before trusting a build-specific conclusion.'
    } elseif (-not $cliVer) {
        Add-Check 'version' 'warn' $verDetail 'The CLI version could not be read (dsh.ps1/dsh.cmd not on PATH or printed nothing); run `dsh --version` in PowerShell and compare it with the desktop build by hand.'
    } else {
        Add-Check 'version' 'ok' $verDetail ''
    }
} else {
    $cliNote = if ($cliVer) { '; cli=' + $cliVer } else { '; cli not detected' }
    Add-Check 'version' 'warn' ('agent version not detected' + $cliNote) 'The runtime manifest was not found next to the app; the version in system.txt is blank.'
}
if ($dshHomeMissing) {
    Add-Check 'dsh home' 'fail' 'DSH_HOME and USERPROFILE are both empty' 'Set DSH_HOME to the real home, or start DSH once from a normal user session.'
} elseif (Test-Path $Dsh) {
    Add-Check 'dsh home' 'ok' (Mask-Secrets $Dsh) ''
} else {
    Add-Check 'dsh home' 'fail' ('missing: ' + (Mask-Secrets $Dsh)) 'Set DSH_HOME to the real home, or start DSH once.'
}
if ($profileDirs.Count -eq 0) {
    Add-Check 'profiles' 'fail' 'no profiles found under DSH_HOME' 'Start DSH once so it creates its profile.'
} else {
    Add-Check 'profiles' 'ok' ((@($profileDirs | ForEach-Object { $_.Name })) -join ', ') ''
}

# 2. per-profile integrity
foreach ($pd in $profileDirs) {
    $pname = $pd.Name
    $pkgPath = Join-Path $pd.FullName 'package.json'

    $missing = @()
    foreach ($req in @('package.json', 'cordis.patch.yml')) {
        if (-not (Test-Path (Join-Path $pd.FullName $req))) { $missing += $req }
    }
    if ($missing.Count -gt 0) {
        Add-Check ('profile ' + $pname + ' · files') 'fail' ('missing ' + ($missing -join ', ')) 'A bootable profile always has package.json and cordis.patch.yml; restore them from a backup or a fresh profile template.'
    } else {
        Add-Check ('profile ' + $pname + ' · files') 'ok' 'package.json + cordis.patch.yml present' ''
    }

    $pkg = $null
    if (Test-Path $pkgPath) {
        try {
            $pkg = ConvertFrom-Json ([System.IO.File]::ReadAllText($pkgPath))
            Add-Check ('profile ' + $pname + ' · package.json') 'ok' 'valid JSON' ''
        } catch {
            Add-Check ('profile ' + $pname + ' · package.json') 'fail' ('not valid JSON: ' + (Short $_.Exception.Message 160)) 'Fix the JSON syntax first; every later check in this profile depends on it.'
            continue
        }
    }

    if ($pkg) {
        # Bundles are resolved by the DSH installation as well as by profile
        # node_modules, so looking only under profiles/<name>/node_modules
        # produced false FAILs on every shipped profile. The authoritative
        # answer is the compose check above: if `--dump-config` succeeds, the
        # resolver found them. Here we only report what the profile declares.
        $declared = 0
        try { if ($pkg.dsh -and $pkg.dsh.profile -and $pkg.dsh.profile.bundles) { $declared = @($pkg.dsh.profile.bundles).Count } } catch { }
        if ($declared -gt 0) {
            Add-Check ('profile ' + $pname + ' · bundles') 'ok' ($declared.ToString() + ' bundle(s) declared; resolution covered by the compose check') ''
        } else {
            Add-Check ('profile ' + $pname + ' · bundles') 'warn' 'no dsh.profile.bundles declared' 'A profile without bundles boots only the core; if that is not intentional, restore the bundles list.'
        }

        $linkDeps = @()
        try {
            if ($pkg.dependencies) {
                foreach ($dep in @($pkg.dependencies.PSObject.Properties)) {
                    if (([string]$dep.Value) -like 'link:*') { $linkDeps += $dep.Name }
                }
            }
        } catch { }
        $badLinks = @()
        foreach ($ln in $linkDeps) {
            $target = ([string]$pkg.dependencies.$ln).Substring(5)
            if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path $pd.FullName $target }
            if (-not (Test-Path $target)) { $badLinks += ($ln + ' -> ' + $target) }
        }
        if ($badLinks.Count -gt 0) {
            Add-Check ('profile ' + $pname + ' · link deps') 'fail' (Short ($badLinks -join '; ') 220) 'The plugin was moved or deleted; point the link: path at its new home, or reinstall that plugin.'
        } elseif ($linkDeps.Count -gt 0) {
            Add-Check ('profile ' + $pname + ' · link deps') 'ok' ($linkDeps.Count.ToString() + ' link: dependency target(s) exist') ''
        }
    }
}

# 3. the environment around it
# A rescue report that only looks at the drive it is written to misses the
# two that actually matter: the system drive (profiles, temp, update cache)
# and the drive holding DSH_HOME. Check all three, with a stable label.
$diskDrives = @()
$seenDisk = @{}
foreach ($dd in @(
        @{ root = $env:SystemDrive;                role = 'system' },
        @{ root = (Split-Path -Qualifier $Dsh);    role = 'DSH home' },
        @{ root = $OutDrive;                      role = 'report' })) {
    $root = [string]$dd.root
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    $root = $root.TrimEnd('\')
    if ($seenDisk.ContainsKey($root.ToLowerInvariant())) { continue }
    $seenDisk[$root.ToLowerInvariant()] = $true
    $letter = $root.Substring(0, 1)
    $freeMB = $null
    try {
        $pd2 = Get-PSDrive -Name $letter -ErrorAction Stop
        if ($null -ne $pd2.Free) { $freeMB = [int][math]::Round($pd2.Free / 1MB) }
    } catch { }
    if ($null -ne $freeMB) { $diskDrives += [pscustomobject]@{ Root = ($letter + ':'); Role = $dd.role; FreeMB = $freeMB } }
}
if ($diskDrives.Count -gt 0) {
    $low   = @($diskDrives | Where-Object { $_.FreeMB -lt 200 })
    $tight = @($diskDrives | Where-Object { $_.FreeMB -ge 200 -and $_.FreeMB -lt 10240 })
    $diskDetail = (($diskDrives | ForEach-Object { '{0} ({1}) {2} MB free' -f $_.Root, $_.Role, $_.FreeMB }) -join ', ')
    if ($low.Count -gt 0) {
        Add-Check 'disk' 'fail' $diskDetail 'Free space or move the kit folder; the collection may finish but the zip will not fit.'
    } elseif ($tight.Count -gt 0) {
        Add-Check 'disk' 'warn' $diskDetail 'Not urgent; a full drive also breaks DSH itself, so keep an eye on it.'
    } else {
        Add-Check 'disk' 'ok' $diskDetail ''
    }
}
if ($found -eq 0) {
    Add-Check 'logs' 'warn' 'no log files found' 'Expected on a fresh install; desktop builds from 0.2.1-rc.3 write crash logs under %APPDATA%\@deepseek-ai\dsh-desktop\logs instead.'
} else {
    Add-Check 'logs' 'ok' ($found.ToString() + ' file(s), newest ' + $logFresh) ''
}
$recentDshDumps = @($dshRelatedDumps | Where-Object { $_.Time -gt (Get-Date).AddHours(-48) })
$recentOtherDumps = @($otherDumps | Where-Object { $_.Time -gt (Get-Date).AddHours(-48) })
if ($recentDshDumps.Count -gt 0) {
    Add-Check 'crash dumps' 'warn' ($recentDshDumps.Count.ToString() + ' DSH-related dump(s) in the last 48h') 'A dump means a native crash is on disk; open crash-dumps.txt for paths.'
} elseif ($recentOtherDumps.Count -gt 0) {
    $otherNames = @($recentOtherDumps | Group-Object Process | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count })
    $otherTotal = $otherDumps.Count
    $otherOutside = $otherTotal - $recentOtherDumps.Count
    $otherNote = 'no DSH-named dump in the last 48h; ' + $recentOtherDumps.Count + ' unrelated in the same window (' + ($otherNames -join ', ') + '); ' + $otherTotal + ' unrelated dump(s) on disk in total'
    if ($otherOutside -gt 0) { $otherNote += ' (' + $otherOutside + ' outside the 48h window or unnamed)' }
    Add-Check 'crash dumps' 'ok' $otherNote 'crash-dumps.txt lists every dump, including ones with no process name; crash logs are separate files.'
} else {
    Add-Check 'crash dumps' 'ok' 'none in the last 48h' ''
}

# The symptom is asked in PowerShell (Read-Host) now, but a pipe or a caller can
# still hand us undecodable bytes, and an unattended run can hand us nothing at
# all. Both deserve a line in checks: a missing or mojibake symptom is worse
# than none, because the next reader cannot tell it apart from "no problem".
if ($Symptom -match [string][char]0xFFFD) {
    Add-Check 'symptom' 'warn' 'the captured symptom contains undecodable characters (U+FFFD)' 'Re-run with -Symptom "..." from PowerShell, or use the .bat, whose prompt runs in PowerShell and is Unicode-safe.'
} elseif ([string]::IsNullOrWhiteSpace($Symptom)) {
    # A user pressing Enter at the prompt and an unattended run must look the same
    # to whoever reads checks.json later, so both get a warn; only the reason differs.
    $noSymptomWhy = if ([Console]::IsInputRedirected) { 'non-interactive run' } else { 'skipped at the prompt' }
    Add-Check 'symptom' 'warn' ('no symptom was provided (' + $noSymptomWhy + ')') 'Pass -Symptom "what you saw on screen" to give the next reader the one clue that matters.'
}

# 4. machine-readable copy + counts for index.md
$checkCounts = [ordered]@{ ok = 0; warn = 0; fail = 0 }
foreach ($c in $script:Checks) {
    if ($checkCounts.Contains($c.status)) { $checkCounts[$c.status] = $checkCounts[$c.status] + 1 }
}
# Sort for the reader: failures first, then warnings, then passes. Within a
# status, group by check family (agent, version, home, profiles, compose, disk,
# logs) and keep the original order inside a family. A plain status-only sort
# used to interleave headless/desktop/web and made the PASS block look random.
$checkStatusRank = @{ fail = 0; warn = 1; ok = 2 }
$checkKindRank = @{
    'agent' = 0; 'version' = 1; 'dsh home' = 2; 'profiles' = 3
    'disk' = 8; 'logs' = 9; 'crash dumps' = 10
}
$sortedChecks = @($script:Checks | ForEach-Object -Begin { $checkIndex = 0 } -Process {
    $k = [string]$_.kind
    $kr = if ($checkKindRank.ContainsKey($k)) { $checkKindRank[$k] }
          elseif ($k -like 'profile *') { 4 }
          elseif ($k -eq 'config compose') { 5 }
          else { 7 }
    $i = $checkIndex
    $checkIndex++
    [pscustomobject]@{ Check = $_; StatusRank = $checkStatusRank[$_.status]; KindRank = $kr; Index = $i }
} | Sort-Object StatusRank, KindRank, Index | ForEach-Object { $_.Check })
$checksDoc = [ordered]@{
    kit_version = $KitVersion
    captured_at = $CapturedAt
    counts      = $checkCounts
    checks      = $sortedChecks
}
Add-Text 'checks.json' (ConvertTo-Json -InputObject $checksDoc -Depth 6)

Step 'writing index.md'

# --- 9. index: the page a reader should open first ---------------------------
# Everything above is raw evidence. This turns it into a starting point: what
# happened, was the agent even running, what looks broken, where to look next.

$status = @()
$running = if ($dshProc.Count -gt 0) { 'yes' } else { 'no' }
$status += "kit_version            = $KitVersion"
$status += "captured_at            = $CapturedAt"
$status += "packaged_at            = $((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))"
$status += "dsh_running_at_capture = $running"
$status += "dsh_process_count      = $($dshProc.Count)"
$status += "agent_version          = $hostVer"
$status += "log_files_found        = $found"
$status += "newest_log_written     = $logFresh"
$status += "log_extensions         = $($logExts -join ' ')"
$status += "skipped_subfolders     = $($skipDirs -join ', ')"
$status += "skipped_secret_named_logs = $logSecretSkipped"
if ($running -eq 'no') {
    $status += ''
    $status += 'DSH was NOT running when this kit was captured.'
    $status += 'So this kit describes the installation (configs, plugin state, disk'
    $status += 'layout) but cannot show what the live process was doing.'
    $status += 'If you need the crash itself, capture while it is still running,'
    $status += 'or read recent-errors.txt and the log files for the last session.'
}
Add-Text 'dsh-status.txt' ($status -join "`r`n")

# Auto-triage: scan what we collected for the handful of strings that mean
# something, and group them. Cheap, and it is what a reader does first anyway.
$hits = @{}
# Numbers alone are the main source of false positives: a UUID contains 401,
# "592.3 MB" contains 592, a listening port is a 5-digit number. The numeric
# patterns therefore require HTTP context, and the inventories below are skipped
# entirely - they list paths, sizes and ports, not error text.
$patterns = [ordered]@{
    'out of memory'  = '(?i)out of memory|heap out of memory|ENOMEM|内存不足|内存溢出'
    'port in use'    = '(?i)EADDRINUSE|address already in use|端口.{0,4}(被)?占用'
    'connection'     = '(?i)ECONNRESET|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|socket hang up|连接(被重置|失败|超时|中断)'
    'auth'           = '(?i)unauthorized|invalid api key|invalid_token|authentication (failed|error)|(?:status|code|http)\s*[=:]?\s*(?<![-0-9])(?:401|403)\b|(认证|鉴权|授权)失败|无效.{0,4}(密钥|token|凭证)'
    'rate limit'     = '(?i)rate limit|too many requests|(?:status|code|http)\s*[=:]?\s*(?<![-0-9])429\b|频率限制|请求(过于)?频繁'
    'server error'   = '(?i)internal server error|bad gateway|service unavailable|(?:status|code|http)\s*[=:]?\s*(?<![-0-9])5\d\d\b|服务器(内部)?错误|服务(暂时)?不可用|网关(错误|超时)'
    'context window' = '(?i)context.{0,12}(length|window|exceed)|CONTEXT_WINDOW_EXCEEDED|too many tokens|上下文.{0,8}(超|过长|上限|溢出)'
    'timeout'        = '(?i)timeout|timed out|deadline exceeded|超时|未响应|没有响应'
    'module missing' = '(?i)cannot find module|MODULE_NOT_FOUND|no loader entry matched|找不到模块|模块(不存在|缺失)'
    'cors'           = '(?i)blocked by cors|access-control-allow-origin|cors (policy|error|preflight)'
    'renderer'       = '(?i)renderer (process|crash)|gpu process.{0,24}(crash|gone)|webcontents.{0,24}(crash|failed)|ERR_FAILED|Aw, Snap'
    'websocket'      = '(?i)websocket.{0,24}(error|fail|closed|disconnect)|ws[s]?://.{0,80}(ECONNREFUSED|ECONNRESET|closed)'
}
# session-tail.txt is excluded as well: it is a transcript, so it contains every
# word the user and the agent said. Scanning it turns the agent's own sentences
# ("the timeout was caused by...") into hits.
$triageSkip = @('sessions.txt', 'tree-dsh.txt', 'processes.tsv', 'network.txt', 'timeline.txt', 'system.txt', 'session-tail.txt', 'environment.txt')
$scannedFiles = 0
Get-ChildItem $Tmp -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in @('.txt', '.log', '.jsonl', '.ndjson') -and $_.Length -lt 8MB -and $triageSkip -notcontains $_.Name -and $_.Name -notlike 'dump-config-*' } |
    ForEach-Object {
        $body = Read-TextAuto $_.FullName 0
        if (-not $body) { return }
        $scannedFiles++
        foreach ($k in $patterns.Keys) {
            $ms = [regex]::Matches($body, $patterns[$k])
            if ($k -eq 'module missing' -and $ms.Count -gt 0) {
                # The plugin market writes one "level=info ... no loader entry
                # matched" line per disabled plugin. Counting those turned 62
                # harmless toggles into a "module missing" alarm; only errors
                # are worth a reader's attention.
                $ms = @($ms | Where-Object {
                    $l0 = $body.LastIndexOf("`n", [Math]::Max(0, $_.Index - 1)) + 1
                    $r0 = $body.IndexOf("`n", $_.Index)
                    if ($r0 -lt 0) { $r0 = $body.Length }
                    ($body.Substring($l0, $r0 - $l0) -notmatch '(?i)level"?\s*[=:]\s*"?info')
                })
            }
            if ($ms.Count -eq 0) { continue }
            if (-not $hits.ContainsKey($k)) { $hits[$k] = @{} }
            # Keep the first matching LINE next to the count. A count alone makes
            # the reader open the file to judge whether it is real.
            $m = $ms[0]
            $ls = $body.LastIndexOf("`n", [Math]::Max(0, $m.Index - 1))
            if ($ls -lt 0) { $ls = 0 } else { $ls = $ls + 1 }
            $le = $body.IndexOf("`n", $m.Index)
            if ($le -lt 0) { $le = $body.Length }
            $sample = $body.Substring($ls, $le - $ls).Trim()
            if ($sample.Length -gt 110) { $sample = $sample.Substring(0, 110) + '...' }
            $hits[$k][$_.Name] = @{ n = $ms.Count; sample = $sample }
        }
    }

# Threshold warnings: the boring failures that look like agent bugs.
$warn = @()
if ($null -ne $outFreeMB -and $outFreeMB -lt 200) {
    $warn += ("only {0} MB free on {1} (the drive that holds the report) - the zip may not fit" -f $outFreeMB, $OutDrive)
}
if (-not $os -or -not $cs) {
    # Inside a restricted sandbox every CIM call comes back empty. Saying so is
    # the difference between "your machine is broken" and "this report is thin".
    $warn += 'CIM/WMI queries returned nothing - the system section is incomplete (restricted environment?)'
}
$seenVol = @{}
foreach ($d in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
    if ($null -ne $d.Free -and ($d.DisplayRoot -notmatch '^\\\\') -and $d.Used -gt 0) {
        # subst drives and mapped duplicates report the same volume; warn once.
        $volKey = '{0}|{1}' -f $d.Used, $d.Free
        if ($seenVol.ContainsKey($volKey)) { continue }
        $seenVol[$volKey] = $true
        $freeGB = $d.Free / 1GB
        if ($freeGB -lt 10) { $warn += ("disk {0}: only {1:N1} GB free" -f $d.Name, $freeGB) }
    }
}
$osm = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($osm) {
    $freeRamGB = $osm.FreePhysicalMemory / 1MB
    if ($freeRamGB -lt 2) { $warn += ("only {0:N1} GB of RAM free" -f $freeRamGB) }
}
$notResp = @($procs | Where-Object {
    $lv = $liveMap[[int]$_.ProcessId]
    $lv -and $lv.Responding -eq $false
})
foreach ($nr in $notResp) { $warn += ("process not responding: {0} (pid {1}, {2} MB)" -f $nr.Name, $nr.ProcessId, $liveMap[[int]$nr.ProcessId].WsMB) }
if ($recentDshDumps.Count -gt 0) { $warn += ("{0} DSH-related crash dump(s) in the last 48h (%LOCALAPPDATA%\CrashDumps)" -f $recentDshDumps.Count) }

# Final guard: raw dsh stdout/stderr are unmasked and must never enter the zip.
# The scratch folder is outside $Tmp, but a failed cleanup or a future refactor
# must not be able to leak them silently.
$rawDump = @(Get-ChildItem $Tmp -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like 'dump-config-*' -and $_.Extension -in @('.out', '.err') })
if ($rawDump.Count -gt 0) {
    foreach ($rf in $rawDump) { Remove-Item -LiteralPath $rf.FullName -Force -ErrorAction SilentlyContinue }
    $warn += ('removed ' + $rawDump.Count + ' unmasked dump file(s) from the report folder before zipping')
}

$idx = @()
$idx += '# DSH rescue report'
$idx += ''
$idx += "**Captured:** $CapturedAt  "
$idx += "**Packaged:** $((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))  "
$idx += "**Kit version:** $KitVersion  "
$idx += "**Agent:** $hostVer  "
$idx += "**Running at capture:** $running"
$idx += ''
if ($Symptom) {
    $idx += '## What the user saw'
    $idx += ''
    $idx += '> ' + ($Symptom -replace "`r?`n", ' ')
    if ($Symptom -match [string][char]0xFFFD) {
        $idx += ''
        $idx += '_Some characters could not be decoded (U+FFFD). Re-run from PowerShell with `-Symptom "..."`, or use the .bat which switches the console to UTF-8._'
    }
    $idx += ''
} else {
    # Say so explicitly. A missing section reads as "the kit forgot", an empty
    # one reads as "the user was not asked" - and the reader can act on that.
    $idx += '## What the user saw'
    $idx += ''
    $idx += '_Not provided. Re-run with `-Symptom "the exact message on screen"` to'
    $idx += 'put it here; it is the fastest way to point a reader at the right log._'
    $idx += ''
}
$idx += '## Where to look'
$idx += ''
$idx += '| file | what it answers |'
$idx += '|---|---|'
$idx += '| `dsh-status.txt` | was the agent running, which build, how many logs |'
$idx += '| `checks.json` | machine-readable PASS/WARN/FAIL checks, counts and fix hints |'
$idx += '| `dump-config-*.txt` | real composer output per profile; first error line at the top |'
$idx += '| `session-tail.txt` | what the agent was doing: last 25 events of the newest sessions |'
$idx += '| `timeline.txt` | fresh install or long history; what changed in the last 48h |'
$idx += '| `environment.txt` | PATH, proxy and TEMP as the agent actually sees them |'
$idx += '| `network.txt` | proxy, interfaces, listening ports, DNS |'
$idx += '| `recent-errors.txt` | Windows Application + System errors, last 24h |'
$idx += '| `crash-dumps.txt` | whether a dump was actually written |'
$idx += '| `processes.tsv` | every process, with responding state and working set |'
$idx += '| `dsh-process-tree.txt` | which plugins actually spawned helpers |'
$idx += '| `credentials-meta.txt` | whether a key is configured (a count only - no names, no values) |'
$idx += '| `logs/` | log tails, crash logs first |'
$idx += '| `sessions.txt` | every session folder, size and mtime |'
$idx += ''
$idx += '## Checks'
$idx += ''
$idx += 'Static checks run before packaging. PASS means nothing to do; WARN means'
$idx += 'the report is thinner than it could be; FAIL means the installation is'
$idx += 'internally inconsistent right now and the rest of the report explains it.'
$idx += ''
$idx += '| status | check | detail | fix |'
$idx += '|---|---|---|---|'
foreach ($c in $sortedChecks) {
    $label = switch ($c.status) { 'ok' { 'PASS' } 'warn' { 'WARN' } 'fail' { 'FAIL' } default { $c.status } }
    $kind = ([string]$c.kind) -replace '\|', '\|'
    $det  = ([string]$c.detail) -replace '\|', '\|'
    $fix  = if ($c.status -eq 'ok') { '' } else { ([string]$c.fixHint) -replace '\|', '\|' }
    $idx += ('| {0} | {1} | {2} | {3} |' -f $label, $kind, $det, $fix)
}
$idx += ''
$idx += ('**{0} passed, {1} warnings, {2} failures.**' -f $checkCounts.ok, $checkCounts.warn, $checkCounts.fail)
if ($checkCounts.fail -gt 0) {
    $idx += 'A FAIL row is the first thing to fix; the evidence files below explain it.'
} elseif ($checkCounts.warn -gt 0) {
    $idx += 'Warnings do not prove a bug, but part of the picture is missing.'
} else {
    $idx += 'All checks passed. If DSH still misbehaves, the cause is runtime, not installation: compare the log tails and session-tail.txt.'
}
$idx += ''
$idx += 'Machine-readable copy with the same rows: `checks.json`.'
$idx += ''
$idx += '## Automatic triage'
$idx += ''
if ($hits.Count -eq 0) {
    $idx += 'No error-looking strings found in the scanned DSH status/log files.'
$idx += 'The Windows event log is not part of this scan - see recent-errors.txt.'
} else {
    $idx += '| pattern | hits | where (count) | first matching line |'
    $idx += '|---|---|---|---|'
    foreach ($k in @($hits.Keys | Sort-Object)) {
        $files = $hits[$k]
        $total = 0
        foreach ($f in $files.Keys) { $total += $files[$f].n }
        $where = @($files.Keys | Sort-Object | ForEach-Object { "$_ ($($files[$_].n))" })
        # The sample is one line, mask-safe (Add-Text already masked everything
        # in this folder), and lets a reader dismiss a false positive instantly.
        $sample = @($files.Keys | Sort-Object | ForEach-Object { $files[$_].sample } | Where-Object { $_ } | Select-Object -First 1)
        $sampleText = if ($sample.Count -gt 0) { ($sample[0] -replace '\|', '\|') } else { '' }
        $idx += ("| {0} | {1} | {2} | {3} |" -f $k, $total, ($where -join ', '), $sampleText)
    }
}
$idx += ''
$idx += ('Scanned {0} text file(s) under the report folder. Transcripts and inventories are excluded, and `dump-config-*` is reported below instead of being pattern-scanned.' -f $scannedFiles)
$idx += ''
if ($dumpResults.Count -gt 0) {
    $idx += '### Config compose (dump-config)'
    $idx += ''
    $dumpBad = @($dumpResults | Where-Object { $_.status -ne 'ok' })
    if ($dumpBad.Count -eq 0) {
        $idx += 'Every non-desktop profile composed cleanly; the patch files parse.'
    } else {
        foreach ($r in $dumpBad) {
            $lbl = if ($r.status -eq 'fail') { 'FAIL' } else { 'WARN' }
            $firstLine = if ($r.first) { Short $r.first 200 } else { '(no stderr)' }
            $idx += ('- **' + $lbl + ' ' + $r.profile + '** (' + $r.seconds + 's): ' + $firstLine)
        }
    }
    $idx += ''
    $idx += '`desktop` is skipped: the CLI refuses it ("managed exclusively by the Electron app").'
    $idx += 'Full composer output per profile: `dump-config-<profile>.txt`; the first error line is at the top.'
    $idx += ''
}
$idx += '## Warnings'
$idx += ''
if ($warn.Count -eq 0) {
    $idx += 'Nothing crossed the usual thresholds (disk <10 GB, RAM <2 GB, an unresponsive process, a fresh dump).'
} else {
    foreach ($w in $warn) { $idx += "- $w" }
}
if ($script:WriteFailures.Count -gt 0) {
    $idx += ''
    $idx += ('**{0} file(s) could not be written and are missing from this report:**' -f $script:WriteFailures.Count)
    foreach ($f in $script:WriteFailures) { $idx += "- $f" }
}
$idx += ''
$idx += '## How to hand this over'
$idx += ''
$idx += '1. Unzip anywhere.'
$idx += '2. Give the whole folder to another AI together with one sentence:'
$idx += '   what you saw, when it started, and whether you restarted since.'
$idx += '3. If `dsh_running_at_capture = no`, say so up front: the kit then has no'
$idx += '   live evidence, only the installation state.'
$idx += ''
$idx += '## Privacy'
$idx += ''
$idx += '`credentials.yaml` is never copied. Not even its key names are printed:'
$idx += 'credentials-meta.txt reports how many are configured, nothing else.'
$idx += 'Command lines, log lines, config values and the user name are masked'
$idx += 'before they are written. The install path (the DSH_HOME prefix) is NOT'
$idx += 'masked: absolute local paths are part of the evidence and appear in the files.'
if ($credSweepHits.Count -gt 0) {
    $idx += ''
    $idx += ('**Privacy sweep:** {0} credential-like string(s) in {1} file(s) survived the first masking pass and were masked again before packaging. Still read the dumps yourself before sharing.' -f $credSweepTotal, $credSweepHits.Count)
}
$idx += ''
$idx += '**Read `session-tail.txt` yourself before handing this folder to anyone.**'
$idx += 'It answers "what was the agent doing when it hung", which means it contains'
$idx += 'short fragments of your own conversation - 25 events, each cut at 600 chars.'
$idx += 'Everything else in the report is machine state, not dialogue.'
Add-Text 'index.md' (Mask-Secrets ($idx -join "`r`n"))

# --- 10. README for whoever opens the zip -------------------------------------

$readme = @(
    'DSH rescue kit  v' + $KitVersion
    '========================='
    "generated: $((Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz'))"
    ''
    'OPEN index.md FIRST. It has the symptom, the PASS/WARN/FAIL checks, the triage'
    ''
    'What is inside:'
    '  index.md                start here: symptom, triage, warnings, file map'
    '  dsh-status.txt          was the agent running? which build? how many logs?'
    '  system.txt              OS / disks / memory / boot time / agent version'
    '  timeline.txt            .dsh creation time, agent start time, last 48h changes'
    '  session-tail.txt        last 25 events of the newest session(s) - the only'
    '                          record of what the agent was doing'
    '  network.txt             proxy, interfaces, listening ports, DNS'
    '  processes.tsv           processes with responding state and working set'
    '  dsh-process-tree.txt    process tree under the agent: which plugins spawned helpers'
    '  tree-dsh.txt            top-level .dsh folder map (2 levels, names only)'
    '  tree-extra-*.txt        extra directories, if any were requested'
    '  sessions.txt            every workspace, every session folder + size'
    '  credentials-meta.txt    whether a key exists (count only, no names, no values)'
    '  checks.json             PASS/WARN/FAIL checks: profiles, link deps, composer, disk'
    '  dump-config-*.txt       real `dsh --dump-config` output per profile; first error on top'
    '  crash-dumps.txt         dump files, if any were written'
    '  logs/                   crash logs and log tails (flattened names)'
    '  recent-errors.txt       Windows Application + System errors, last 24h'
    '  memory-head.txt         agent memory (only when -IncludeMemory was used)'
    '  config copies           cordis.patch.yml / package.json / guardian state'
    ''
    'Read dsh-status.txt FIRST. If it says dsh_running_at_capture = no, this kit'
    'has no live crash evidence, only the installation state.'
    ''
    'Note on logs: desktop builds from 0.2.1-rc.3 onward no longer write'
    '  <dsh>\logs while running. A file there is a leftover from an older build.'
    'Crash logs live in %APPDATA%\@deepseek-ai\dsh-desktop\logs and are collected'
    'first when they exist. So "log_files_found = 0" on a fresh install is'
    'expected, not a fault of this kit.'
    ''
    'How to use:'
    '  1. Unzip anywhere.'
    '  2. Give the whole folder to another AI, together with one line saying'
    '     what went wrong and when.'
    '  3. Config files are flattened, path separators replaced by "_".'
    ''
    'Privacy: credentials (.credentials.yaml) are never copied, and API-looking'
    'strings in command lines and logs are replaced with ***. The user name and'
    'profile path are replaced by %USERNAME% / %USERPROFILE%. The key list is not'
    'reproduced either: credentials-meta.txt only says how many are configured.'
    'The install path (the DSH_HOME prefix) is not masked: absolute local paths'
    'are evidence, not a leak.'
)
Add-Text 'README.txt' ($readme -join "`r`n")

Step 'packaging'

# --- 11. zip it up ------------------------------------------------------------
# Never overwrite: the most common rescue sequence is "capture while it is
# broken, restart, capture again", and both captures matter.

$zip = Join-Path $OutDir ($ZipName + '.zip')
if (Test-Path $zip) {
    $base = Join-Path $OutDir $ZipName
    $i = 2
    while (Test-Path $zip) { $zip = "$base ($i).zip"; $i++ }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
# Compress-Archive has no encoding switch; on macOS and older 7-Zip the Chinese
# file names would come out garbled. ZipFile lets us pin UTF-8.
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    (LongPath $Tmp), (LongPath $zip),
    [System.IO.Compression.CompressionLevel]::Optimal,
    $false,
    [System.Text.Encoding]::UTF8)

}
catch {
    $ok = $false
    Write-Output "FAILED: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) { Write-Output $_.ScriptStackTrace }
    # A rescue tool that loses its own evidence when it fails is the cruellest
    # failure mode there is. Salvage whatever was collected into a PARTIAL zip
    # before the scratch folder is cleaned up.
    try {
        $partial = Join-Path $OutDir ('PARTIAL-' + $ZipName + '.zip')
        $pi = 2
        while (Test-Path $partial) {
            $partial = Join-Path $OutDir ('PARTIAL-' + $ZipName + " ($pi).zip"); $pi++
        }
        # The main path would have failed with the very same call, so go entry by
        # entry here: one unreadable file must not take the other 30 down with it.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $pzip = [System.IO.Compression.ZipFile]::Open((LongPath $partial), 'Create')
        $pskip = 0
        try {
            # Length budget comes from the UNPREFIXED path: Get-ChildItem hands
            # back FullName without the \\?\ we passed in, so measuring
            # (LongPath $Tmp) here would eat four characters off every entry name.
            $pbase = $Tmp.TrimEnd('\').Length + 1
            foreach ($pf in @(Get-ChildItem -LiteralPath (LongPath $Tmp) -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                try {
                    $pfName = $pf.FullName
                    if ($pfName.StartsWith('\\?\UNC\')) { $pfName = '\\' + $pfName.Substring(8) }
                    elseif ($pfName.StartsWith('\\?\')) { $pfName = $pfName.Substring(4) }
                    if ($pfName.Length -le $pbase) { $pskip++; continue }
                    $pname = $pfName.Substring($pbase) -replace '\\', '/'
                    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                        $pzip, (LongPath $pf.FullName), $pname,
                        [System.IO.Compression.CompressionLevel]::Optimal)
                } catch { $pskip++ }
            }
        } finally { try { $pzip.Dispose() } catch { } }
        Write-Output "PARTIAL: $partial (incomplete, but readable; $pskip file(s) skipped)"
    } catch {
        # Packaging failed too (long path, disk full). Keep the scratch folder
        # and print where it is, rather than deleting the only copy.
        $script:KeepTmp = $true
        Write-Output "PARTIAL PACKAGING FAILED: $($_.Exception.Message)"
        Write-Output "Evidence left uncompressed at: $Tmp"
    }
}
finally {
    # work-* holds decoded conversation fragments in PLAIN TEXT. It is scratch for
    # a single decode pass, never evidence, so it goes even when KeepTmp is set to
    # preserve the rest of the scratch folder.
    $rootL = LongPath $TmpRoot
    try {
        if ([System.IO.Directory]::Exists($rootL)) {
            foreach ($d in [System.IO.Directory]::GetDirectories($rootL, 'work-*')) {
                try { [System.IO.Directory]::Delete($d, $true) } catch { }
            }
            # Raw dump-config stdout/stderr (unmasked) is scratch, never evidence.
            foreach ($d in [System.IO.Directory]::GetDirectories($rootL, 'dump-*')) {
                try { [System.IO.Directory]::Delete($d, $true) } catch { }
            }
        }
    } catch { }
    if (-not $script:KeepTmp) {
    # Remove-Item cannot reach a >260-char path, so use the .NET API. Best
    # effort: a leftover scratch folder is annoying, never fatal.
    $tmpL = LongPath $Tmp
    if ([System.IO.Directory]::Exists($tmpL)) {
        try { [System.IO.Directory]::Delete($tmpL, $true) } catch { }
    }
    # Leave no empty scratch root behind either.
    try {
        if ([System.IO.Directory]::Exists($rootL)) {
            $left = @([System.IO.Directory]::GetFileSystemEntries($rootL))
            if ($left.Count -eq 0) { [System.IO.Directory]::Delete($rootL, $true) }
        }
    } catch { }
    }  # end of "if (-not $script:KeepTmp)"
}

if (-not $ok) { exit 1 }

$sizeKB = [math]::Round((Get-Item $zip).Length / 1KB, 1)
Write-Output "OK $zip ($sizeKB KB)"
Write-Output ('checks: {0} ok / {1} warn / {2} fail' -f $checkCounts.ok, $checkCounts.warn, $checkCounts.fail)
if ($checkCounts.fail -gt 0) { Write-Output 'Open index.md in the report: FAIL rows come first.' }
exit 0
