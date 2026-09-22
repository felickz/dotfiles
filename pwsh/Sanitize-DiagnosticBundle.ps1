<#
.SYNOPSIS
Produce a redacted copy of a vendor diagnostic bundle, safe to email to support.

.DESCRIPTION
Hardware vendors ship diagnostic collectors that gather far more than they need. A dock
vendor troubleshooting a monitor wants EDID, display config, USB topology and driver
versions. It does not need your process list, your software inventory, your logged-on
accounts or your kernel crash dumps.

This takes such a bundle and produces a sanitized sibling zip:

  Dropped outright (whole files):
    Minidump\*.dmp     raw kernel memory; can contain tokens, credentials or document
                       contents, and cannot realistically be reviewed by hand
    users.csv          local accounts, which on a managed machine includes service accounts
    tasklist.csv       every running process
    installed_apps.csv, RegKeys\HKLM_Uninstall.txt
                       full software inventory
    NetworkStats.txt, RegKeys\HKLM_Connectivity.txt
                       routing table, active connections, adapter detail

  Redacted in place, so the remaining files stay diagnostically useful:
    MAC addresses, non-loopback IPv4, GUIDs, this machine's name, this user's name.

Monitor serial numbers are KEPT by default. They are hardware identifiers that support
legitimately needs to identify a panel or a revision, and they say nothing about the
machine or the network. Pass -RedactSerials if you disagree.

.PARAMETER ExtraRedaction
Environment-specific literals to redact, as @{ 'literal' = '[PLACEHOLDER]' }. Matching is
case-insensitive. Use this for things only you know are sensitive, such as an employer's
private DNS suffix or the name of a corporate agent.

.PARAMETER ExtraRedactionFile
A file of 'literal=[PLACEHOLDER]' lines, one per line, read in addition to
-ExtraRedaction. Defaults to $env:LOCALAPPDATA\diagnostic-redactions.txt if it exists.
Deliberately outside this repo: corporate strings should never be committed anywhere
public, including to a redaction list.

.EXAMPLE
Sanitize-DiagnosticBundle.ps1 -Zip ~\Desktop\Plugabug_20260101.zip

.EXAMPLE
Sanitize-DiagnosticBundle.ps1 -Zip .\bundle.zip -ExtraRedaction @{ 'contoso.local' = '[DNS]' }

.NOTES
Always verifies its own output and writes the result to the Verification property. Do not
send a bundle whose Verification is not Clean.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$Zip,
    [Parameter(Position = 1)][string]$OutDir = "$env:USERPROFILE\Desktop",
    [switch]$RedactSerials,
    [hashtable]$ExtraRedaction,
    [string]$ExtraRedactionFile = "$env:LOCALAPPDATA\diagnostic-redactions.txt"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Zip)) { throw "Not found: $Zip" }
$Zip = (Resolve-Path -LiteralPath $Zip).Path
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

# Patterns that identify the machine or the network. Applied to every text file.
# Ordered so the GUID rule runs before the IPv4 rule cannot matter, but keep it explicit.
$patterns = [ordered]@{
    # MAC addresses, dashed or colon-separated.
    '(?<![0-9A-Fa-f-])([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}(?![0-9A-Fa-f-])'         = '[MAC-REDACTED]'
    # GUIDs. This is what exposes an Entra tenant id in DNS suffixes and registry paths.
    '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b' = '[GUID-REDACTED]'
    # IPv4, skipping loopback and the unspecified address, which carry no information.
    '(?<!\d)(?!0\.0\.0\.0)(?!127\.0\.0\.1)((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?!\d)' = '[IP-REDACTED]'
}

$literals = [ordered]@{}
if ($env:COMPUTERNAME) { $literals[$env:COMPUTERNAME] = '[HOSTNAME]' }
if ($env:USERNAME) { $literals[$env:USERNAME] = '[USER]' }

