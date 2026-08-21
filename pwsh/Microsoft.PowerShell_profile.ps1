# NOTE TO AI AGENTS: this profile is mirrored (as a curated, non-sensitive
# subset) at https://github.com/felickz/dotfiles
# (D:\repos\felickz\dotfiles\pwsh\Microsoft.PowerShell_profile.ps1). If you make
# non-sensitive changes here (new/updated functions, no secrets or private
# paths/hostnames), also update and push the equivalent change to that repo.
Write-Output "[reminder] Non-sensitive changes to this profile should also be pushed to felickz/dotfiles (D:\repos\felickz\dotfiles)."

# Animated fly-in effect for ASCII art
$asciiLines = @(
    "  _____ _____ _     ___ ____ _  ______   ____  ____  __",
    " |  ___| ____| |   |_ _/ ___| |/ |__  /  |  _ \/ ___|| |",
    " | |_  |  _| | |    | | |   | ' /  / /   | |_) \___ \| |",
    " |  _| | |___| |___ | | |___| . \ / /_  _|  __/ ___) | |",
    " |_|   |_____|_____|___\____|_|\_/____(_)__|   |____/|_|",
    "",
    "",
    ""
)

$maxLength = ($asciiLines | Measure-Object -Property Length -Maximum).Maximum
$steps = 15

for ($i = 0; $i -lt $steps; $i++) {
    $offset = [Math]::Max(0, $maxLength - [int](($i / $steps) * ($maxLength + 10)))

    Clear-Host
    foreach ($line in $asciiLines) {
        $spaces = " " * $offset
        $visiblePart = if ($offset -lt $line.Length) {
            $line.Substring($offset)
        } else {
            ""
        }
        Write-Host $visiblePart -ForegroundColor Cyan
    }

    Start-Sleep -Milliseconds 30
}

Clear-Host
foreach ($line in $asciiLines) {
    Write-Host $line -ForegroundColor Cyan
}

Write-Host "Loading PowerShell profile from " -NoNewline
Write-Host "`$PROFILE" -ForegroundColor Green -NoNewline
Write-Host ": $PROFILE"

Register-ArgumentCompleter -Native -CommandName az -ScriptBlock {
    param($commandName, $wordToComplete, $cursorPosition)
    $completion_file = New-TemporaryFile
    $env:ARGCOMPLETE_USE_TEMPFILES = 1
    $env:_ARGCOMPLETE_STDOUT_FILENAME = $completion_file
    $env:COMP_LINE = $wordToComplete
    $env:COMP_POINT = $cursorPosition
    $env:_ARGCOMPLETE = 1
    $env:_ARGCOMPLETE_SUPPRESS_SPACE = 0
    $env:_ARGCOMPLETE_IFS = "`n"
    $env:_ARGCOMPLETE_SHELL = 'powershell'
    az 2>&1 | Out-Null
    Get-Content $completion_file | Sort-Object | ForEach-Object {
        [System.Management.Automation.CompletionResult]::new($_, $_, "ParameterValue", $_)
    }
    Remove-Item $completion_file, Env:\_ARGCOMPLETE_STDOUT_FILENAME, Env:\ARGCOMPLETE_USE_TEMPFILES, Env:\COMP_LINE, Env:\COMP_POINT, Env:\_ARGCOMPLETE, Env:\_ARGCOMPLETE_SUPPRESS_SPACE, Env:\_ARGCOMPLETE_IFS, Env:\_ARGCOMPLETE_SHELL
}


# Import the Chocolatey Profile that contains the necessary code to enable
# tab-completions to function for `choco`.
# Be aware that if you are missing these lines from your profile, tab completion
# for `choco` will not function.
# See https://ch0.co/tab-completion for details.
$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}

# #output to profile console that we are installing copilot alias:
# Write-Host "Installing gh copilot alias `ghcs` and `ghce` via C:\Users\chadbentz\Documents\PowerShell\gh-copilot.ps1"
# . C:\Users\chadbentz\Documents\PowerShell\gh-copilot.ps1

# Function to generate mock Stripe API key
function New-StripeKeyMock {
    $baseStripeString = "sk_live_"
    # Generate random hex characters (similar to openssl rand -hex)
    $randomBytes = New-Object byte[] 50
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
    $rng.GetBytes($randomBytes)
    $stringRand = [System.BitConverter]::ToString($randomBytes) -replace '-', ''
    # Take first 99 characters (similar to head -c 99)
    $stringRand = $stringRand.Substring(0, [Math]::Min(99, $stringRand.Length))
    # Return the combined string
    return $baseStripeString + $stringRand
}

