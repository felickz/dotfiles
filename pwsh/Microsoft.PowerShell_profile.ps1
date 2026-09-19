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

function Get-CopilotProcess {
    <#
    .SYNOPSIS
    Running GitHub Copilot CLI / app processes that contend for the shared plugin git cache.
    .DESCRIPTION
    Every Copilot CLI instance and the Copilot app share one marketplace git cache under
    ~\.copilot\repos. Updating plugins while other instances are live fails part-way through
    the marketplace fetch:

        Failed to fetch GitHub marketplace github/awesome-copilot:
        Git cache I/O failed: The process cannot access the file because it is being used
        by another process. (os error 32)

    That was reproduced directly with "copilot plugin update <name>", not inferred from the
    batch failure, so the update functions below skip rather than fail noisily on every new
    shell.

    Matching is deliberately narrow. Microsoft's Windows Copilot is copilotapp.exe /
    copilotapphost.exe under "Program Files (x86)\Microsoft\Copilot" and has nothing to do
    with Copilot CLI plugins; treating it as a blocker would suppress updates permanently,
    since it is essentially always running. Get-Process -Name matches exactly so
    "copilotapp" already fails the name filter, and the path check keeps that true even if
    those process names change.
    #>
    [CmdletBinding()]
    param()

    $ourPaths = @(
        '\\github-copilot-sdk\\'            # Copilot CLI, versioned install
        '\\winget\\links\\copilot\.exe$'    # winget shim that launches the CLI
        '\\GitHub Copilot\\github\.exe$'    # Copilot app
    )

    Get-Process -Name copilot, github -ErrorAction SilentlyContinue | Where-Object {
        # .Path throws for processes this user cannot open; treat those as "not ours".
        $path = try { $_.Path } catch { $null }
        $path -and ($ourPaths | Where-Object { $path -match $_ })
    }
}

