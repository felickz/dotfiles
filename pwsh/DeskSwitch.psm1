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

# Desk positions, and the label used when there is only one DDC-capable monitor. A machine
# wired to a single panel has no left/right to speak of - the personal laptop reaches only
# the left monitor and the Mac only the right one, yet each sees exactly one - so calling it
# 'Only' says what is true instead of guessing a position, and Resolve-DeskMonitor lets any
# requested role land on it.
$script:DeskRoles = @('Left', 'Center', 'Right')
$script:SoleRole = 'Only'

# .NET cannot unload or replace a type once it is in the AppDomain, so Add-Type is skipped
# when DeskSwitch.Native already exists. That means a shell which imported an OLDER version
# of this module keeps the old type even after Import-Module -Force, and any newly added
# method fails at call time with a confusing "does not contain a method named ..." error.
#
# Detect that case up front and say so plainly, rather than letting it surface later.
$script:RequiredNativeMethods = @(
    'GetVCPFeatureAndVCPFeatureReply'
    'SetVCPFeature'
    'EnumHMonitors'
    'IdleMilliseconds'
    'GetOrientation'
    'SetOrientation'
)

if ('DeskSwitch.Native' -as [type]) {
    $missing = @($script:RequiredNativeMethods | Where-Object {
        -not ([DeskSwitch.Native].GetMethod($_))
    })
    if ($missing) {
        Write-Warning ("This shell already has an older DeskSwitch.Native loaded, missing: {0}. " -f ($missing -join ', ') +
            'A .NET type cannot be replaced once loaded, so Import-Module -Force will not help. ' +
            'Open a new PowerShell window to pick up the current module.')
    }
}

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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public uint dmFields;
        public int dmPositionX, dmPositionY;
        public uint dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
        public uint dmPanningWidth, dmPanningHeight;
    }

    public class Native {
        public const uint DM_POSITION            = 0x00000020;
        public const uint DM_DISPLAYORIENTATION  = 0x00000080;
        public const uint DM_BITSPERPEL          = 0x00040000;
        public const uint DM_PELSWIDTH           = 0x00080000;
        public const uint DM_PELSHEIGHT          = 0x00100000;
        public const uint DM_DISPLAYFREQUENCY    = 0x00400000;
        public const uint CDS_UPDATEREGISTRY     = 0x00000001;
        public const int  ENUM_CURRENT_SETTINGS  = -1;

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr p);

        /// Current orientation of a display: 0 landscape, 1 portrait (90), 2 landscape
        /// flipped (180), 3 portrait flipped (270). -1 if it cannot be read.
        public static int GetOrientation(string device) {
            var dm = new DEVMODE();
            dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(device, ENUM_CURRENT_SETTINGS, ref dm)) return -1;
            return (int)dm.dmDisplayOrientation;
        }

        /// Rotates a display.
        ///
        /// Width and height must be swapped when crossing between landscape and portrait,
        /// or the call fails with DISP_CHANGE_BADMODE: the driver validates the mode against
        /// the requested orientation, so a 2560x1440 panel has to be asked for 1440x2560
        /// when turned on its side.
        public static int SetOrientation(string device, int orientation) {
            var dm = new DEVMODE();
            dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(device, ENUM_CURRENT_SETTINGS, ref dm)) return -100;

            bool wasPortrait = (dm.dmDisplayOrientation % 2) != 0;
            bool willBePortrait = (orientation % 2) != 0;
            if (wasPortrait != willBePortrait) {
                uint swap = dm.dmPelsWidth;
                dm.dmPelsWidth = dm.dmPelsHeight;
                dm.dmPelsHeight = swap;
            }

            dm.dmDeviceName = device;
            dm.dmDisplayOrientation = (uint)orientation;
            dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL |
                          DM_DISPLAYFREQUENCY | DM_DISPLAYORIENTATION;

            return ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY, IntPtr.Zero);
        }

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
    # A single monitor gets 'Only' rather than a made-up position: this machine can reach
    # just the one panel, wherever it physically sits.
    $sorted = @($result | Sort-Object X)
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $sorted[$i].Role = if ($sorted.Count -eq 1) { $script:SoleRole }
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