function b64 {
  param(
    [switch]$Decode,
    [string]$InputString,
    [string]$InFile,
    [string]$OutFile
  )

  if ($Decode) {
    if ($InputString) {
      [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($InputString))
    } elseif ($InFile) {
      $b64 = Get-Content $InFile -Raw
      [IO.File]::WriteAllBytes($OutFile, [Convert]::FromBase64String($b64))
      "Wrote $OutFile"
    } else {
      # read from pipeline
      $data = [Console]::In.ReadToEnd().Trim()
      [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data))
    }
  } else {
    if ($InputString) {
      [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($InputString))
    } elseif ($InFile) {
      [Convert]::ToBase64String([IO.File]::ReadAllBytes($InFile)) | Out-File -Encoding ascii $OutFile
      "Wrote $OutFile"
    } else {
      $data = [Console]::In.ReadToEnd()
      [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($data))
    }
  }
}


function Get-LastCommandExecutionTime {
    $last = Get-History -Count 1
    if (-not $last) {
        Write-Host "No command history yet." -ForegroundColor Yellow
        return
    }
    $duration = $last.Duration.ToString("hh\:mm\:ss\.fff")
    Write-Host "Command:  " -NoNewline
    Write-Host $last.CommandLine -ForegroundColor Cyan
    Write-Host "Duration: " -NoNewline
    Write-Host $duration -ForegroundColor Green
}

function Check-CopilotUpdates {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return }

    $extensionList = gh extension list 2>&1 | Out-String
    if ($extensionList -notmatch 'gh copilot\s+github/gh-copilot\s+v?([\d.]+)') { return }

    $currentVersion = $matches[1]

    try {
        $apiUrl = "https://api.github.com/repos/github/gh-copilot/releases/latest"
        $response = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 3 -ErrorAction Stop
        $latestVersion = $response.tag_name -replace '^v', ''

        if ($currentVersion -ne $latestVersion) {
            Write-Host "⚠   GitHub Copilot CLI update available: v$currentVersion → v$latestVersion" -ForegroundColor Yellow
            Write-Host "  Update with: gh extension upgrade gh-copilot" -ForegroundColor Cyan
        }
        else {
            Write-Host "gh extension:" -NoNewLine
            Write-Host "gh-copilot " -ForegroundColor Green -NoNewLine
            Write-Host "is up to date: v$currentVersion"
        }
    } catch {
        Write-Host
    }
}

function Update-GhExtensions {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return }

    Write-Host "gh extensions: " -NoNewline
    Write-Host "upgrading all..." -ForegroundColor Cyan
    $output = gh extension upgrade --all 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        $output.Trim().Split("`n") | ForEach-Object {
            if ($_ -match '\S') { Write-Host "  $_" -ForegroundColor DarkGray }
        }
    } else {
        Write-Host "  gh extension upgrade --all failed:" -ForegroundColor Yellow
        Write-Host $output -ForegroundColor DarkYellow
    }
}

function Update-CopilotPlugins {
    if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) { return }

    Write-Host "copilot plugins: " -NoNewline
    Write-Host "updating all..." -ForegroundColor Cyan
    $output = copilot plugin update --all 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        $output.Trim().Split("`n") | ForEach-Object {
            if ($_ -match '\S') { Write-Host "  $_" -ForegroundColor DarkGray }
        }
    } else {
        Write-Host "  copilot plugin update --all failed:" -ForegroundColor Yellow
        Write-Host $output -ForegroundColor DarkYellow
    }
}

##
## Override MCP defaults for Copilot CLI
##
function copilot-all {
    & copilot.ps1 --add-github-mcp-toolset all `
        @args
}

function copilot-ghas {
    & copilot.ps1 --add-github-mcp-toolset code_security `
        --add-github-mcp-toolset dependabot `
        --add-github-mcp-toolset secret_protection `
        --add-github-mcp-toolset security_advisories `
        --add-github-mcp-tool run_secret_scanning `
        @args
}