function Test-CopilotBusy {
    <#
    .SYNOPSIS
    True when a Copilot CLI or app instance is running, so plugin/extension updates should wait.
    .PARAMETER Reason
    Receives a human-readable summary of what is holding things up.
    #>
    [CmdletBinding()]
    param([ref]$Reason)

    $procs = @(Get-CopilotProcess)
    if (-not $procs) { return $false }

    if ($Reason) {
        $Reason.Value = ($procs | Group-Object ProcessName |
            ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
    }
    $true
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
    [CmdletBinding()]
    param([switch]$Force)

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return }

    $why = ''
    if ((Test-CopilotBusy -Reason ([ref]$why)) -and -not $Force) {
        Write-Host "gh extensions: " -NoNewline
        Write-Host "skipped" -ForegroundColor DarkYellow -NoNewline
        Write-Host " ($why running) - " -NoNewline
        Write-Host "udgh -Force" -ForegroundColor Cyan -NoNewline
        Write-Host " to update anyway"
        return
    }

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
    [CmdletBinding()]
    param([switch]$Force)

    if (-not (Get-Command copilot -ErrorAction SilentlyContinue)) { return }

    # Always guarded, because the marketplace fetch reads a git cache shared with every
    # other live Copilot instance (see Get-CopilotProcess).
    $why = ''
    if ((Test-CopilotBusy -Reason ([ref]$why)) -and -not $Force) {
        Write-Host "copilot plugins: " -NoNewline
        Write-Host "skipped" -ForegroundColor DarkYellow -NoNewline
        Write-Host " ($why running) - " -NoNewline
        Write-Host "udcp -Force" -ForegroundColor Cyan -NoNewline
        Write-Host " to update anyway"
        return
    }

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

function Test-ExplorerSpin {
    <#
    .SYNOPSIS
    Detects the wedged shell task scheduler that freezes the taskbar clock.
    .DESCRIPTION
    Explorer is NOT deadlocked when this happens - its message pump answers WM_NULL
    in ~7ms and no critical sections are contended. Instead ~9 threadpool threads spin
    in windows_storage!CShellTaskScheduler::TT_TransitionThreadToRunningOrTerminating,
    starving the CTray taskbar thread of CPU so the clock never repaints.
    So: sustained CPU burn is the signal, "Not Responding" is not.
    #>
    $p = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { return $false }
    $before = $p.TotalProcessorTime.TotalSeconds
    Start-Sleep -Seconds 3
    $p.Refresh()
    $burn = ($p.TotalProcessorTime.TotalSeconds - $before) / 3   # cores consumed
    Write-Host ("explorer pid {0}  {1:P0} of a core  {2} threads" -f $p.Id, $burn, $p.Threads.Count) -ForegroundColor DarkGray
    return ($burn -gt 0.30)   # idle explorer is ~0%; wedged sits near or above a full core
}

function Restart-Explorer {
    <#
    .SYNOPSIS
    Restarts Explorer to recover the frozen taskbar clock after a sleep/resume.
    .NOTES
    History (2026-08-27, confirmed from full-memory dumps + WPR trace):

    Two INDEPENDENT bugs, both triggered by Modern Standby resume (Kernel-Power 507):

    1. itype.exe (Mouse and Keyboard Center v14.41, built 2021) - the KEYBOARD component.
       Its UI thread wedges re-dispatching private message 0x5F6 (119s CPU, 97s kernel).
       Because it owns a WH_KEYBOARD_LL hook - which runs on the INSTALLING thread -
       every keystroke system-wide blocks on that saturated thread up to
       LowLevelHooksTimeout (300ms default). That is the typing lag, and why killing
       itype fixes it instantly: the chokepoint just disappears.
       FIXED: launch tasks disabled (see Enable-IType below to reverse).
       Do NOT relaunch itype here - that reintroduces the hook. The old version of this
       function also called `Start-Process itype.exe`, which threw anyway (not on PATH).

    2. explorer.exe - shell task scheduler spins (see Test-ExplorerSpin). Still unfixed
       upstream; restarting Explorer is the only recovery. Only ever observed after #1.
       Repro evidence lives in C:\traces\ - keep it until the OS bug is resolved.
    #>
    [CmdletBinding()]
    param(
        # Skip the "is it actually wedged?" check and restart unconditionally.
        [switch]$Force
    )

    if (-not $Force -and -not (Test-ExplorerSpin)) {
        Write-Host "Explorer looks healthy - not restarting. Use -Force to override." -ForegroundColor Yellow
        return
    }

    $old = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
    $oldId = if ($old) { $old.Id } else { 0 }
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue

    # Windows normally respawns the shell on its own; only start it if it doesn't come
    # back. Unconditionally calling Start-Process here races that and can leave you with
    # a stray File Explorer window instead of a shell. Match on a NEW pid - the dying
    # process lingers briefly and will otherwise be mistaken for the replacement.
    $shell = $null
    for ($i = 0; $i -lt 20 -and -not $shell; $i++) {
        Start-Sleep -Milliseconds 500
        $shell = Get-Process explorer -ErrorAction SilentlyContinue |
                 Where-Object { $_.Id -ne $oldId } | Select-Object -First 1
    }
    if (-not $shell) {
        Start-Process explorer.exe
        for ($i = 0; $i -lt 10 -and -not $shell; $i++) {
            Start-Sleep -Milliseconds 500
            $shell = Get-Process explorer -ErrorAction SilentlyContinue |
                     Where-Object { $_.Id -ne $oldId } | Select-Object -First 1
        }
    }

    if ($shell) { Write-Host "Explorer restarted (pid $($shell.Id)) - clock should tick again." -ForegroundColor Green }
    else        { Write-Warning "Explorer did not come back. Start it from Task Manager > Run new task > explorer.exe" }
}

function Get-DeepSleep {
    <#
    .SYNOPSIS
    Reports whether the verified Modern Standby optimizations are enabled.
    .DESCRIPTION
    DeepSleep On means:
      1. Network connectivity during Modern Standby is disabled on AC and battery.
      2. The unused Plugable UD-ULTC4K 3.5 mm audio interface is disabled.

    These settings fixed a Surface Laptop Studio 2 that stayed at 0% hardware and
    software low-power residency with the dock connected. A dock-free SleepStudy
    measured 93-99% residency. DisplayLink video, Ethernet, USB, and charging remain
    enabled when only the Plugable Audio interface is disabled.
    #>
    [CmdletBinding()]
    param()

    $networkSetting = 'F15576E8-98B7-4186-B944-EAFA664402D9'
    $powerOutput = powercfg /qh SCHEME_CURRENT SUB_NONE $networkSetting 2>&1 | Out-String

    $acValue = if ($powerOutput -match 'Current AC Power Setting Index:\s+0x([0-9a-f]+)') {
        [Convert]::ToInt32($matches[1], 16)
    }
    $dcValue = if ($powerOutput -match 'Current DC Power Setting Index:\s+0x([0-9a-f]+)') {
        [Convert]::ToInt32($matches[1], 16)
    }

    $audioDevices = @(Get-PnpDevice -Class MEDIA -ErrorAction SilentlyContinue | Where-Object {
        $_.FriendlyName -eq 'Plugable Audio' -and
        $_.InstanceId -like 'USB\VID_17E9&PID_6011&MI_02\*'
    })
    $audioStates = @($audioDevices | ForEach-Object {
        $problemCode = (Get-PnpDeviceProperty -InstanceId $_.InstanceId `
            -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data
        if ($problemCode -eq 22) { 'Disabled' } else { 'Enabled' }
    } | Sort-Object -Unique)
    $audioState = if (-not $audioDevices) { 'Not detected' }
                  elseif ($audioStates.Count -eq 1) { $audioStates[0] }
                  else { 'Mixed' }

    $networkAc = switch ($acValue) { 0 { 'Disabled' } 1 { 'Enabled' } 2 { 'Managed' } default { 'Unknown' } }
    $networkDc = switch ($dcValue) { 0 { 'Disabled' } 1 { 'Enabled' } 2 { 'Managed' } default { 'Unknown' } }
    $state = if ($acValue -eq 0 -and $dcValue -eq 0 -and $audioState -eq 'Disabled') {
        'On'
    } elseif ($acValue -eq 1 -and $dcValue -eq 1 -and $audioState -eq 'Enabled') {
        'Off'
    } else {
        'Partial'
    }

    [pscustomobject]@{
        DeepSleep            = $state
        StandbyNetworkOnAC   = $networkAc
        StandbyNetworkOnDC   = $networkDc
        PlugableAudio        = $audioState
    }
}

function Set-DeepSleep {
    <#
    .SYNOPSIS
    Enables or reverts the verified Modern Standby optimizations.
    .PARAMETER State
    On disables standby networking on AC/DC and disables the Plugable dock's
    unused 3.5 mm audio interface. Off restores standby networking and Plugable Audio.
    .EXAMPLE
    DeepSleep On
    .EXAMPLE
    DeepSleep Off
    .EXAMPLE
    Get-DeepSleep
    .NOTES
    Requires elevation. If needed, the function opens one UAC prompt and performs only
    the two changes documented above. PlatformAoAcOverride, wake devices, hibernation
    timers, PowerToys Awake, DisplayLink video, Ethernet, USB, and charging are untouched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('On', 'Off')]
        [string]$State
    )

    $networkValue = if ($State -eq 'On') { 0 } else { 1 }
    $deviceVerb = if ($State -eq 'On') { 'Disable' } else { 'Enable' }
    $description = "$deviceVerb standby networking and Plugable Audio"
    if (-not $PSCmdlet.ShouldProcess('Windows power and Plugable dock audio settings', $description)) {
        return
    }

    $script = @'
$ErrorActionPreference = 'Stop'
$state = '__STATE__'
$networkValue = __NETWORK_VALUE__
$networkSetting = 'F15576E8-98B7-4186-B944-EAFA664402D9'

foreach ($powerSource in 'ac', 'dc') {
    & powercfg "/set${powerSource}valueindex" SCHEME_CURRENT SUB_NONE $networkSetting $networkValue
    if ($LASTEXITCODE -ne 0) {
        throw "powercfg failed while updating the $powerSource standby-network setting."
    }
}
& powercfg /setactive SCHEME_CURRENT
if ($LASTEXITCODE -ne 0) { throw 'powercfg failed while reactivating the current plan.' }

$audioDevices = @(Get-PnpDevice -Class MEDIA -ErrorAction SilentlyContinue | Where-Object {
    $_.FriendlyName -eq 'Plugable Audio' -and
    $_.InstanceId -like 'USB\VID_17E9&PID_6011&MI_02\*'
})
if (-not $audioDevices) {
    Write-Warning 'No known Plugable Audio interface was found. The network setting was still updated.'
}
foreach ($device in $audioDevices) {
    $problemCode = (Get-PnpDeviceProperty -InstanceId $device.InstanceId `
        -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data
    if ($state -eq 'On' -and $problemCode -ne 22) {
        Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
    } elseif ($state -eq 'Off' -and $problemCode -eq 22) {
        Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
    }
}

Write-Host "DeepSleep $state applied." -ForegroundColor Green
Write-Host 'Close this window, then run Get-DeepSleep in your normal shell to verify.' -ForegroundColor Cyan
'@
    $script = $script.Replace('__STATE__', $State).Replace('__NETWORK_VALUE__', [string]$networkValue)

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if ($isAdmin) {
        & ([scriptblock]::Create($script))
        return
    }

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile', '-NoExit', '-EncodedCommand', $encodedCommand
    Write-Host "UAC prompt sent for DeepSleep $State." -ForegroundColor Yellow
}

Set-Alias -Name DeepSleep -Value Set-DeepSleep

function Enable-IType {
    <#
    .SYNOPSIS
    Re-enables itype.exe autostart. Only needed if you attach a Microsoft KEYBOARD.
    .DESCRIPTION
    The Arc Touch BT Mouse is driven by ipoint.exe, which is untouched - so unless a
    Microsoft keyboard shows up, leaving itype disabled costs nothing. Requires admin.
    Also useful to reproduce the resume bug on demand for the OS team.
    #>
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile', '-Command', @'
schtasks /Change /TN "Microsoft_MKC_Logon_Task_itype.exe" /ENABLE
schtasks /Change /TN "Microsoft_Hardware_Launch_itype_exe" /ENABLE
Write-Host "itype tasks re-enabled. Sign out/in or run itype.exe to start it."
pause
'@
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

# ─── DeskSwitch (v2): monitor input switching across three machines ───────
# Module lives beside this profile in the dotfiles repo. $PROFILE is a symlink and
# $PSScriptRoot resolves to the LINK's directory, not the repo, so follow the link to
# find it; fall back to the literal repo path.
$deskModule = $null
foreach ($candidate in @(
        (Join-Path $PSScriptRoot 'DeskSwitch.psm1'),
        $(if ($PSCommandPath) {
              $t = (Get-Item $PSCommandPath -Force -ErrorAction SilentlyContinue).Target
              if ($t) { Join-Path (Split-Path $t -Parent) 'DeskSwitch.psm1' }
          }),
        'D:\repos\felickz\dotfiles\pwsh\DeskSwitch.psm1'
    )) {
    if ($candidate -and (Test-Path $candidate)) { $deskModule = $candidate; break }
}
if ($deskModule) { Import-Module $deskModule -Force -DisableNameChecking }

# Which monitor inputs each machine claims, keyed by desk position (left/center/right is
# resolved from actual screen X, not display index - Windows renumbers those, and two of
# the monitors are the same model).
#
# Moving a machine to a different monitor, or switching the side panels to USB-C after
# upgrading them to P2725DE, is an edit to this map only. Run "gmin -Detailed" to see
# which inputs each monitor actually advertises.
$Global:DeskProfiles = [ordered]@{
    main     = @{ HostName = 'SURFACESTUDIO2'  ; Monitors = [ordered]@{ Left = 'DP'; Center = 'DP'; Right = 'DP' } }
    mac      = @{ HostName = 'H17MX7TXMT'      ; Monitors = [ordered]@{ Right = 'USBC' } }
    personal = @{ HostName = 'SURFACE-LAPTOP5' ; Monitors = [ordered]@{ Left  = 'HDMI' } }
}

function Switch-MonitorSetup {
    <#
    .SYNOPSIS
    Toggles the desktop between the full multi-monitor layout and laptop-screen-only.
    .DESCRIPTION
    Flips the Windows display topology using the CCD (Connecting and Configuring Displays)
    API - the same switch Win+P performs, without the flyout. Windows keeps the arrangement
    for each topology (monitor positions, resolutions, which one is primary) in its display
    config database, so extending back restores the layout you already had instead of
    stacking everything at 0,0.

    With no arguments it toggles: more than one active display collapses to the laptop
    panel, otherwise it extends across everything currently connected.

    This switches the Windows display TOPOLOGY (which panels are lit). To switch which
    machine a monitor is showing, see Switch-DeskProfile / swdesk.
    .PARAMETER Mode
    Toggle (default) flips to the opposite of the current state.
    Laptop forces internal-display-only. All forces extend across every connected display.
    .PARAMETER TimeoutSeconds
    How long to wait for displays to settle before reporting. DisplayLink dock monitors are
    the slow ones. Default 15.
    .EXAMPLE
    Switch-MonitorSetup
    .EXAMPLE
    Switch-MonitorSetup -Mode Laptop
    .EXAMPLE
    swmon -Mode All
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('Toggle', 'Laptop', 'All')]
        [string]$Mode = 'Toggle',

        [ValidateRange(0, 120)]
        [int]$TimeoutSeconds = 15
    )

    if (-not ('Native.DisplayConfig' -as [type])) {
        Add-Type -Namespace Native -Name DisplayConfig -MemberDefinition @'
[DllImport("user32.dll")]
public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

[DllImport("user32.dll")]
public static extern int SetDisplayConfig(uint numPathArrayElements, IntPtr pathArray, uint numModeInfoArrayElements, IntPtr modeInfoArray, uint flags);
'@
    }

    $QDC_ONLY_ACTIVE_PATHS = 0x00000002
    $SDC_TOPOLOGY_INTERNAL = 0x00000001
    $SDC_TOPOLOGY_EXTEND = 0x00000004
    $SDC_APPLY = 0x00000080

    function Get-ActiveDisplayCount {
        $paths = 0
        $modes = 0
        $rc = [Native.DisplayConfig]::GetDisplayConfigBufferSizes($QDC_ONLY_ACTIVE_PATHS, [ref]$paths, [ref]$modes)
        if ($rc -ne 0) { throw "GetDisplayConfigBufferSizes failed with code $rc." }
        [int]$paths
    }

    $current = Get-ActiveDisplayCount
    $target = switch ($Mode) {
        'Laptop' { 'Laptop' }
        'All' { 'All' }
        default { if ($current -gt 1) { 'Laptop' } else { 'All' } }
    }

    if ($target -eq 'Laptop') {
        $topology = $SDC_TOPOLOGY_INTERNAL
        $fallbackArg = '/internal'
        $label = 'laptop screen only'
    }
    else {
        $topology = $SDC_TOPOLOGY_EXTEND
        $fallbackArg = '/extend'
        $label = 'all connected displays (extend)'
    }

    if (-not $PSCmdlet.ShouldProcess('display topology', "Switch to $label")) { return }

    Write-Host "Switching to $label (currently $current active)..." -ForegroundColor Cyan

    $rc = [Native.DisplayConfig]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, $topology -bor $SDC_APPLY)
    if ($rc -ne 0) {
        Write-Verbose "SetDisplayConfig returned $rc; falling back to DisplaySwitch.exe $fallbackArg"
        Start-Process -FilePath "$env:SystemRoot\System32\DisplaySwitch.exe" -ArgumentList $fallbackArg -Wait
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $now = Get-ActiveDisplayCount
        $settled = if ($target -eq 'Laptop') { $now -eq 1 } else { $now -gt 1 }
    } until ($settled -or (Get-Date) -ge $deadline)

    if ($settled) {
        Write-Host "Now driving $now display$(if ($now -ne 1) { 's' })." -ForegroundColor Green
    }
    else {
        Write-Warning "Asked for '$label' but $now display(s) are active after ${TimeoutSeconds}s. DisplayLink screens can lag - re-run, or use Restart-Monitors if they stay dark."
    }
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
            $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'Upgrade-CodeQL' } -ErrorAction Stop
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
    $asset = $release.assets | Where-Object name -EQ "codeql-bundle-win64.tar.gz" | Select-Object -First 1
    if (-not $asset) {
        Write-Host "Release $bundleTag does not contain codeql-bundle-win64.tar.gz." -ForegroundColor Red
        return
    }
    $downloadUrl = $asset.browser_download_url
    $expectedArchiveSize = [long]$asset.size
    $archive     = Join-Path $env:TEMP "codeql-bundle-win64-$cliVersionNumber.tar.gz"

    $archiveSize = if (Test-Path $archive) { (Get-Item $archive).Length } else { 0 }
    if ($archiveSize -eq $expectedArchiveSize) {
        Write-Host "Reusing downloaded bundle $archive" -ForegroundColor Green
    } else {
        if ($archiveSize -gt 0 -and $archiveSize -lt $expectedArchiveSize) {
            Write-Host "Resuming partial download $archive ($archiveSize of $expectedArchiveSize bytes)..." -ForegroundColor Cyan
            curl.exe -L --fail --continue-at - -o $archive $downloadUrl
        } else {
            if ($archiveSize -gt $expectedArchiveSize) {
                Write-Host "Cached bundle has an unexpected size; downloading it again." -ForegroundColor Yellow
                Remove-Item $archive -Force
            }
            Write-Host "Downloading $downloadUrl" -ForegroundColor Cyan
            curl.exe -L --fail -o $archive $downloadUrl
        }

        $downloadedSize = if (Test-Path $archive) { (Get-Item $archive).Length } else { 0 }
        if ($LASTEXITCODE -ne 0 -or $downloadedSize -ne $expectedArchiveSize) {
            Write-Host "Download is incomplete ($downloadedSize of $expectedArchiveSize bytes). Re-run Upgrade-CodeQL to resume it." -ForegroundColor Red
            return
        }
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
        try {
            Rename-Item -Path $InstallPath -NewName $leafOld
        } catch {
            $installRoot = $InstallPath.TrimEnd('\')
            $lockingProcesses = @(
                Get-CimInstance Win32_Process | Where-Object {
                    ($_.ExecutablePath -and (
                        $_.ExecutablePath.Equals($codeqlExe, [StringComparison]::OrdinalIgnoreCase) -or
                        $_.ExecutablePath.StartsWith("$installRoot\", [StringComparison]::OrdinalIgnoreCase)
                    )) -or
                    ($_.CommandLine -and
                        $_.CommandLine.IndexOf($installRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0)
                }
            )

            if (-not $lockingProcesses) {
                Write-Host "Could not identify a process using $InstallPath." -ForegroundColor Red
                Write-Host "Rename failed: $($_.Exception.Message)" -ForegroundColor Red
                return
            }

            Write-Host "The following process(es) are using the CodeQL installation:" -ForegroundColor Yellow
            foreach ($process in $lockingProcesses) {
                Write-Host ""
                Write-Host "PID:        $($process.ProcessId)" -ForegroundColor Yellow
                Write-Host "Name:       $($process.Name)"
                Write-Host "Executable: $($process.ExecutablePath)"
                Write-Host "Command:    $($process.CommandLine)"
            }

            $answer = Read-Host "`nKill these process(es) and retry the upgrade? [Y/N]"
            if ($answer -notmatch '^(?i:y|yes)$') {
                Write-Host "Upgrade cancelled. The downloaded bundle remains cached at $archive." -ForegroundColor Yellow
                return
            }

            foreach ($process in $lockingProcesses) {
                Write-Host "Stopping PID $($process.ProcessId) ($($process.Name))..." -ForegroundColor Cyan
                Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            }
            Start-Sleep -Milliseconds 500

            try {
                Rename-Item -Path $InstallPath -NewName $leafOld
            } catch {
                Write-Host "Rename still failed after stopping the identified processes: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "The downloaded bundle remains cached at $archive." -ForegroundColor Yellow
                return
            }
        }
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
    Write-Host "Keeping downloaded bundle cached at $archive" -ForegroundColor DarkGray

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

# ─── Aliases ───────────────────────────────────────────────────────
# Short forms for the custom functions above. Where a function uses an approved
# verb, the alias follows PowerShell's own convention of verb AliasPrefix (see
# Get-Verb) plus a noun abbreviation - so Restart-* is rt*, Update-* is ud*,
# Get-* is g*, Set-* is s*, matching swmon for Switch-MonitorSetup.
# All were checked against Get-Command for collisions before being added.
$aliasMap = [ordered]@{
    # Monitors
    'swmon'               = 'Switch-MonitorSetup'
    'Switch-Monitor-Setup' = 'Switch-MonitorSetup'
    'rtmon'               = 'Restart-Monitors'

    # Copilot CLI wrappers
    'cpall'               = 'copilot-all'
    'cpghas'              = 'copilot-ghas'
    'cpdep'               = 'copilot-depcheck'

    # Updates
    'ccu'                 = 'Check-CopilotUpdates'
    'gcop'                = 'Get-CopilotProcess'
    'udgh'                = 'Update-GhExtensions'
    'udcp'                = 'Update-CopilotPlugins'
    'upql'                = 'Upgrade-CodeQL'

    # Misc
    'rtexp'               = 'Restart-Explorer'
    'nsk'                 = 'New-StripeKeyMock'
    'elapsed'             = 'Get-LastCommandExecutionTime'
    'glct'                = 'Get-LastCommandExecutionTime'
}
foreach ($alias in $aliasMap.GetEnumerator()) {
    Set-Alias -Name $alias.Key -Value $alias.Value -Scope Global -Force
}

# ─── Profile Summary ───────────────────────────────────────────────
Write-Host ""
Write-Host "── Custom Functions ──────────────────────────────────────" -ForegroundColor DarkGray
$functions = @(
    @{ Alias = "nsk";     Name = "New-StripeKeyMock";            Desc = "Generate mock Stripe API key" }
    @{ Alias = "";        Name = "b64";                          Desc = "Base64 encode/decode (b64 'hi' | b64 -Decode 'aGk=')" }
    @{ Alias = "elapsed"; Name = "Get-LastCommandExecutionTime";  Desc = "Show duration of last command" }
    @{ Alias = "cpall";   Name = "copilot-all";                  Desc = "Copilot CLI with all MCP toolsets" }
    @{ Alias = "cpghas";  Name = "copilot-ghas";                 Desc = "Copilot CLI with GHAS MCP toolsets" }
    @{ Alias = "cpdep";   Name = "copilot-depcheck";             Desc = "Copilot CLI with Dependabot dep vulnerability scanning" }
    @{ Alias = "rtexp";   Name = "Restart-Explorer";             Desc = "Kill and restart Windows Explorer + itype.exe" }
    @{ Alias = "rtmon";   Name = "Restart-Monitors";             Desc = "Wake USB-C dock monitors stuck after sleep (admin)" }
    @{ Alias = "swmon";   Name = "Switch-MonitorSetup";          Desc = "Toggle multi-monitor extend <-> laptop screen only" }
    @{ Alias = "swdesk";  Name = "Switch-DeskProfile";           Desc = "Point monitors at a machine: swdesk main | mac | personal" }
    @{ Alias = "gmin";    Name = "Get-MonitorInput";             Desc = "Show each monitor's role, current input (-Detailed = supported inputs)" }
    @{ Alias = "smin";    Name = "Set-MonitorInput";             Desc = "Set one monitor's input, e.g. smin -Role Right -Source HDMI" }
    @{ Alias = "gmb";     Name = "Get-MonitorBrightness";        Desc = "Show brightness/contrast of every monitor + the laptop panel" }
    @{ Alias = "smb";     Name = "Set-MonitorBrightness";        Desc = "Set brightness, e.g. smb -Percent 40 | smb -Role Center -Percent 65" }
    @{ Alias = "syncbr";  Name = "Sync-MonitorBrightness";       Desc = "Match externals to the laptop panel now (-Offset biases them)" }
    @{ Alias = "";        Name = "Start-BrightnessFollow";       Desc = "Externals track the laptop brightness keys (Register-BrightnessFollow = at logon)" }
    @{ Alias = "";        Name = "Start-DeskFollow";             Desc = "Claim this machine's monitors when you type here (Register-DeskFollow = at logon)" }
    @{ Alias = "ccu";     Name = "Check-CopilotUpdates";         Desc = "Check for Copilot CLI updates" }
    @{ Alias = "gcop";    Name = "Get-CopilotProcess";           Desc = "Copilot CLI/app instances holding the shared plugin git cache" }
    @{ Alias = "udgh";    Name = "Update-GhExtensions";          Desc = "Update gh CLI extensions (skipped while Copilot runs; -Force)" }
    @{ Alias = "udcp";    Name = "Update-CopilotPlugins";        Desc = "Update Copilot CLI plugins (skipped while Copilot runs; -Force)" }
    @{ Alias = "upql";    Name = "Upgrade-CodeQL";               Desc = "Install latest (or -Version pinned) CodeQL bundle + sync ql submodule ref" }
)
foreach ($f in $functions) {
    Write-Host "  " -NoNewline
    Write-Host ("{0,-9}" -f $f.Alias) -ForegroundColor Yellow -NoNewline
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