function Resolve-DeskMonitor {
    <#
    .SYNOPSIS
    Picks which monitors a command acts on, tolerating an omitted or mismatched role when
    only one DDC-capable monitor is attached.
    .DESCRIPTION
    Roles only mean something on a desk with more than one controllable monitor. The
    Surface Studio drives all three, but the personal laptop is USB-C to the left panel and
    the Mac is USB-C to the right one, so each of those reaches exactly one monitor and
    there is nothing to choose between. On those machines naming a position is busywork,
    and naming the "wrong" one should not be an error either - there is only one answer.

    So with a single monitor attached this returns it for any role, or for no role at all.
    With several, roles match exactly, an omitted role means every monitor, and a role with
    no monitor behind it warns as before.
    .PARAMETER Monitor
    Monitors from Get-DeskMonitor.
    .PARAMETER Role
    Requested roles. Empty means "whatever is attached".
    .PARAMETER ExactRole
    Suppress the single-monitor fallback. Used when applying a profile that owns more than
    one role, so a three-monitor profile cannot drive one panel three times.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][object[]]$Monitor = @(),
        [AllowEmptyCollection()][string[]]$Role = @(),
        [switch]$ExactRole
    )

    $mons = @($Monitor)
    $roles = @($Role | Where-Object { $_ })

    if ($mons.Count -eq 0) { return @() }

    if ($mons.Count -eq 1 -and -not $ExactRole) {
        if ($roles.Count -le 1) {
            if ($roles.Count -eq 1 -and $roles[0] -ne $mons[0].Role) {
                Write-Verbose "Only one DDC-capable monitor is attached; using it for '$($roles[0])'."
            }
            return @($mons[0])
        }
        # Several roles but one monitor: the caller means specific panels, so fall through
        # to exact matching rather than driving the same one repeatedly.
    }

    if ($roles.Count -eq 0) { return $mons }

    $picked = @()
    foreach ($r in $roles) {
        $m = @($mons | Where-Object { $_.Role -eq $r })
        if (-not $m) {
            Write-Warning "No DDC-capable monitor in the '$r' position (dark or detached?)."
            continue
        }
        $picked += $m
    }
    $picked
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

    The role is optional. A machine wired to one monitor has nothing to choose between, so
    "smin DP" is enough there - and on such a machine a role that does not match, such as
    "smin Left DP" from the laptop that only reaches the left panel, still lands on it.
    .PARAMETER Role
    Left, Center or Right - resolved by horizontal position. Positional, and optional:
    omit it to target every attached monitor, or the only one.
    .PARAMETER Source
    DP, HDMI, USBC, or a raw code such as 0x1B. Positional; may be given on its own.
    .PARAMETER ExactRole
    Require the role to match a real desk position, disabling the single-monitor fallback.
    .EXAMPLE
    smin DP
    .EXAMPLE
    smin Right HDMI
    .EXAMPLE
    Set-MonitorInput -Role Left,Center,Right -Source DP
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({ param($c, $p, $word) $script:DeskRoles | Where-Object { $_ -like "$word*" } })]
        [string[]]$Role,

        [Parameter(Position = 1)]
        [Alias('Input')]
        [ArgumentCompleter({ param($c, $p, $word) $script:InputCodes.Keys | Where-Object { $_ -like "$word*" } })]
        [string]$Source,

        [switch]$ExactRole,
        [switch]$Quiet
    )

    $roles = @($Role | Where-Object { $_ })

    # "smin DP": a lone positional argument is the input, not a position. Roles and input
    # names do not overlap, so the two cases stay distinguishable.
    if (-not $Source -and $roles.Count -eq 1) {
        if ($roles[0] -in $script:DeskRoles) {
            throw "Set-MonitorInput: -Source is required, e.g. 'smin $($roles[0]) DP'."
        }
        $Source = $roles[0]
        $roles = @()
    }
    if (-not $Source) { throw "Set-MonitorInput: -Source is required, e.g. 'smin DP' or 'smin Right HDMI'." }

    $unknown = @($roles | Where-Object { $_ -notin $script:DeskRoles -and $_ -ne $script:SoleRole })
    if ($unknown) {
        throw "Unknown role '$($unknown -join "', '")'. Valid roles: $($script:DeskRoles -join ', ')."
    }

    $code = ConvertTo-DeskInputCode $Source
    $name = ConvertFrom-DeskInputCode $code
    $mons = @(Get-DeskMonitor)
    $changed = 0

    try {
        if ($mons.Count -eq 0) { Write-Warning 'No DDC-capable monitor found.' }

        foreach ($m in Resolve-DeskMonitor -Monitor $mons -Role $roles -ExactRole:$ExactRole) {
            if ($m.InputCode -eq $code) {
                if (-not $Quiet) { Write-Host "  $($m.Role) ($($m.Description)) already on $name." -ForegroundColor DarkGray }
                continue
            }

            if (-not $PSCmdlet.ShouldProcess("$($m.Role) - $($m.Description)", "Switch input to $name")) { continue }

            if (-not [DeskSwitch.Native]::SetVCPFeature($m.Handle, $script:VcpInputSource, $code)) {
                Write-Warning "$($m.Role): SetVCPFeature failed (err $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
                continue
            }
            $changed++
            if (-not $Quiet) { Write-Host "  $($m.Role) ($($m.Description)) -> $name" -ForegroundColor Green }
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

    # A profile that owns several positions must match them exactly, or a machine currently
    # seeing one monitor would drive that single panel once per entry. A profile that owns
    # one position is unambiguous, so it may use the single-monitor fallback.
    $exact = $deskProfile.Monitors.Count -gt 1

    $total = 0
    foreach ($entry in $deskProfile.Monitors.GetEnumerator()) {
        $total += Set-MonitorInput -Role $entry.Key -Source $entry.Value -ExactRole:$exact -Quiet:$Quiet
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
    $mons = @(Get-DeskMonitor)
    $exact = $deskProfile.Monitors.Count -gt 1
    try {
        foreach ($entry in $deskProfile.Monitors.GetEnumerator()) {
            $matched = Resolve-DeskMonitor -Monitor $mons -Role $entry.Key -ExactRole:$exact -WarningAction SilentlyContinue
            if (-not $matched) { continue }
            $code = ConvertTo-DeskInputCode $entry.Value
            foreach ($m in $matched) {
                if ($m.InputCode -ne $code) { return $false }
            }
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

# ─── Brightness ────────────────────────────────────────────────────
# Brightness is VCP 0x10, the MCCS control right next to input source (0x60), so it rides
# the same DDC/CI channel and needs no Dell software. Verified on this desk: every monitor
# reports 0x10 as readable and writable over a 0-100 range.
#
# The laptop's own panel is NOT on DDC - it is driven by the graphics driver and exposed
# through WMI instead (root\wmi WmiMonitorBrightness / WmiMonitorBrightnessMethods). That
# split is why the follow watcher reads one API and writes another.

$script:VcpBrightness = 0x10
$script:VcpContrast   = 0x12

# Dell monitors raise a one-time on-screen "power consumption" confirmation the first time
# brightness is raised past their energy threshold (75% here). Measured: while that dialog
# is up the monitor stops answering DDC brightness entirely - the write is held, reads
# fail, and the value stays put until someone presses a button on the monitor itself.
#
# Once acknowledged it does not return, so brightness is not clamped by default. These
# knobs exist for a monitor that has not been acknowledged yet, or to keep an unattended
# follow inside a comfortable range:
#     $Global:DeskBrightnessMax = 75   # never exceed this when syncing/following
#     $Global:DeskBrightnessMin = 10   # never dim below this
#
# Get-Variable rather than a $null comparison: under Set-StrictMode -Version Latest,
# reading an undefined variable is a terminating error.
if (-not (Get-Variable -Name DeskBrightnessMax -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:DeskBrightnessMax = 100
}
if (-not (Get-Variable -Name DeskBrightnessMin -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:DeskBrightnessMin = 0
}

function Get-ClampedBrightness {
    <#
    .SYNOPSIS
    Clamps a brightness percentage into the configured comfortable range.
    .DESCRIPTION
    Used by the unattended paths only. An explicit Set-MonitorBrightness is treated as
    deliberate and is never clamped.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][int]$Percent)

    $min = [Math]::Max(0, [int]$Global:DeskBrightnessMin)
    $max = [Math]::Min(100, [int]$Global:DeskBrightnessMax)
    if ($min -gt $max) { $min = $max }

    [Math]::Max($min, [Math]::Min($max, $Percent))
}

function Get-LaptopBrightness {
    <#
    .SYNOPSIS
    Current brightness percentage of the built-in laptop panel.
    .DESCRIPTION
    Returns $null on a desktop, or any machine whose panel does not expose the WMI
    brightness class, so callers can fall back rather than fail.
    #>
    [CmdletBinding()]
    param()

    $b = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($b) { [int]$b.CurrentBrightness } else { $null }
}

function Set-LaptopBrightness {
    <#
    .SYNOPSIS
    Sets the built-in laptop panel brightness.
    .PARAMETER Percent
    0-100. Positional.
    .EXAMPLE
    Set-LaptopBrightness 40
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory, Position = 0)][ValidateRange(0, 100)][int]$Percent)

    $methods = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $methods) {
        Write-Warning 'No WMI brightness method available (not a laptop panel?).'
        return
    }
    if (-not $PSCmdlet.ShouldProcess('laptop panel', "Set brightness to $Percent%")) { return }

    Invoke-CimMethod -InputObject $methods -MethodName WmiSetBrightness `
        -Arguments @{ Timeout = 1; Brightness = [byte]$Percent } | Out-Null
}

function Get-MonitorBrightness {
    <#
    .SYNOPSIS
    Brightness (and contrast) of each DDC-capable monitor, plus the laptop panel.
    .EXAMPLE
    Get-MonitorBrightness
    #>
    [CmdletBinding()]
    param()

    $mons = Get-DeskMonitor
    try {
        foreach ($m in $mons) {
            $type = 0; $cur = 0; $max = 0
            $okB = [DeskSwitch.Native]::GetVCPFeatureAndVCPFeatureReply($m.Handle, $script:VcpBrightness, [ref]$type, [ref]$cur, [ref]$max)
            $bright = if ($okB) { [int]$cur } else { $null }
            $bmax = if ($okB) { [int]$max } else { $null }

            $type = 0; $cur = 0; $max = 0
            $okC = [DeskSwitch.Native]::GetVCPFeatureAndVCPFeatureReply($m.Handle, $script:VcpContrast, [ref]$type, [ref]$cur, [ref]$max)

            [PSCustomObject]@{
                Role       = $m.Role
                Monitor    = $m.Description
                Brightness = $bright
                Max        = $bmax
                Contrast   = if ($okC) { [int]$cur } else { $null }
            }
        }
    }
    finally { Close-DeskMonitorHandle }

    $laptop = Get-LaptopBrightness
    if ($null -ne $laptop) {
        [PSCustomObject]@{
            Role = 'Laptop'; Monitor = 'built-in panel'
            Brightness = $laptop; Max = 100; Contrast = $null
        }
    }
}

function Set-MonitorBrightness {
    <#
    .SYNOPSIS
    Sets brightness on one or more external monitors.
    .DESCRIPTION
    Skips any monitor already at the requested value. DDC writes are slow and make the
    monitor's OSD flash, so this keeps the follow watcher cheap and quiet - exactly the
    same idempotency trick Set-MonitorInput uses.

    A monitor showing a dead input, or one that has been detached, stops answering DDC. It
    is reported as skipped rather than treated as an error.
    .PARAMETER Percent
    0-100. Positional, so "smb 40" works. Scaled automatically if a monitor reports a
    maximum other than 100.
    .PARAMETER Role
    Which monitors. Defaults to every DDC-capable monitor. Also positional, so
    "smb 65 Center" works. On a machine that reaches only one monitor any role lands on it.
    .PARAMETER IncludeLaptop
    Also set the built-in panel.
    .EXAMPLE
    smb 40
    .EXAMPLE
    smb 65 Center
    .EXAMPLE
    Set-MonitorBrightness -Percent 40 -IncludeLaptop
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateRange(0, 100)][int]$Percent,
        [Parameter(Position = 1)]
        [ArgumentCompleter({ param($c, $p, $word) $script:DeskRoles | Where-Object { $_ -like "$word*" } })]
        [string[]]$Role,
        [switch]$IncludeLaptop,
        [switch]$Quiet
    )

    $roles = @($Role | Where-Object { $_ })
    $unknown = @($roles | Where-Object { $_ -notin $script:DeskRoles -and $_ -ne $script:SoleRole })
    if ($unknown) {
        throw "Unknown role '$($unknown -join "', '")'. Valid roles: $($script:DeskRoles -join ', ')."
    }

    $mons = @(Get-DeskMonitor)
    $changed = 0
    try {
        $targets = @(Resolve-DeskMonitor -Monitor $mons -Role $roles)

        foreach ($m in $targets) {
            $type = 0; $cur = 0; $max = 0
            if (-not [DeskSwitch.Native]::GetVCPFeatureAndVCPFeatureReply($m.Handle, $script:VcpBrightness, [ref]$type, [ref]$cur, [ref]$max)) {
                Write-Warning "$($m.Role): does not report brightness over DDC."
                continue
            }

            # Most monitors use 0-100, but the max is whatever the monitor declares.
            $scaled = if ($max -gt 0 -and $max -ne 100) { [int][Math]::Round($Percent * $max / 100.0) } else { $Percent }

            if ([int]$cur -eq $scaled) {
                if (-not $Quiet) { Write-Host "  $($m.Role) already at $Percent%." -ForegroundColor DarkGray }
                continue
            }

            if (-not $PSCmdlet.ShouldProcess("$($m.Role) - $($m.Description)", "Set brightness to $Percent%")) { continue }

            if ([DeskSwitch.Native]::SetVCPFeature($m.Handle, $script:VcpBrightness, $scaled)) {
                $changed++
                if (-not $Quiet) { Write-Host "  $($m.Role) ($($m.Description)) -> $Percent%" -ForegroundColor Green }
            }
            else {
                Write-Warning "$($m.Role): SetVCPFeature failed (err $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
            }
        }
    }
    finally { Close-DeskMonitorHandle }

    if ($IncludeLaptop) {
        $laptop = Get-LaptopBrightness
        if ($null -ne $laptop -and $laptop -ne $Percent) {
            Set-LaptopBrightness -Percent $Percent
            $changed++
            if (-not $Quiet) { Write-Host "  Laptop -> $Percent%" -ForegroundColor Green }
        }
    }

    $changed
}

function Sync-MonitorBrightness {
    <#
    .SYNOPSIS
    Matches every external monitor to the laptop panel's current brightness.
    .DESCRIPTION
    One-shot version of Start-BrightnessFollow: useful after docking, or bound to a hotkey.

    An external monitor at the same numeric percentage usually looks brighter than a laptop
    panel, so -Offset biases the external monitors without changing the laptop. The result
    is clamped to 0-100.
    .PARAMETER Offset
    Percentage points added to the laptop value before it is applied externally.
    Negative values dim the externals relative to the laptop. Positional, so
    "syncbr -10" works.
    .EXAMPLE
    Sync-MonitorBrightness
    .EXAMPLE
    syncbr -10
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)][ValidateRange(-100, 100)][int]$Offset = 0,
        [switch]$Quiet
    )

    $laptop = Get-LaptopBrightness
    if ($null -eq $laptop) {
        Write-Warning 'No laptop panel brightness available to sync from.'
        return 0
    }

    $target = Get-ClampedBrightness ($laptop + $Offset)
    if (-not $Quiet) { Write-Host "Laptop is at $laptop% -> setting externals to $target%" -ForegroundColor Cyan }

    Set-MonitorBrightness -Percent $target -Quiet:$Quiet
}

function Start-BrightnessFollow {
    <#
    .SYNOPSIS
    Makes the external monitors track the laptop's brightness keys in real time.
    .DESCRIPTION
    The laptop panel raises WmiMonitorBrightnessEvent whenever its brightness changes, and
    the event carries the new value - so the keyboard brightness keys, the Action Center
    slider and adaptive brightness all drive this equally, with no polling and no hotkey to
    register.

    Holding a brightness key fires a burst of events. They are coalesced: the watcher waits
    for a short quiet period and applies only the final value, so the monitors take one DDC
    write per gesture instead of one per keystroke.
    .PARAMETER Offset
    Percentage points to bias the external monitors by. See Sync-MonitorBrightness.
    .PARAMETER DebounceMs
    Quiet period before applying. Default 400ms.
    .EXAMPLE
    Start-BrightnessFollow -Offset -10 -Verbose
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(-100, 100)][int]$Offset = 0,
        [ValidateRange(0, 5000)][int]$DebounceMs = 400
    )

    if ($null -eq (Get-LaptopBrightness)) {
        throw 'This machine does not expose laptop panel brightness over WMI.'
    }

    $sourceId = 'DeskSwitchBrightness'
    Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
    Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue

    Register-CimIndicationEvent -Namespace root\wmi -Query 'SELECT * FROM WmiMonitorBrightnessEvent' `
        -SourceIdentifier $sourceId -ErrorAction Stop

    Write-Host "Following laptop brightness (offset $Offset). Ctrl+C to stop." -ForegroundColor Cyan
    Sync-MonitorBrightness -Offset $Offset -Quiet | Out-Null

    try {
        while ($true) {
            $ev = Wait-Event -SourceIdentifier $sourceId
            $latest = $ev.SourceEventArgs.NewEvent.Brightness
            Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue

            # Drain the burst produced by holding a brightness key and keep only the last value.
            while ($true) {
                $more = Wait-Event -SourceIdentifier $sourceId -Timeout ([Math]::Ceiling($DebounceMs / 1000.0))
                if (-not $more) { break }
                $latest = $more.SourceEventArgs.NewEvent.Brightness
                Remove-Event -EventIdentifier $more.EventIdentifier -ErrorAction SilentlyContinue
            }

            $target = Get-ClampedBrightness ([int]$latest + $Offset)
            Write-Verbose "Laptop -> $latest%, applying $target% to externals."
            try { Set-MonitorBrightness -Percent $target -Quiet | Out-Null }
            catch { Write-Warning "BrightnessFollow: $($_.Exception.Message)" }
        }
    }
    finally {
        Unregister-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier $sourceId -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }
}

function Register-BrightnessFollow {
    <#
    .SYNOPSIS
    Runs Start-BrightnessFollow at logon as a per-user scheduled task.
    .DESCRIPTION
    Unelevated: neither DDC/CI nor the WMI brightness class needs administrator rights.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$TaskName = 'BrightnessFollow',
        [int]$Offset = 0,
        [string]$ModulePath = $PSCommandPath
    )

    $cmd = "Import-Module '$ModulePath'; Start-BrightnessFollow -Offset $Offset"
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

function Unregister-BrightnessFollow {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$TaskName = 'BrightnessFollow')
    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister task')) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Removed '$TaskName'." -ForegroundColor Green
    }
}