if ($ExtraRedactionFile -and (Test-Path -LiteralPath $ExtraRedactionFile)) {
    foreach ($line in (Get-Content -LiteralPath $ExtraRedactionFile)) {
        if ($line -match '^\s*(?:#|$)') { continue }
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $literals[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim()
    }
}
if ($ExtraRedaction) {
    foreach ($k in $ExtraRedaction.Keys) { $literals[[string]$k] = [string]$ExtraRedaction[$k] }
}

$work = Join-Path $env:TEMP ('diag-sanitize-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$src = Join-Path $work 'src'
New-Item -ItemType Directory -Path $src -Force | Out-Null

try {
    Expand-Archive -LiteralPath $Zip -DestinationPath $src -Force

    $dropExact = @(
        'users.csv'
        'tasklist.csv'
        'installed_apps.csv'
        'NetworkStats.txt'
        'windows_updates.csv'
    )
    $dropPaths = @(
        'Minidump'
        'RegKeys\HKLM_Uninstall.txt'
        'RegKeys\HKLM_Connectivity.txt'
    )

    $dropped = @()
    foreach ($name in $dropExact) {
        $p = Join-Path $src $name
        if (Test-Path -LiteralPath $p) { $dropped += $name; Remove-Item -LiteralPath $p -Force }
    }
    foreach ($rel in $dropPaths) {
        $p = Join-Path $src $rel
        if (Test-Path -LiteralPath $p) { $dropped += $rel; Remove-Item -LiteralPath $p -Recurse -Force }
    }
    # Catch dumps parked outside Minidump\.
    foreach ($d in @(Get-ChildItem $src -Recurse -File -Filter '*.dmp' -ErrorAction SilentlyContinue)) {
        $dropped += $d.Name
        Remove-Item -LiteralPath $d.FullName -Force
    }

    $maskSerials = @()
    if ($RedactSerials) {
        $found = @()
        $edid = Join-Path $src 'edid.txt'
        if (Test-Path -LiteralPath $edid) {
            $found += [regex]::Matches((Get-Content -LiteralPath $edid -Raw), '(?<=Serial Number\s*:\s*)(\S+)') |
                ForEach-Object { $_.Groups[1].Value }
        }
        $mon = Join-Path $src 'monitors.csv'
        if (Test-Path -LiteralPath $mon) {
            foreach ($row in (Import-Csv -LiteralPath $mon -ErrorAction SilentlyContinue)) {
                $col = $row.PSObject.Properties['Monitor Serial Number']
                if ($col -and $col.Value) { $found += $col.Value }
            }
        }
        # Only mask tokens long enough to actually be a serial, so a short string cannot
        # corrupt unrelated text.
        $maskSerials = @($found | Where-Object { $_ -and $_.Length -ge 6 } | Sort-Object -Unique)
    }

    # Classify by content, not by extension. An extension allowlist always misses
    # something: this class of bundle hides a 2 MB PE executable behind a .tmp name and a
    # multi-megabyte installer log behind .LOG. UTF-16 is detected explicitly, since it is
    # full of NUL bytes and a naive "no NULs means text" test would skip exactly the
    # chatty installer logs worth redacting.
    $textFiles = @()
    foreach ($f in (Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue)) {
        $n = [int][Math]::Min(4096, $f.Length)
        $head = [byte[]]::new([Math]::Max($n, 1))
        if ($n -gt 0) {
            $fs = [IO.File]::OpenRead($f.FullName)
            try { $null = $fs.Read($head, 0, $n) } finally { $fs.Dispose() }
        }

        $isUtf16 = $n -ge 2 -and (
            ($head[0] -eq 0xFF -and $head[1] -eq 0xFE) -or ($head[0] -eq 0xFE -and $head[1] -eq 0xFF)
        )
        if ($n -eq 0 -or $isUtf16 -or ($head[0..($n - 1)] -notcontains 0)) {
            $textFiles += $f
            continue
        }

        # Binary. It cannot be reviewed or redacted, so it does not go to a third party.
        $dropped += "binary: $($f.Name)"
        Remove-Item -LiteralPath $f.FullName -Force
    }
    $changed = 0

    foreach ($f in $textFiles) {
        $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { continue }
        $orig = $raw

        foreach ($p in $patterns.GetEnumerator()) { $raw = [regex]::Replace($raw, $p.Key, $p.Value) }
        foreach ($l in $literals.GetEnumerator()) {
            if ($l.Key) { $raw = [regex]::Replace($raw, [regex]::Escape($l.Key), $l.Value, 'IgnoreCase') }
        }
        foreach ($s in $maskSerials) {
            $raw = [regex]::Replace($raw, "(?<![A-Za-z0-9])$([regex]::Escape($s))(?![A-Za-z0-9])", '[SERIAL-REDACTED]')
        }

        if ($raw -ne $orig) {
            Set-Content -LiteralPath $f.FullName -Value $raw -Encoding utf8 -NoNewline
            $changed++
        }
    }

    $stem = [IO.Path]::GetFileNameWithoutExtension($Zip)
    $out = Join-Path $OutDir "$stem-SANITIZED.zip"
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    Compress-Archive -Path (Join-Path $src '*') -DestinationPath $out -CompressionLevel Optimal

    # Verify the artifact that will actually be sent, not the staging folder, because a
    # mistake in the repackage step is exactly the kind of thing that slips through.
    $vdir = Join-Path $work 'verify'
    Expand-Archive -LiteralPath $out -DestinationPath $vdir -Force
    $vfiles = @(Get-ChildItem $vdir -Recurse -File)

    $leaks = @()
    foreach ($f in $vfiles) {
        if ($f.Extension -eq '.dmp') { $leaks += "crash dump survived: $($f.Name)"; continue }
        $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { continue }
        if ($raw.IndexOf([char]0) -ge 0) { $leaks += "unreviewable binary survived: $($f.Name)"; continue }
        foreach ($p in $patterns.GetEnumerator()) {
            if ([regex]::IsMatch($raw, $p.Key)) { $leaks += "$($f.Name): matched $($p.Key)" }
        }
        foreach ($l in $literals.GetEnumerator()) {
            if ($l.Key -and $raw.IndexOf($l.Key, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $leaks += "$($f.Name): contains '$($l.Key)'"
            }
        }
    }

    if ($leaks) {
        Write-Warning "Verification FAILED. Do not send this bundle."
        $leaks | Select-Object -Unique | ForEach-Object { Write-Warning "  $_" }
    }

    [pscustomobject]@{
        Output        = $out
        SizeMB        = [math]::Round((Get-Item -LiteralPath $out).Length / 1MB, 2)
        OriginalMB    = [math]::Round((Get-Item -LiteralPath $Zip).Length / 1MB, 2)
        FilesDropped  = $dropped
        FilesRedacted = $changed
        FilesKept     = $vfiles.Count
        SerialsKept   = -not $RedactSerials
        Verification  = if ($leaks) { 'FAILED' } else { 'Clean' }
        Leaks         = @($leaks | Select-Object -Unique)
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
