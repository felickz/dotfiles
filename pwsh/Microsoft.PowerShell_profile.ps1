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

##
## Azure CLI tab completion
## Enables IntelliSense-style autocompletion for `az` commands using argcomplete.
##
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

##
## Mock Stripe API key generator
## Produces a realistic-looking sk_live_ key for testing secret-scanning tools.
## Usage: New-StripeKeyMock
##
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

Write-Host "Added " -NoNewline
Write-Host "New-StripeKeyMock" -ForegroundColor Green -NoNewline
Write-Host " function for generating mock Stripe API keys"


##
## Base64 encode/decode utility
## Supports strings, files, and pipeline input.
## Usage: b64 'hello'  |  b64 -Decode 'aGVsbG8='  |  b64 -InFile img.png -OutFile img.b64
##
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


Write-Host "Added " -NoNewline
Write-Host "b64" -ForegroundColor Green -NoNewline
Write-Host " command: b64 'hello' or b64 -Decode 'ZGVtbzpwQDU1dzByZA=='"

##
## Last command execution time
## Displays the wall-clock duration of the most recent command from history.
## Usage: Get-LastCommandExecutionTime
##
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

Write-Host "Added " -NoNewline
Write-Host "Get-LastCommandExecutionTime" -ForegroundColor Green -NoNewline
Write-Host " function to display the duration of the last command"



##
## Copilot CLI wrapper with default MCP security toolsets
## Invokes copilot.ps1 with pre-configured MCP toolsets for code security,
## Dependabot, secret protection, security advisories, and secret scanning.
## Usage: copilot <args>
##
function copilot {
    & copilot.ps1 --add-github-mcp-toolset code_security `
        --add-github-mcp-toolset Dependabot `
        --add-github-mcp-toolset secret_protection `
        --add-github-mcp-toolset security_advisories `
        --add-github-mcp-tool run_secret_scanning `
        @args
}

Write-Host "Added " -NoNewline
Write-Host "copilot" -ForegroundColor Green -NoNewline
Write-Host " function with default MCP toolsets (code_security, Dependabot, secret_protection, security_advisories, run_secret_scanning)"

##
## CodeQL CLI upgrader (latest or pinned version)
## Downloads codeql-bundle-win64 from github/codeql-action - either the latest
## release, or a specific -Version you name (useful for pinning to what a repo's
## .codeqlversion actually expects, even after a newer CLI has since shipped).
## Swaps it into C:\Utils\codeql (keeping a -old backup until success), checks
## out the matching codeql-cli/vX.Y.Z ref in the ql submodule, and prints
## "codeql --version" to confirm.
## Usage: Upgrade-CodeQL  |  Upgrade-CodeQL -Version 2.26.1
##
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

Write-Host "Added " -NoNewline
Write-Host "Upgrade-CodeQL" -ForegroundColor Green -NoNewline
Write-Host " function to install latest (or -Version pinned) CodeQL CLI + sync ql submodule ref"

# Set-Location -Path "C:\repos"
# Write-Host "Setting start directory"


##
## PowerToys / WinGet CommandNotFound module
## Suggests installable packages via winget when a typed command is not found.
## Requires: PowerToys with the CommandNotFound experimental feature enabled.
## See: https://learn.microsoft.com/windows/powertoys/cmd-not-found
##
#f45873b3-b655-43a6-b217-97c00aa0db58 PowerToys CommandNotFound module
Import-Module -Name Microsoft.WinGet.CommandNotFound

Write-Host "Imported " -NoNewLine
Write-Host "Microsoft.WinGet.CommandNotFound " -ForegroundColor Green -NoNewline
Write-Host "module for winget suggestions on command not found errors."

#f45873b3-b655-43a6-b217-97c00aa0db58



#EOL Stuff:

                # #output to profile console that we are installing copilot alias:
                # Write-Host "Installing gh copilot alias `ghcs` and `ghce` via C:\Users\chadbentz\Documents\PowerShell\gh-copilot.ps1"
                # . C:\Users\chadbentz\Documents\PowerShell\gh-copilot.ps1

                ##
                ## GitHub Copilot CLI update checker
                ## Compares the locally installed gh-copilot extension version against the
                ## latest release on GitHub and prints a notice when an update is available.
                ##

                # function Check-CopilotUpdates {
                #     if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return }

                #     $extensionList = gh extension list 2>&1 | Out-String
                #     if ($extensionList -notmatch 'gh copilot\s+github/gh-copilot\s+v?([\d.]+)') { return }

                #     $currentVersion = $matches[1]

                #     try {
                #         $apiUrl = "https://api.github.com/repos/github/gh-copilot/releases/latest"
                #         $response = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 3 -ErrorAction Stop
                #         $latestVersion = $response.tag_name -replace '^v', ''

                #         if ($currentVersion -ne $latestVersion) {
                #             Write-Host "⚠   GitHub Copilot CLI update available: v$currentVersion → v$latestVersion" -ForegroundColor Yellow
                #             Write-Host "  Update with: gh extension upgrade gh-copilot" -ForegroundColor Cyan
                #         }
                #         else {
                #             Write-Host "gh extension:" -NoNewLine
                #             Write-Host "gh-copilot " -ForegroundColor Green -NoNewLine
                #             Write-Host "is up to date: v$currentVersion"
                #         }
                #     } catch {
                #         Write-Host
                #     }
                # }


                ## CLI is self updationg now - Just call /update on the CLI
                ##Check-CopilotUpdates