function Get-MonitorOrientation {
    <#
    .SYNOPSIS
    Shows how each monitor is currently rotated.
    .EXAMPLE
    Get-MonitorOrientation
    #>
    [CmdletBinding()]
    param()

    $mons = Get-DeskMonitor
    try {
        foreach ($m in $mons) {
            $o = [DeskSwitch.Native]::GetOrientation($m.Device)
            [PSCustomObject]@{
                Role        = $m.Role
                Monitor     = $m.Description
                Device      = $m.Device
                Orientation = switch ($o) {
                    0 { 'Landscape' } 1 { 'Portrait' }
                    2 { 'LandscapeFlipped' } 3 { 'PortraitFlipped' }
                    default { 'unknown' }
                }
            }
        }
    }
    finally { Close-DeskMonitorHandle }
}

function Set-MonitorOrientation {
    <#
    .SYNOPSIS
    Rotates a monitor between landscape and portrait.
    .DESCRIPTION
    Rotation is a Windows display-config change, not a DDC one - the monitor panel itself
    has no idea. So this uses ChangeDisplaySettingsEx with DM_DISPLAYORIENTATION rather than
    a VCP code, and works even on a display that is not answering DDC.

    Width and height are swapped automatically when crossing between landscape and portrait.
    Without that the call fails with DISP_CHANGE_BADMODE, because the driver validates the
    requested mode against the requested orientation.

    Windows repacks the desktop around the new shape, so neighbouring monitors may shift.
    .PARAMETER Role
    Left, Center or Right. Positional, and optional when only one monitor is attached.
    .PARAMETER Orientation
    Landscape, Portrait, LandscapeFlipped or PortraitFlipped. Positional. Omit to toggle
    between Landscape and Portrait.
    .EXAMPLE
    rot Right Portrait
    .EXAMPLE
    rot Right            # toggle
    .EXAMPLE
    rot Portrait         # single-monitor machine
    .EXAMPLE
    Set-MonitorOrientation -Role Right -Orientation Landscape
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({ param($c, $p, $word) $script:DeskRoles | Where-Object { $_ -like "$word*" } })]
        [string]$Role,
        [Parameter(Position = 1)][ValidateSet('Landscape', 'Portrait', 'LandscapeFlipped', 'PortraitFlipped')][string]$Orientation,
        [switch]$Quiet
    )

    $codes = @{ Landscape = 0; Portrait = 1; LandscapeFlipped = 2; PortraitFlipped = 3 }

    # "rot Portrait": a lone positional argument naming an orientation is the orientation,
    # not a position. Orientation and role names do not overlap.
    if (-not $Orientation -and $Role -and $codes.ContainsKey($Role)) {
        $Orientation = $Role
        $Role = ''
    }
    if ($Role -and $Role -notin $script:DeskRoles -and $Role -ne $script:SoleRole) {
        throw "Unknown role '$Role'. Valid roles: $($script:DeskRoles -join ', ')."
    }

    $mons = @(Get-DeskMonitor)
    try {
        $matched = @(Resolve-DeskMonitor -Monitor $mons -Role $Role)
        if ($matched.Count -eq 0) {
            if ($mons.Count -eq 0) { Write-Warning 'No DDC-capable monitor found.' }
            return
        }
        if ($matched.Count -gt 1) {
            throw "Set-MonitorOrientation: more than one monitor is attached; name one of $(@($mons.Role) -join ', ')."
        }
        $m = $matched[0]
        $Role = $m.Role
        $device = $m.Device
        $label = $m.Description
    }
    finally { Close-DeskMonitorHandle }

    $current = [DeskSwitch.Native]::GetOrientation($device)
    if ($current -lt 0) {
        Write-Warning "Could not read the current orientation of $device."
        return
    }

    if (-not $Orientation) {
        # Toggle: portrait goes back to landscape, anything else goes portrait.
        $Orientation = if (($current % 2) -ne 0) { 'Landscape' } else { 'Portrait' }
    }
    $target = $codes[$Orientation]

    if ($current -eq $target) {
        if (-not $Quiet) { Write-Host "  $Role is already $Orientation." -ForegroundColor DarkGray }
        return 0
    }

    if (-not $PSCmdlet.ShouldProcess("$Role - $label [$device]", "Rotate to $Orientation")) { return }

    $rc = [DeskSwitch.Native]::SetOrientation($device, $target)
    if ($rc -ne 0) {
        Write-Warning "$Role : ChangeDisplaySettingsEx returned $rc (see DISP_CHANGE_* codes)."
        return 0
    }

    if (-not $Quiet) { Write-Host "  $Role ($label) -> $Orientation" -ForegroundColor Green }
    1
}

