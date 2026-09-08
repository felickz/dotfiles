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

function Get-ExternalCamera {
    <#
    .SYNOPSIS
    Lists camera devices that are not built into this machine.
    .DESCRIPTION
    Windows assigns every device built into the chassis the well-known "system container"
    ID {00000000-0000-0000-FFFF-FFFFFFFFFFFF}. Anything plugged in gets its own container
    GUID, so comparing against that constant reliably separates the laptop's own webcam
    from dock/monitor-mounted ones - without hardcoding vendor IDs.

    Matching on manufacturer would not work here: the iContact Camera Pro reports its
    Manufacturer as "Microsoft", identical to the built-in Surface camera.

    Covers both the Camera and Image device classes, since UVC webcams register under
    either one depending on their driver.
    #>
    [CmdletBinding()]
    param()

    $systemContainer = '{00000000-0000-0000-FFFF-FFFFFFFFFFFF}'

    Get-PnpDevice -Class Camera, Image -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
        # Read ContainerID straight from the device's Enum key. Get-PnpDeviceProperty
        # yields the identical value but fires a separate CIM query per device, which
        # measured ~25s for five cameras against ~0.1s here - and this runs twice per
        # toggle. Fall back to the CIM call only if the registry read fails, since a
        # few Enum keys carry restrictive ACLs.
        $container = Get-ItemPropertyValue -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$($_.InstanceId)" -Name 'ContainerID' -ErrorAction SilentlyContinue
        if (-not $container) {
            $container = (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_ContainerId' -ErrorAction SilentlyContinue).Data
        }
        $container -and $container -ne $systemContainer
    }
}

# Phone-as-webcam / other virtual cameras (e.g. the Pixel showing up via Phone Link).
# Windows ships no policy or registry switch that disables just the connected camera -
# the only documented control is Settings > Bluetooth & devices > Mobile devices >
# [your phone] > "Use as a connected camera". Set this to $true if that toggle will not
# stick, and swmon will keep virtual cameras disabled in BOTH monitor modes. Left $false
# by default so Phone Link (notifications, messages, calls) is untouched out of the box.
$Global:SwmonDisableVirtualCameras = $false

function Get-VirtualCamera {
    <#
    .SYNOPSIS
    Lists software/virtual camera devices, such as a phone exposed as a webcam.
    .DESCRIPTION
    These are not physical cameras, so they do not carry a real device container and are
    invisible to Get-ExternalCamera. They register under SWD\VCAMDEVAPI, which is matched
    here deliberately narrowly: sibling software nodes like SWD\SGDEVAPI (Surface Camera
    Sensor Group) and SWD\DRIVERENUM (Windows Studio Effects) back the built-in camera and
    must be left alone.
    #>
    [CmdletBinding()]
    param()

    Get-PnpDevice -Class SoftwareDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'SWD\VCAMDEVAPI\*' }
}

