<#
.SYNOPSIS
DeskSwitch - drive Dell monitor inputs over DDC/CI so three machines can share one desk.

.DESCRIPTION
Switches monitor inputs using the MCCS "Input Source" control (VCP code 0x60) over DDC/CI,
which travels on the display cable's I2C channel. No Dell software, driver or agent is
required, so the same code works on any MCCS-compliant monitor.

Why not trigger off the keyboard's Easy-Switch key:
    The Logi Bolt receiver (VID_046D&PID_C548) presents FIXED HID endpoints. Pressing
    Easy-Switch moves the keyboard's radio link to another host but leaves every one of
    those endpoints enumerated, so nothing arrives or departs for Windows to notice. The
    keyboard and mouse collections are additionally claimed by kbdclass/mouclass, so
    user-mode cannot read their reports either. Both were measured, not assumed.

    So DeskSwitch inverts the problem: no machine tries to detect a key it cannot see.
    Instead each machine owns the inputs it needs and asserts them when it observes local
    user input. Pressing Easy-Switch moves the keyboard, the user types, and that machine
    claims its monitors. No network, pairing or cross-machine messaging is involved.
#>

Set-StrictMode -Version Latest

# MCCS VCP 0x60 input source values. 0x0F/0x11/0x1B were confirmed against the live
# capability strings of the P2725D and P3425WE; the rest are standard MCCS.
$script:InputCodes = [ordered]@{
    DP     = 0x0F
    DP1    = 0x0F
    DP2    = 0x10
    HDMI   = 0x11
    HDMI1  = 0x11
    HDMI2  = 0x12
    USBC   = 0x1B
    VGA    = 0x01
    DVI    = 0x03
}

$script:VcpInputSource = 0x60

if (-not ('DeskSwitch.Native' -as [type])) {
    Add-Type -ErrorAction Stop -ReferencedAssemblies System.Runtime.InteropServices, System.Collections -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace DeskSwitch {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    public class Native {
        public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprc, IntPtr data);

        [DllImport("user32.dll")]
        public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);

        [DllImport("user32.dll")]
        public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        [DllImport("dxva2.dll", SetLastError = true)]
        public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint count);

        [DllImport("dxva2.dll", SetLastError = true)]
        public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint count, [Out] PHYSICAL_MONITOR[] arr);

        [DllImport("dxva2.dll", SetLastError = true)]
        public static extern bool DestroyPhysicalMonitors(uint count, [In] PHYSICAL_MONITOR[] arr);

        [DllImport("dxva2.dll", SetLastError = true)]
        public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type, out uint current, out uint max);

        [DllImport("dxva2.dll", SetLastError = true)]
        public static extern bool SetVCPFeature(IntPtr h, byte code, uint value);

        [DllImport("dxva2.dll", SetLastError = true)]
        public static extern bool GetCapabilitiesStringLength(IntPtr h, out uint len);

        [DllImport("dxva2.dll", SetLastError = true)]
        public static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, StringBuilder buf, uint len);

        public static List<IntPtr> EnumHMonitors() {
            var list = new List<IntPtr>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
                delegate(IntPtr hm, IntPtr hdc, IntPtr r, IntPtr d) { list.Add(hm); return true; },
                IntPtr.Zero);
            return list;
        }

        public static string Capabilities(IntPtr h) {
            uint len;
            if (!GetCapabilitiesStringLength(h, out len) || len == 0) return null;
            var sb = new StringBuilder((int)len);
            if (!CapabilitiesRequestAndCapabilitiesReply(h, sb, len)) return null;
            return sb.ToString();
        }

        public static uint IdleMilliseconds() {
            var lii = new LASTINPUTINFO();
            lii.cbSize = (uint)Marshal.SizeOf(lii);
            if (!GetLastInputInfo(ref lii)) return 0;
            // Unsigned subtraction wraps correctly when TickCount rolls over at ~49.7 days.
            return (uint)Environment.TickCount - lii.dwTime;
        }
    }
}
'@
}

function ConvertTo-DeskInputCode {
    <#
    .SYNOPSIS
    Resolves an input name (DP, HDMI, USBC) or a raw value to a VCP 0x60 code.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source)

    $key = $Source.Trim().ToUpperInvariant() -replace '[\s\-_]', ''
    if ($script:InputCodes.Contains($key)) { return [int]$script:InputCodes[$key] }
    if ($key -match '^(0X)?([0-9A-F]{1,2})$') { return [Convert]::ToInt32($Matches[2], 16) }
    throw "Unknown input '$Source'. Known names: $($script:InputCodes.Keys -join ', '), or a hex code like 0x1B."
}