# Lightweight session for pre-commit dependency vulnerability scanning
# See: https://github.blog/changelog/2026-05-05-dependency-scanning-with-github-mcp-server-is-in-public-preview/
function copilot-depcheck {
    & copilot.ps1 --add-github-mcp-toolset dependabot `
        @args
}

function Restart-Explorer {
    Stop-Process -Name explorer -Force
    Stop-Process -Name itype -Force -ErrorAction SilentlyContinue
    Start-Process explorer.exe
    Start-Process itype.exe
    Write-Host "Explorer and itype restarted!" -ForegroundColor Green
}

function Restart-Monitors {
    <#
    .SYNOPSIS
    Restarts failed DisplayLink adapters and monitor endpoints after waking from sleep.
    #>
    $script = @'
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'restart-monitors.log'
"Starting monitor reset: $(Get-Date -Format o)" | Set-Content -Path $log

$displayLinkAdapters = Get-PnpDevice -PresentOnly -Class Display | Where-Object {
    if ($_.Status -eq 'OK') { return $false }
    $provider = Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_DriverProvider' -ErrorAction SilentlyContinue
    $provider.Data -eq 'DisplayLink' -or $_.FriendlyName -match 'DisplayLink|Plugable'
}
$monitorEndpoints = Get-PnpDevice -PresentOnly -Class Monitor | Where-Object { $_.Status -ne 'OK' }
$targets = @($displayLinkAdapters) + @($monitorEndpoints) |
    Group-Object -Property InstanceId |
    ForEach-Object { $_.Group[0] }

if (-not $targets) {
    'No failed DisplayLink adapters or monitor endpoints were found.' | Add-Content -Path $log
    return
}

foreach ($device in $targets) {
    "Disabling $($device.FriendlyName) [$($device.InstanceId)]" | Add-Content -Path $log
    Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
}
Start-Sleep -Seconds 5
foreach ($device in $targets) {
    "Enabling $($device.FriendlyName) [$($device.InstanceId)]" | Add-Content -Path $log
    Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
}
Start-Sleep -Seconds 10
foreach ($device in $targets) {
    $current = Get-PnpDevice -InstanceId $device.InstanceId
    $problem = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode').Data
    "$($current.FriendlyName): Status=$($current.Status); ProblemCode=$problem" | Add-Content -Path $log
}
'Reset finished.' | Add-Content -Path $log
Get-Content -Path $log
'@
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-EncodedCommand', $encodedCommand
    Write-Host "UAC prompt sent - approve to reset failed DisplayLink adapters and monitors." -ForegroundColor Yellow
    Write-Host "Results will be written to $env:TEMP\restart-monitors.log" -ForegroundColor DarkGray
}

function Upgrade-CodeQL {
    <#
    .SYNOPSIS
    Upgrades (or pins) the local CodeQL CLI bundle to a github/codeql-action release.
    .DESCRIPTION
    Downloads codeql-bundle-win64 from github/codeql-action - either the latest release,
    or a specific -Version you name - short-circuits if that version is already installed,
    swaps it into C:\Utils\codeql (keeping a -old backup until success), checks out the
    matching codeql-cli/vX.Y.Z ref in the ql submodule, and prints "codeql --version" to
    confirm.
    .PARAMETER Version
    Optional exact CLI version to install, e.g. "2.26.1" or "v2.26.1". Useful when a newer
    release (e.g. 2.26.2) has since shipped but you need to pin to what's actually released
    and match e.g. a repo's .codeqlversion. Omit to fetch whatever is currently latest.
    .EXAMPLE
    Upgrade-CodeQL -Version 2.26.1
    .EXAMPLE
    Upgrade-CodeQL -Version 2.26.1 -InstallPath D:\Utils\codeql-2.26.1
    #>
    [CmdletBinding()]
    param(
        [string]$Version,
        [string]$InstallPath  = "C:\Utils\codeql",
        [string]$SubmodulePath = "D:\repos\felickz\vscode-codeql-starter\ql"
    )

    $ErrorActionPreference = 'Stop'

    # 1. Resolve which bundle release to install: an explicit -Version pin, or /releases/latest
    if ($Version) {
        $cliVersionNumber = $Version -replace '^v', ''  # 2.26.1
        $cliVersion       = "v$cliVersionNumber"        # v2.26.1
        $bundleTag        = "codeql-bundle-$cliVersion" # codeql-bundle-v2.26.1
        Write-Host "Looking up requested CodeQL bundle release $bundleTag..." -ForegroundColor Cyan
        $apiUrl = "https://api.github.com/repos/github/codeql-action/releases/tags/$bundleTag"
        try {
            $null = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'Upgrade-CodeQL' } -ErrorAction Stop
        } catch {
            Write-Host "No release found for $bundleTag (is $cliVersion a real CodeQL CLI version?): $_" -ForegroundColor Red
            return
        }
        Write-Host "Found bundle: $bundleTag (CLI $cliVersion)" -ForegroundColor Green
    } else {
        Write-Host "Checking latest CodeQL bundle release..." -ForegroundColor Cyan
        $apiUrl = "https://api.github.com/repos/github/codeql-action/releases/latest"
        try {
            $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'Upgrade-CodeQL' } -ErrorAction Stop
        } catch {
            Write-Host "Failed to query GitHub API: $_" -ForegroundColor Red
            return
        }
        $bundleTag        = $release.tag_name                          # codeql-bundle-v2.25.6
        $cliVersion       = ($bundleTag -replace '^codeql-bundle-', '') # v2.25.6
        $cliVersionNumber = ($cliVersion -replace '^v', '')             # 2.25.6
        Write-Host "Latest bundle: $bundleTag (CLI $cliVersion)" -ForegroundColor Green
    }

    # 2. Short-circuit if the installed version already matches
    $codeqlExe = Join-Path $InstallPath "codeql.exe"
    if (Test-Path $codeqlExe) {
        $installedRaw = & $codeqlExe --version 2>$null | Select-Object -First 1
        if ($installedRaw -match '([\d]+\.[\d]+\.[\d]+)') {
            $installedVersion = $matches[1]
            if ($installedVersion -eq $cliVersionNumber) {
                Write-Host "CodeQL $installedVersion is already installed at $InstallPath. Nothing to do." -ForegroundColor Green
                return
            }
            Write-Host "Installed CodeQL $installedVersion, switching to $cliVersionNumber" -ForegroundColor Yellow
        }
    } else {
        Write-Host "No existing CodeQL at $InstallPath; performing a fresh install." -ForegroundColor Yellow
    }

    # 3. Download the win64 bundle
    $downloadUrl = "https://github.com/github/codeql-action/releases/download/$bundleTag/codeql-bundle-win64.tar.gz"
    $archive     = Join-Path $env:TEMP "codeql-bundle-win64-$cliVersionNumber.tar.gz"
    Write-Host "Downloading $downloadUrl" -ForegroundColor Cyan
    curl.exe -L --fail -o $archive $downloadUrl
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $archive)) {
        Write-Host "Download failed." -ForegroundColor Red
        return
    }

    # 4. Rename the current install to -old (clear any stale backup first)
    $oldPath  = "$InstallPath-old"
    $leafNew  = Split-Path $InstallPath -Leaf
    $leafOld  = Split-Path $oldPath -Leaf
    if (Test-Path $oldPath) {
        Write-Host "Removing stale $oldPath..." -ForegroundColor DarkGray
        Remove-Item -Recurse -Force $oldPath
    }
    if (Test-Path $InstallPath) {
        Write-Host "Renaming $InstallPath -> $oldPath" -ForegroundColor Cyan
        Rename-Item -Path $InstallPath -NewName $leafOld
    }

    # 5. Extract into an isolated staging dir, then move into place. The bundle
    #    always expands to a top-level 'codeql' folder regardless of -InstallPath's
    #    leaf name - extracting straight into $InstallPath's parent would silently
    #    clobber any unrelated existing "<parent>\codeql" folder (e.g. your real
    #    default install, if -InstallPath shares a parent with it). Staging first
    #    avoids that collision entirely.
    $stagingParent = Join-Path $env:TEMP "codeql-upgrade-stage-$cliVersionNumber-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $stagingParent -Force | Out-Null
    Write-Host "Extracting bundle to staging dir $stagingParent..." -ForegroundColor Cyan
    tar.exe -xzf $archive -C $stagingParent
    $stagedCodeqlExe = Join-Path $stagingParent "codeql\codeql.exe"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $stagedCodeqlExe)) {
        Write-Host "Extraction failed. Restoring previous install." -ForegroundColor Red
        Remove-Item -Recurse -Force $stagingParent -ErrorAction SilentlyContinue
        if (Test-Path $InstallPath) { Remove-Item -Recurse -Force $InstallPath }
        if (Test-Path $oldPath)     { Rename-Item -Path $oldPath -NewName $leafNew }
        return
    }

    # 6. Move the staged 'codeql' folder into its final -InstallPath location
    Write-Host "Installing to $InstallPath..." -ForegroundColor Cyan
    Move-Item -Path (Join-Path $stagingParent "codeql") -Destination $InstallPath
    Remove-Item -Recurse -Force $stagingParent -ErrorAction SilentlyContinue

    # 7. Delete the -old backup now that the new install is in place
    if (Test-Path $oldPath) {
        Write-Host "Deleting $oldPath..." -ForegroundColor DarkGray
        Remove-Item -Recurse -Force $oldPath
    }
    Remove-Item $archive -Force -ErrorAction SilentlyContinue

    # 8. Switch the ql submodule to the matching CLI ref (e.g. codeql-cli/v2.25.6)
    $ref = "codeql-cli/$cliVersion"
    if (Test-Path $SubmodulePath) {
        Write-Host "Switching ql submodule to $ref..." -ForegroundColor Cyan
        Push-Location $SubmodulePath
        try {
            git fetch --tags 2>&1 | Out-Null
            git checkout $ref 2>&1 | Write-Host
        } finally {
            Pop-Location
        }
    } else {
        Write-Host "Submodule path $SubmodulePath not found; skipping checkout." -ForegroundColor Yellow
    }

    # 9. Confirm
    Write-Host "CodeQL version now installed:" -ForegroundColor Green
    & $codeqlExe --version
}

# Set-Location -Path "C:\repos"
# Write-Host "Setting start directory"


#f45873b3-b655-43a6-b217-97c00aa0db58 PowerToys CommandNotFound module

Import-Module -Name Microsoft.WinGet.CommandNotFound

#f45873b3-b655-43a6-b217-97c00aa0db58

# ─── Profile Summary ───────────────────────────────────────────────
Write-Host ""
Write-Host "── Custom Functions ──────────────────────────────────────" -ForegroundColor DarkGray
$functions = @(
    @{ Name = "New-StripeKeyMock";           Desc = "Generate mock Stripe API key" }
    @{ Name = "b64";                         Desc = "Base64 encode/decode (b64 'hi' | b64 -Decode 'aGk=')" }
    @{ Name = "Get-LastCommandExecutionTime"; Desc = "Show duration of last command" }
    @{ Name = "copilot-all";                 Desc = "Copilot CLI with all MCP toolsets" }
    @{ Name = "copilot-ghas";               Desc = "Copilot CLI with GHAS MCP toolsets" }
    @{ Name = "copilot-depcheck";            Desc = "Copilot CLI with Dependabot dep vulnerability scanning" }
    @{ Name = "Restart-Explorer";            Desc = "Kill and restart Windows Explorer + itype.exe" }
    @{ Name = "Restart-Monitors";            Desc = "Wake USB-C dock monitors stuck after sleep (admin)" }
    @{ Name = "Upgrade-CodeQL";              Desc = "Install latest (or -Version pinned) CodeQL bundle + sync ql submodule ref" }
)
foreach ($f in $functions) {
    Write-Host "  " -NoNewline
    Write-Host ("{0,-30}" -f $f.Name) -ForegroundColor Green -NoNewline
    Write-Host $f.Desc
}

Write-Host ""
Write-Host "── Modules Loaded ────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  " -NoNewline
Write-Host "Microsoft.WinGet.CommandNotFound" -ForegroundColor Green -NoNewline
Write-Host "  ✔ loaded"

Write-Host "  " -NoNewline
Write-Host "az CLI tab-completion" -ForegroundColor Green -NoNewline
Write-Host "              ✔ registered"

Write-Host ""
Write-Host "── Config Paths ──────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  " -NoNewline
Write-Host "Copilot CLI MCP:  " -ForegroundColor Green -NoNewline
Write-Host "$env:USERPROFILE\.copilot\mcp-config.json"
Write-Host "  " -NoNewline
Write-Host "VS Code Settings: " -ForegroundColor Green -NoNewline
Write-Host "$env:APPDATA\Code\User\settings.json"
Write-Host "  " -NoNewline
Write-Host "VS Code MCP:      " -ForegroundColor Green -NoNewline
Write-Host "$env:APPDATA\Code\User\mcp.json"

Write-Host ""
Write-Host "── Update Checks ─────────────────────────────────────────" -ForegroundColor DarkGray

Check-CopilotUpdates
Update-GhExtensions
Update-CopilotPlugins

Write-Host "──────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