function Set-ExternalCameraState {
    <#
    .SYNOPSIS
    Enables or disables every external (non-built-in) camera.
    .DESCRIPTION
    Toggling PnP devices needs admin, so this elevates via UAC - but only when there is
    actually something to change, so a no-op never prompts.

    When disabling, the instance IDs are recorded to a state file; re-enabling touches
    only those, so a camera you deliberately disabled yourself stays disabled. If the
    state file is missing, it falls back to re-enabling all disabled external cameras.

    Only the camera/video interfaces are touched. A composite webcam's microphone
    interface is left alone so disabling the video does not also kill its mic.
    .PARAMETER State
    Enabled or Disabled.
    .PARAMETER Quiet
    Suppress the informational output.
    .EXAMPLE
    Set-ExternalCameraState -State Disabled
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Enabled', 'Disabled')]
        [string]$State,

        [switch]$IncludeVirtual,

        [switch]$Quiet
    )

    $stateFile = Join-Path $env:LOCALAPPDATA 'switch-monitorsetup-cameras.json'
    $cameras = @(Get-ExternalCamera)
    $virtual = if ($IncludeVirtual) { @(Get-VirtualCamera) } else { @() }

    if (-not $cameras -and -not $virtual) {
        if (-not $Quiet) { Write-Host "  No external cameras detected." -ForegroundColor DarkGray }
        return
    }

    # Physical external cameras follow the requested state.
    if ($State -eq 'Disabled') {
        $toDisable = @($cameras | Where-Object { $_.Status -eq 'OK' })
        $toEnable = @()
    }
    else {
        $remembered = if (Test-Path $stateFile) {
            @(Get-Content $stateFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json)
        }
        else { @() }

        $toEnable = if ($remembered) {
            @($cameras | Where-Object { $_.InstanceId -in $remembered -and $_.Status -ne 'OK' })
        }
        else {
            @($cameras | Where-Object { $_.Status -ne 'OK' })
        }
        $toDisable = @()
    }

    # Virtual cameras are never re-enabled - they stay off in both modes, which is the
    # whole point of the opt-in. They are also kept out of the state file so the enable
    # path can never resurrect them.
    $toDisable += @($virtual | Where-Object { $_.Status -eq 'OK' })

    if (-not $toDisable -and -not $toEnable) {
        if (-not $Quiet) { Write-Host "  External cameras already $($State.ToLower())." -ForegroundColor DarkGray }
        if ($State -eq 'Enabled') { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
        return
    }

    $names = (@($toDisable) + @($toEnable) | ForEach-Object { $_.FriendlyName } | Select-Object -Unique) -join ', '
    if (-not $PSCmdlet.ShouldProcess($names, "Set external camera state to $State")) { return }

    if ($State -eq 'Disabled' -and $cameras) {
        @($cameras | Where-Object { $_.Status -eq 'OK' }).InstanceId |
            ConvertTo-Json -Depth 3 | Set-Content -Path $stateFile -Encoding utf8
    }

    $asLiteral = {
        param($items)
        if (-not $items) { return '@()' }
        '@(' + (($items.InstanceId | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ',') + ')'
    }

    $payload = @'
$ErrorActionPreference = 'Continue'
$log = Join-Path $env:TEMP 'switch-monitorsetup-cameras.log'
"Camera change: $(Get-Date -Format o)" | Set-Content -Path $log
foreach ($id in __DISABLE__) {
    try {
        Disable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop
        "DISABLED $id" | Add-Content -Path $log
    }
    catch {
        "FAIL-DISABLE $id :: $($_.Exception.Message)" | Add-Content -Path $log
    }
}
foreach ($id in __ENABLE__) {
    try {
        Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop
        "ENABLED  $id" | Add-Content -Path $log
    }
    catch {
        "FAIL-ENABLE $id :: $($_.Exception.Message)" | Add-Content -Path $log
    }
}
'@
    $payload = $payload.Replace('__DISABLE__', (& $asLiteral $toDisable)).Replace('__ENABLE__', (& $asLiteral $toEnable))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))

    $count = @($toDisable).Count + @($toEnable).Count
    Write-Host "  UAC prompt sent - approve to update $count camera interface(s): $names" -ForegroundColor Yellow

    # Windows PowerShell rather than pwsh: the PnpDevice module is native there, so it
    # avoids the slower/flakier WinPS compatibility shim in PowerShell 7.
    $proc = Start-Process powershell.exe -Verb RunAs -Wait -PassThru `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded

    if ($proc.ExitCode -ne 0) {
        Write-Warning "Camera change did not complete (exit code $($proc.ExitCode)). See $env:TEMP\switch-monitorsetup-cameras.log"
        return
    }

    $stillOn = @(Get-ExternalCamera | Where-Object { $_.Status -eq 'OK' })
    $virtualOn = @(Get-VirtualCamera | Where-Object { $_.Status -eq 'OK' })

    if ($State -eq 'Disabled') {
        if ($stillOn) {
            Write-Warning "Still enabled: $(($stillOn.FriendlyName | Select-Object -Unique) -join ', '). A camera in use by an app can refuse to disable."
        }
        else {
            Write-Host "  External cameras disabled - laptop camera only." -ForegroundColor Green
        }
    }
    else {
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
        Write-Host "  External cameras re-enabled ($($stillOn.Count) interface(s) live)." -ForegroundColor Green
    }

    if ($IncludeVirtual) {
        if ($virtualOn) {
            Write-Warning "Virtual camera still present: $(($virtualOn.FriendlyName | Select-Object -Unique) -join ', '). Windows can re-register it; turn it off at Settings > Bluetooth & devices > Mobile devices."
        }
        else {
            Write-Host "  Virtual cameras disabled." -ForegroundColor Green
        }
    }
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

    External cameras follow the displays. Dropping to laptop-only disables every camera
    that is not built into the chassis, so the laptop webcam is the only one left - no
    more dock-mounted camera pointing up at you from desk height. Extending back
    re-enables them. That part needs admin, so it raises a UAC prompt, but only when
    there is actually a camera to change. Use -SkipCameras to leave cameras alone.

    Virtual cameras (phone-as-webcam) are separate: set $SwmonDisableVirtualCameras = $true
    and they are disabled in BOTH modes, never re-enabled.
    .PARAMETER Mode
    Toggle (default) flips to the opposite of the current state.
    Laptop forces internal-display-only. All forces extend across every connected display.
    .PARAMETER TimeoutSeconds
    How long to wait for displays to settle before reporting. DisplayLink dock monitors are
    the slow ones. Default 15.
    .PARAMETER SkipCameras
    Switch displays only; do not touch external cameras (and never prompt for UAC).
    .EXAMPLE
    Switch-MonitorSetup
    .EXAMPLE
    Switch-MonitorSetup -Mode Laptop
    .EXAMPLE
    swmon -Mode All
    .EXAMPLE
    swmon -SkipCameras
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('Toggle', 'Laptop', 'All')]
        [string]$Mode = 'Toggle',

        [ValidateRange(0, 120)]
        [int]$TimeoutSeconds = 15,

        [switch]$SkipCameras
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

    # Cameras after the displays, so any UAC prompt lands on a screen that stays on.
    if (-not $SkipCameras) {
        Set-ExternalCameraState `
            -State $(if ($target -eq 'Laptop') { 'Disabled' } else { 'Enabled' }) `
            -IncludeVirtual:$Global:SwmonDisableVirtualCameras
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

# ─── Aliases ───────────────────────────────────────────────────────
# Short forms for the custom functions above. Where a function uses an approved
# verb, the alias follows PowerShell's own convention of verb AliasPrefix (see
# Get-Verb) plus a noun abbreviation - so Restart-* is rt*, Update-* is ud*,
# Get-* is g*, Set-* is s*, matching swmon for Switch-MonitorSetup.
# All were checked against Get-Command for collisions before being added.
$aliasMap = [ordered]@{
    # Monitors + cameras
    'swmon'               = 'Switch-MonitorSetup'
    'Switch-Monitor-Setup' = 'Switch-MonitorSetup'
    'rtmon'               = 'Restart-Monitors'
    'gcam'                = 'Get-ExternalCamera'
    'gvcam'               = 'Get-VirtualCamera'
    'scam'                = 'Set-ExternalCameraState'

    # Copilot CLI wrappers
    'cpall'               = 'copilot-all'
    'cpghas'              = 'copilot-ghas'
    'cpdep'               = 'copilot-depcheck'

    # Updates
    'ccu'                 = 'Check-CopilotUpdates'
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
    @{ Alias = "swmon";   Name = "Switch-MonitorSetup";          Desc = "Toggle 4-monitor extend <-> laptop screen only + external cams" }
    @{ Alias = "scam";    Name = "Set-ExternalCameraState";      Desc = "Enable/disable all non-built-in cameras (admin)" }
    @{ Alias = "gcam";    Name = "Get-ExternalCamera";           Desc = "List non-built-in cameras" }
    @{ Alias = "gvcam";   Name = "Get-VirtualCamera";            Desc = "List virtual cameras (phone-as-webcam); see `$SwmonDisableVirtualCameras" }
    @{ Alias = "ccu";     Name = "Check-CopilotUpdates";         Desc = "Check for Copilot CLI updates" }
    @{ Alias = "udgh";    Name = "Update-GhExtensions";          Desc = "Update gh CLI extensions" }
    @{ Alias = "udcp";    Name = "Update-CopilotPlugins";        Desc = "Update Copilot CLI plugins" }
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