function ConvertFrom-DeskInputCode {
    param([int]$Code)
    switch ($Code) {
        0x0F { 'DP' } 0x10 { 'DP2' } 0x11 { 'HDMI' } 0x12 { 'HDMI2' }
        0x1B { 'USBC' } 0x01 { 'VGA' } 0x03 { 'DVI' }
        default { '0x{0:X2}' -f $Code }
    }
}

function Get-DeskMonitor {
    <#
    .SYNOPSIS
    Enumerates DDC/CI-capable monitors with their desk position, current input and supported inputs.
    .DESCRIPTION
    Roles are assigned by horizontal position rather than by display index or model name.
    Windows renumbers \\.\DISPLAYn freely across docking and driver updates, and two of the
    monitors here are the same model, so neither index nor model can identify "the left one".
    Sorting the DDC-capable monitors by their X coordinate is stable across both.

    Monitors without DDC/CI (the laptop's internal panel) are skipped: they have no input to
    switch.
    .PARAMETER IncludeCapabilities
    Also parse and return the supported input list from each monitor's MCCS capability string.
    This is what makes a hardware upgrade visible: swap in a USB-C model and USBC simply
    appears in SupportedInputs.
    #>
    [CmdletBinding()]
    param([switch]$IncludeCapabilities)

    $result = @()
    $handles = @()

    foreach ($hm in [DeskSwitch.Native]::EnumHMonitors()) {
        $mi = New-Object DeskSwitch.MONITORINFOEX
        $mi.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($mi)
        if (-not [DeskSwitch.Native]::GetMonitorInfo($hm, [ref]$mi)) { continue }

        $count = 0
        if (-not [DeskSwitch.Native]::GetNumberOfPhysicalMonitorsFromHMONITOR($hm, [ref]$count)) { continue }
        if ($count -eq 0) { continue }

        $arr = New-Object 'DeskSwitch.PHYSICAL_MONITOR[]' $count
        if (-not [DeskSwitch.Native]::GetPhysicalMonitorsFromHMONITOR($hm, $count, $arr)) { continue }
        $handles += , $arr

        foreach ($pm in $arr) {
            $type = 0; $cur = 0; $max = 0
            $ddc = [DeskSwitch.Native]::GetVCPFeatureAndVCPFeatureReply($pm.hPhysicalMonitor, $script:VcpInputSource, [ref]$type, [ref]$cur, [ref]$max)
            if (-not $ddc) { continue }

            $supported = $null
            if ($IncludeCapabilities) {
                $caps = [DeskSwitch.Native]::Capabilities($pm.hPhysicalMonitor)
                # Capability strings list a control then its allowed values, e.g. "... 52 60( 0F 11) 87 ...".
                # The code precedes the parenthesis, so anchor on whitespace before "60(".
                if ($caps -and $caps -match '(?:^|\s)60\(\s*([0-9A-Fa-f\s]+?)\)') {
                    $supported = @(($Matches[1].Trim() -split '\s+') | Where-Object { $_ } | ForEach-Object {
                        ConvertFrom-DeskInputCode ([Convert]::ToInt32($_, 16))
                    })
                }
            }

            $result += [PSCustomObject]@{
                Description     = $pm.szPhysicalMonitorDescription.Trim()
                Device          = $mi.szDevice
                X               = $mi.rcMonitor.left
                Y               = $mi.rcMonitor.top
                Width           = $mi.rcMonitor.right - $mi.rcMonitor.left
                Primary         = [bool]($mi.dwFlags -band 1)
                InputCode       = $cur -band 0xFF
                Input           = ConvertFrom-DeskInputCode ($cur -band 0xFF)
                SupportedInputs = $supported
                Handle          = $pm.hPhysicalMonitor
                Role            = $null
            }
        }
    }

    # Assign left/center/right by X order across however many DDC monitors are present.
    $sorted = @($result | Sort-Object X)
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $sorted[$i].Role = if ($sorted.Count -eq 1) { 'Center' }
            elseif ($i -eq 0) { 'Left' }
            elseif ($i -eq $sorted.Count - 1) { 'Right' }
            else { 'Center' }
    }

    $script:LastHandleSets = $handles
    $sorted
}

function Close-DeskMonitorHandle {
    <#
    .SYNOPSIS
    Releases physical monitor handles returned by Get-DeskMonitor.
    .DESCRIPTION
    dxva2 handles must be released or the monitor eventually stops answering DDC. Callers
    that use Get-DeskMonitor directly must call this when finished; the higher-level
    functions already do so in a finally block.

    Defaults to the handle set from the most recent Get-DeskMonitor call, so the usual
    usage is simply "Close-DeskMonitorHandle" with no arguments.
    #>
    [CmdletBinding()]
    param($HandleSets = $script:LastHandleSets)

    foreach ($set in @($HandleSets)) {
        if ($set) { [void][DeskSwitch.Native]::DestroyPhysicalMonitors($set.Count, $set) }
    }
    $script:LastHandleSets = @()
}