Set-Alias -Name swdesk -Value Switch-DeskProfile -Force
Set-Alias -Name gmin   -Value Get-MonitorInput   -Force
Set-Alias -Name smin   -Value Set-MonitorInput   -Force
Set-Alias -Name gmb    -Value Get-MonitorBrightness  -Force
Set-Alias -Name smb    -Value Set-MonitorBrightness  -Force
Set-Alias -Name syncbr -Value Sync-MonitorBrightness -Force
Set-Alias -Name rot    -Value Set-MonitorOrientation -Force
Set-Alias -Name grot   -Value Get-MonitorOrientation -Force

Export-ModuleMember -Function Get-MonitorInput, Set-MonitorInput, Switch-DeskProfile,
    Test-DeskProfileApplied, Start-DeskFollow, Register-DeskFollow, Unregister-DeskFollow,
    Get-DeskMonitor, Close-DeskMonitorHandle, Resolve-DeskMonitor, ConvertTo-DeskInputCode, ConvertFrom-DeskInputCode,
    Get-MonitorBrightness, Set-MonitorBrightness, Sync-MonitorBrightness,
    Get-LaptopBrightness, Set-LaptopBrightness,
    Start-BrightnessFollow, Register-BrightnessFollow, Unregister-BrightnessFollow,
    Get-MonitorOrientation, Set-MonitorOrientation `
    -Alias swdesk, gmin, smin, gmb, smb, syncbr, rot, grot
