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

Write-Host "Added " -NoNewline
Write-Host "New-StripeKeyMock" -ForegroundColor Green -NoNewline
Write-Host " function for generating mock Stripe API keys"


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

Check-CopilotUpdates

##
## Override MCP defaults for Copilot CLI
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

# Set-Location -Path "C:\repos"
# Write-Host "Setting start directory"


#f45873b3-b655-43a6-b217-97c00aa0db58 PowerToys CommandNotFound module

Import-Module -Name Microsoft.WinGet.CommandNotFound

Write-Host "Imported " -NoNewLine
Write-Host "Microsoft.WinGet.CommandNotFound " -ForegroundColor Green -NoNewline
Write-Host "module for winget suggestions on command not found errors."

#f45873b3-b655-43a6-b217-97c00aa0db58