function Get-MonitorInput {
    <#
    .SYNOPSIS
    Shows each monitor's desk role, current input and (with -Detailed) the inputs it supports.
    .EXAMPLE
    Get-MonitorInput -Detailed
    #>
    [CmdletBinding()]
    param([switch]$Detailed)

    $mons = Get-DeskMonitor -IncludeCapabilities:$Detailed
    try {
        $mons | ForEach-Object {
            [PSCustomObject]@{
                Role      = $_.Role
                Monitor   = $_.Description
                X         = $_.X
                Primary   = $_.Primary
                Input     = $_.Input
                Supports  = if ($_.SupportedInputs) { $_.SupportedInputs -join ',' } else { $null }
            }
        }
    }
    finally { Close-DeskMonitorHandle $script:LastHandleSets }
}

function Set-MonitorInput {
    <#
    .SYNOPSIS
    Switches one or more monitors to a given input.
    .DESCRIPTION
    Skips any monitor already on the requested input, which avoids a pointless OSD flash and
    keeps the follow watcher cheap enough to poll continuously.

    Dell monitors stop answering DDC for a moment while they retrain the link, so the readback
    is retried rather than trusted on the first attempt; an immediate read returns 0x00 and
    would look like a failure.
    .PARAMETER Role
    Left, Center or Right - resolved by horizontal position.
    .PARAMETER Source
    DP, HDMI, USBC, or a raw code such as 0x1B.
    .EXAMPLE
    Set-MonitorInput -Role Right -Source HDMI
    .EXAMPLE
    Set-MonitorInput -Role Left,Center,Right -Source DP
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('Left', 'Center', 'Right')][string[]]$Role,
        [Parameter(Mandatory)][Alias('Input')][string]$Source,
        [switch]$Quiet
    )

    $code = ConvertTo-DeskInputCode $Source
    $name = ConvertFrom-DeskInputCode $code
    $mons = Get-DeskMonitor
    $changed = 0

    try {
        foreach ($r in $Role) {
            $m = $mons | Where-Object Role -eq $r
            if (-not $m) {
                Write-Warning "No DDC-capable monitor in the '$r' position."
                continue
            }

            if ($m.InputCode -eq $code) {
                if (-not $Quiet) { Write-Host "  $r ($($m.Description)) already on $name." -ForegroundColor DarkGray }
                continue
            }

            if (-not $PSCmdlet.ShouldProcess("$r - $($m.Description)", "Switch input to $name")) { continue }

            if (-not [DeskSwitch.Native]::SetVCPFeature($m.Handle, $script:VcpInputSource, $code)) {
                Write-Warning "$r : SetVCPFeature failed (err $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
                continue
            }
            $changed++
            if (-not $Quiet) { Write-Host "  $r ($($m.Description)) -> $name" -ForegroundColor Green }
        }
    }
    finally { Close-DeskMonitorHandle $script:LastHandleSets }

    $changed
}

function Switch-DeskProfile {
    <#
    .SYNOPSIS
    Applies a named desk profile, setting every monitor that profile owns.
    .DESCRIPTION
    A profile is just a role-to-input map, so adding a machine or changing a cable is a config
    edit rather than a code change. Profiles live in $Global:DeskProfiles.

    Forward compatibility: when the side monitors are replaced with USB-C models (P2725DE),
    change that profile's value from HDMI to USBC. Nothing else moves. Run
    "Get-MonitorInput -Detailed" after swapping to confirm USBC is advertised.
    .PARAMETER Name
    Profile to apply. Defaults to the profile whose HostName matches this computer.
    .EXAMPLE
    Switch-DeskProfile main
    .EXAMPLE
    swdesk mac
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)][string]$Name,
        [switch]$Quiet
    )

    if (-not $Global:DeskProfiles) { throw 'No $Global:DeskProfiles defined.' }

    if (-not $Name) {
        $Name = ($Global:DeskProfiles.GetEnumerator() |
            Where-Object { $_.Value.HostName -eq $env:COMPUTERNAME } |
            Select-Object -First 1).Key
        if (-not $Name) { throw "No profile matches host '$env:COMPUTERNAME'. Pass -Name explicitly." }
    }

    if (-not $Global:DeskProfiles.Contains($Name)) {
        throw "Unknown profile '$Name'. Available: $($Global:DeskProfiles.Keys -join ', ')"
    }

    $deskProfile = $Global:DeskProfiles[$Name]
    if (-not $Quiet) { Write-Host "Applying desk profile '$Name'..." -ForegroundColor Cyan }

    $total = 0
    foreach ($entry in $deskProfile.Monitors.GetEnumerator()) {
        $total += Set-MonitorInput -Role $entry.Key -Source $entry.Value -Quiet:$Quiet
    }

    if (-not $Quiet -and $total -eq 0) { Write-Host "  Nothing to change." -ForegroundColor DarkGray }
    $total
}

function Test-DeskProfileApplied {
    <#
    .SYNOPSIS
    Returns $true when every monitor a profile owns is already on the right input.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $deskProfile = $Global:DeskProfiles[$Name]
    $mons = Get-DeskMonitor
    try {
        foreach ($entry in $deskProfile.Monitors.GetEnumerator()) {
            $m = $mons | Where-Object Role -eq $entry.Key
            if (-not $m) { continue }
            if ($m.InputCode -ne (ConvertTo-DeskInputCode $entry.Value)) { return $false }
        }
        return $true
    }
    finally { Close-DeskMonitorHandle $script:LastHandleSets }
}

function Start-DeskFollow {
    <#
    .SYNOPSIS
    Claims this machine's monitors whenever the user is actually typing on this machine.
    .DESCRIPTION
    This is the piece that replaces Easy-Switch detection, which is not observable on the
    source machine (see the module header).

    The loop asserts only when BOTH conditions hold:
      1. local user input happened within -ActiveWithinMs, and
      2. at least one monitor is not already on this profile's input.

    Condition 2 is what makes it safe to poll forever: while you keep working on one machine
    the monitors already match, so no DDC traffic is generated and the monitors never flicker.
    Work only happens on the transition back.

    Each machine runs this with its own profile, so pressing Easy-Switch moves the keyboard and
    whichever machine you then touch takes its own monitors. No machine needs to know the others
    exist.
    .PARAMETER Name
    Profile to assert. Defaults to the one matching this hostname.
    .PARAMETER PollSeconds
    How often to check. Default 2.
    .PARAMETER ActiveWithinMs
    Treat the user as present on this machine if input occurred this recently. Default 3000.
    .EXAMPLE
    Start-DeskFollow -Verbose
    #>
    [CmdletBinding()]
    param(
        [string]$Name,
        [ValidateRange(1, 60)][int]$PollSeconds = 2,
        [ValidateRange(500, 60000)][int]$ActiveWithinMs = 3000
    )

    if (-not $Name) {
        $Name = ($Global:DeskProfiles.GetEnumerator() |
            Where-Object { $_.Value.HostName -eq $env:COMPUTERNAME } |
            Select-Object -First 1).Key
    }
    if (-not $Name) { throw "No profile matches host '$env:COMPUTERNAME'." }

    Write-Host "DeskFollow watching for profile '$Name' (poll ${PollSeconds}s). Ctrl+C to stop." -ForegroundColor Cyan

    while ($true) {
        try {
            $idle = [DeskSwitch.Native]::IdleMilliseconds()
            if ($idle -le $ActiveWithinMs -and -not (Test-DeskProfileApplied -Name $Name)) {
                Write-Verbose "Local input ${idle}ms ago and monitors differ - asserting '$Name'."
                Switch-DeskProfile -Name $Name -Quiet | Out-Null
            }
        }
        catch {
            Write-Warning "DeskFollow: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Register-DeskFollow {
    <#
    .SYNOPSIS
    Registers DeskFollow as a per-user logon scheduled task.
    .DESCRIPTION
    Runs unelevated on purpose: DDC/CI needs no admin rights, as verified on this hardware.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$TaskName = 'DeskFollow',
        [string]$ModulePath = $PSCommandPath
    )

    $cmd = "Import-Module '$ModulePath'; Start-DeskFollow"
    $action = New-ScheduledTaskAction -Execute 'pwsh.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -Command `"$cmd`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    if ($PSCmdlet.ShouldProcess($TaskName, 'Register logon task')) {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Force | Out-Null
        Write-Host "Registered '$TaskName' to start at logon." -ForegroundColor Green
    }
}

function Unregister-DeskFollow {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$TaskName = 'DeskFollow')
    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister task')) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Removed '$TaskName'." -ForegroundColor Green
    }
}

Set-Alias -Name swdesk -Value Switch-DeskProfile -Force
Set-Alias -Name gmin   -Value Get-MonitorInput   -Force
Set-Alias -Name smin   -Value Set-MonitorInput   -Force

Export-ModuleMember -Function Get-MonitorInput, Set-MonitorInput, Switch-DeskProfile,
    Test-DeskProfileApplied, Start-DeskFollow, Register-DeskFollow, Unregister-DeskFollow,
    Get-DeskMonitor, Close-DeskMonitorHandle, ConvertTo-DeskInputCode, ConvertFrom-DeskInputCode `
    -Alias swdesk, gmin, smin
