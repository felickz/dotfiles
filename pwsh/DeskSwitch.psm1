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
    'GetMode'
    'Detach'
    'Attach'
    'ListAttached'
    'ListAllDisplays'
    'SetPrimary'
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

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    public class Native {
        public const uint DM_POSITION            = 0x00000020;
        public const uint DM_DISPLAYORIENTATION  = 0x00000080;
        public const uint DM_BITSPERPEL          = 0x00040000;
        public const uint DM_PELSWIDTH           = 0x00080000;
        public const uint DM_PELSHEIGHT          = 0x00100000;
        public const uint DM_DISPLAYFREQUENCY    = 0x00400000;
        public const uint CDS_UPDATEREGISTRY     = 0x00000001;
        public const uint CDS_SET_PRIMARY        = 0x00000010;
        public const uint CDS_NORESET            = 0x10000000;
        public const int  ENUM_CURRENT_SETTINGS  = -1;
        public const int  ENUM_REGISTRY_SETTINGS = -2;
        public const uint DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x00000001;
        public const uint DISPLAY_DEVICE_PRIMARY_DEVICE      = 0x00000004;

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr p);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern int ChangeDisplaySettingsEx(IntPtr dev, IntPtr dm, IntPtr hwnd, uint flags, IntPtr p);

        // IntPtr overload so the adapter enumeration can pass a real NULL; a null string
        // parameter does not reliably marshal as NULL from PowerShell.
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplayDevices(IntPtr dev, uint num, ref DISPLAY_DEVICE info, uint flags);

        /// Current mode of a display as "x,y,w,h,hz". Must be captured BEFORE detaching:
        /// the zeroed-DEVMODE detach also wipes the display's saved mode, so afterwards
        /// EnumDisplaySettings reports 0x0 and there is nothing left to restore from.
        public static string GetMode(string device) {
            var dm = new DEVMODE();
            dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(device, ENUM_CURRENT_SETTINGS, ref dm)) return null;

            // A detached display reports 0x0 as its CURRENT mode. Because the detach is no
            // longer written to the display database, the REGISTRY copy still holds the
            // geometry it had before - which is what makes an exact restore possible even
            // with no saved state of our own.
            if (dm.dmPelsWidth == 0) {
                var reg = new DEVMODE();
                reg.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
                if (EnumDisplaySettings(device, ENUM_REGISTRY_SETTINGS, ref reg) && reg.dmPelsWidth > 0) {
                    dm = reg;
                }
            }
            if (dm.dmPelsWidth == 0) return null;
            return dm.dmPositionX + "," + dm.dmPositionY + "," + dm.dmPelsWidth + "," +
                   dm.dmPelsHeight + "," + dm.dmDisplayFrequency;
        }

        /// Every attached display as "device|x|y|w|h|hz|primary". GDI only, so it keeps
        /// working for a monitor that has gone dark and stopped answering DDC.
        public static List<string> ListAttached() {
            var list = new List<string>();
            for (uint i = 0; i < 32; i++) {
                var dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(IntPtr.Zero, i, ref dd, 0)) break;
                if (string.IsNullOrEmpty(dd.DeviceName)) continue;
                if ((dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) == 0) continue;

                var dm = new DEVMODE();
                dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
                if (!EnumDisplaySettings(dd.DeviceName, ENUM_CURRENT_SETTINGS, ref dm)) continue;

                bool primary = (dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) != 0;
                list.Add(dd.DeviceName + "|" + dm.dmPositionX + "|" + dm.dmPositionY + "|" +
                         dm.dmPelsWidth + "|" + dm.dmPelsHeight + "|" + dm.dmDisplayFrequency + "|" +
                         (primary ? "1" : "0"));
            }
            return list;
        }

        /// Removes a display from the desktop by applying a DEVMODE whose width, height and
        /// position are all zero.
        ///
        /// Deliberately NOT persisted: CDS_UPDATEREGISTRY would write the detach into the
        /// display database, so it would survive a reboot or a re-enumeration. That turned a
        /// handover into a stranded monitor once - the saved record of how to restore it was
        /// keyed by a device name, a dock power-cycle renumbered the outputs, and Windows
        /// re-applied a detach no longer matching anything we could undo.
        ///
        /// Without it the detach is live-only, so anything that re-enumerates the displays -
        /// a reboot, a dock cycle, replugging - silently puts the monitor back. A handover is
        /// temporary by nature, so losing it on re-enumeration is the safer default.
        ///
        /// Flags are 0 rather than CDS_NORESET: NORESET is only legal alongside
        /// CDS_UPDATEREGISTRY and returns DISP_CHANGE_BADFLAGS (-4) on its own. Zero applies
        /// the change immediately without writing it to the display database.
        ///
        /// Windows silently refuses to do this to the PRIMARY display: the call reports
        /// success and nothing changes, so callers must check.
        public static int Detach(string device) {
            var dm = new DEVMODE();
            dm.dmDeviceName = device;
            dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
            dm.dmPelsWidth = 0;
            dm.dmPelsHeight = 0;
            dm.dmPositionX = 0;
            dm.dmPositionY = 0;
            int rc = ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero, 0, IntPtr.Zero);
            return rc;
        }

        /// Makes a display the primary one.
        ///
        /// Windows defines the primary display as the one at position (0,0), so this cannot
        /// be a single call: every OTHER attached display has to be shifted by the same
        /// delta, or the desktop keeps the old origin and the change is rejected or lands
        /// with the screens overlapping.
        ///
        /// All of it is staged with CDS_NORESET and committed by one final NULL call, so the
        /// desktop reflows once instead of once per display.
        ///
        /// This exists to unblock detaching. Windows silently refuses to detach the primary
        /// display, so when the machine's only external monitor is primary and another
        /// machine takes it, there is no way to drop it from the desktop without first
        /// handing "primary" to a panel this machine can still see.
        public static int SetPrimary(string device) {
            var target = new DEVMODE();
            target.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(device, ENUM_CURRENT_SETTINGS, ref target)) return -101;
            if (target.dmPelsWidth == 0) return -102;

            int dx = -target.dmPositionX;
            int dy = -target.dmPositionY;

            // Already at the origin and already flagged primary: nothing to do.
            if (dx == 0 && dy == 0 && IsPrimary(device)) return 0;

            // The new primary goes first; it is what defines the new origin.
            var dm = new DEVMODE();
            dm.dmDeviceName = device;
            dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            dm.dmPositionX = 0;
            dm.dmPositionY = 0;
            dm.dmFields = DM_POSITION;
            int rc = ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero,
                CDS_SET_PRIMARY | CDS_UPDATEREGISTRY | CDS_NORESET, IntPtr.Zero);
            if (rc != 0) return rc;

            foreach (string line in ListAttached()) {
                string[] f = line.Split('|');
                if (f[0] == device) continue;

                var other = new DEVMODE();
                other.dmDeviceName = f[0];
                other.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
                other.dmPositionX = int.Parse(f[1]) + dx;
                other.dmPositionY = int.Parse(f[2]) + dy;
                other.dmFields = DM_POSITION;
                rc = ChangeDisplaySettingsEx(f[0], ref other, IntPtr.Zero,
                    CDS_UPDATEREGISTRY | CDS_NORESET, IntPtr.Zero);
                if (rc != 0) return rc;
            }

            return ChangeDisplaySettingsEx(IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
        }

        public static bool IsPrimary(string device) {
            for (uint i = 0; i < 32; i++) {
                var dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(IntPtr.Zero, i, ref dd, 0)) break;
                if (dd.DeviceName == device) {
                    return (dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) != 0;
                }
            }
            return false;
        }

        /// Every display the driver knows about as "device|attached|monitorName", including
        /// ones detached from the desktop. Used to find a monitor that is physically present
        /// but not being driven - the state a lost or stale detach record leaves behind.
        public static List<string> ListAllDisplays() {
            var list = new List<string>();
            for (uint i = 0; i < 32; i++) {
                var dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(IntPtr.Zero, i, ref dd, 0)) break;
                if (string.IsNullOrEmpty(dd.DeviceName)) continue;

                bool attached = (dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;

                var mon = new DISPLAY_DEVICE();
                mon.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                string monName = EnumDisplayDevices(dd.DeviceName, 0, ref mon, 0) ? mon.DeviceString : "";

                list.Add(dd.DeviceName + "|" + (attached ? "1" : "0") + "|" + monName);
            }
            return list;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool EnumDisplayDevices(string dev, uint num, ref DISPLAY_DEVICE info, uint flags);

        /// Re-attaches a display with explicit geometry.
        ///
        /// SDC_TOPOLOGY_EXTEND cannot do this: detaching also rewrites the saved topology, so
        /// "extend" afterwards means "extend across whatever is still attached" and the
        /// detached display never returns.
        public static int Attach(string device, int x, int y, int w, int h, int hz) {
            var dm = new DEVMODE();
            dm.dmDeviceName = device;
            dm.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            dm.dmPelsWidth = (uint)w;
            dm.dmPelsHeight = (uint)h;
            dm.dmBitsPerPel = 32;
            dm.dmDisplayFrequency = (uint)hz;
            dm.dmPositionX = x;
            dm.dmPositionY = y;
            dm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL | DM_DISPLAYFREQUENCY;

            int rc = ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero, CDS_UPDATEREGISTRY | CDS_NORESET, IntPtr.Zero);
            if (rc != 0) return rc;
            return ChangeDisplaySettingsEx(IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
        }

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

    # Assign left/center/right by X order. Detached monitors are folded back in by their
    # saved X, so roles do not shift when one is handed to another machine: without this,
    # detaching the left panel would silently promote the centre one to "Left" and every
    # ownership comparison after that would be against the wrong profile entry.
    #
    # A single monitor with nothing detached gets 'Only' rather than a made-up position:
    # this machine can reach just the one panel, wherever it physically sits.
    $slots = @()
    foreach ($m in $result) { $slots += [pscustomobject]@{ X = [int]$m.X; Live = $m } }
    foreach ($d in (Get-DeskDetachedState).Values) {
        $slots += [pscustomobject]@{ X = [int]$d.X; Live = $null }
    }
    $ordered = @($slots | Sort-Object X)
    $total = $ordered.Count
    for ($i = 0; $i -lt $total; $i++) {
        $role = if ($total -eq 1) { $script:SoleRole }
            elseif ($i -eq 0) { 'Left' }
            elseif ($i -eq $total - 1) { 'Right' }
            else { 'Center' }
        if ($ordered[$i].Live) { $ordered[$i].Live.Role = $role }
    }

    $sorted = @($result | Sort-Object X)

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

    # Reclaiming: a detached monitor has no HMONITOR and cannot be found over DDC, so if the
    # requested input is the one this machine owns, put it back on the desktop first.
    foreach ($d in @((Get-DeskDetachedState).GetEnumerator())) {
        if ($roles.Count -and $d.Key -notin $roles) { continue }
        $want = (Get-DeskExpectedInput)[$d.Key]
        if ($want -and (ConvertTo-DeskInputCode $want) -eq $code) {
            if (-not $Quiet) { Write-Host "  $($d.Key) was detached; re-attaching before switching input." -ForegroundColor DarkGray }
            [void](Set-DeskMonitorAttached -Role $d.Key -Attached $true -Quiet:$Quiet)
            Start-Sleep -Seconds 2
        }
    }

    $mons = @(Get-DeskMonitor)

    # Switching one monitor's input disturbs the DDC bus, and a neighbour can drop out of
    # the enumeration for several seconds afterwards - during "swdesk" that surfaced as a
    # spurious "no monitor in the 'Center' position" between two roles that were both
    # plainly present. Retry before believing a monitor is really gone.
    if ($roles.Count) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $missing = @($roles | Where-Object { $r = $_; -not ($mons | Where-Object { $_.Role -eq $r }) })
            if (-not $missing -or $mons.Count -eq 0) { break }
            Write-Verbose "Role(s) $($missing -join ', ') not enumerated yet; retrying ($attempt/3)."
            Close-DeskMonitorHandle $script:LastHandleSets
            Start-Sleep -Milliseconds 1800
            $mons = @(Get-DeskMonitor)
        }
    }

    $changed = 0
    $handedOff = @()

    try {
        if ($mons.Count -eq 0) { Write-Warning 'No DDC-capable monitor found.' }

        $expected = Get-DeskExpectedInput -Monitor $mons

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

            # Handed to another machine: note the DEVICE, not just the role. Re-resolving the
            # role after the switch is unsafe, because this monitor drops out of the DDC
            # enumeration for a few seconds and the remaining panels shift roles.
            $want = if ($expected.ContainsKey($m.Role)) { $expected[$m.Role] } else { $null }
            if ($want -and $name -ne $want) {
                $handedOff += [pscustomobject]@{ Role = $m.Role; Device = $m.Device }
            }
        }
    }
    finally { Close-DeskMonitorHandle $script:LastHandleSets }

    # After the handles are released, so the detach cannot race the DDC session.
    if ($handedOff -and (Get-DeskConfig).AutoDetach) {
        foreach ($handed in $handedOff) {
            [void](Set-DeskMonitorAttached -Role $handed.Role -Device $handed.Device -Attached $false -Quiet:$Quiet)
        }
    }

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

    $profiles = Get-DeskProfileMap
    if (-not $profiles) { throw 'No desk profiles available ($DeskProfiles is unset and nothing is saved on disk).' }

    if (-not $Name) {
        $Name = ($profiles.GetEnumerator() |
            Where-Object { $_.Value.HostName -eq $env:COMPUTERNAME } |
            Select-Object -First 1).Key
        if (-not $Name) { throw "No profile matches host '$env:COMPUTERNAME'. Pass -Name explicitly." }
    }

    if (-not $profiles.Contains($Name)) {
        throw "Unknown profile '$Name'. Available: $($profiles.Keys -join ', ')"
    }

    $deskProfile = $profiles[$Name]
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

    $profiles = Get-DeskProfileMap
    if (-not $profiles -or -not $profiles.Contains($Name)) { return $false }
    $deskProfile = $profiles[$Name]
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
        $profiles = Get-DeskProfileMap
        if (-not $profiles) { throw 'No desk profiles available ($DeskProfiles is unset and nothing is saved on disk).' }
        $Name = ($profiles.GetEnumerator() |
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
        # The task runs -NoProfile, so $DeskProfiles will not exist in it. Snapshot the
        # map to disk now, or the watcher silently matches no profile and does nothing.
        Save-DeskProfileMap -ErrorAction SilentlyContinue
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
        # The task runs -NoProfile, so $DeskProfiles will not exist in it. Snapshot the
        # map to disk now, or the watcher silently matches no profile and does nothing.
        Save-DeskProfileMap -ErrorAction SilentlyContinue
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

# ─── Ownership and auto-detach ─────────────────────────────────────
# Switching a monitor's input is only half a handover. The cable this machine is on stays
# trained, so Windows keeps extending the desktop onto a panel that is now showing another
# machine: the cursor disappears into it and windows land there invisibly.
#
# Detection is possible because these Dells keep answering DDC over an INACTIVE cable. So
# this machine can read VCP 0x60 and see "USBC" on a monitor it reaches over DisplayPort,
# which means "someone else owns this right now".
#
# Config lives in a file rather than a shell variable because the guard usually runs as a
# scheduled task, in a different process from the shell where the toggle is flipped. The
# guard re-reads it every pass, so toggling takes effect live without a restart.

$script:DeskConfigFile   = Join-Path $env:LOCALAPPDATA 'deskswitch-config.json'
$script:DeskDetachedFile = Join-Path $env:LOCALAPPDATA 'deskswitch-detached.json'
$script:DeskProfileFile  = Join-Path $env:LOCALAPPDATA 'deskswitch-profiles.json'

function Get-DeskProfileMap {
    <#
    .SYNOPSIS
    The desk profile map, from the shell if present and from disk otherwise.
    .DESCRIPTION
    $DeskProfiles is defined in the PowerShell profile, but the guard and the follow
    watchers run as scheduled tasks started with -NoProfile, so that variable does not
    exist in their process. Without a fallback those tasks would silently never match a
    profile and quietly do nothing.

    Register-DeskGuard, Register-DeskFollow and Register-BrightnessFollow therefore snapshot
    the map to disk when they register, and this reads it back.
    #>
    [CmdletBinding()]
    param()

    if (Get-Variable -Name DeskProfiles -Scope Global -ErrorAction SilentlyContinue) {
        if ($Global:DeskProfiles) { return $Global:DeskProfiles }
    }

    if (-not (Test-Path $script:DeskProfileFile)) { return $null }
    try {
        $raw = Get-Content $script:DeskProfileFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $map = [ordered]@{}
        foreach ($p in $raw.PSObject.Properties) {
            $mons = [ordered]@{}
            foreach ($mp in $p.Value.Monitors.PSObject.Properties) { $mons[$mp.Name] = $mp.Value }
            $map[$p.Name] = @{ HostName = $p.Value.HostName; Monitors = $mons }
        }
        return $map
    }
    catch {
        Write-Verbose "Ignoring unreadable $($script:DeskProfileFile): $($_.Exception.Message)"
        return $null
    }
}

function Save-DeskProfileMap {
    <#
    .SYNOPSIS
    Snapshots $DeskProfiles to disk so -NoProfile scheduled tasks can read it.
    .DESCRIPTION
    Called automatically when a watcher is registered. Re-run it by hand after editing
    $DeskProfiles if a watcher is already registered.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not (Get-Variable -Name DeskProfiles -Scope Global -ErrorAction SilentlyContinue) -or -not $Global:DeskProfiles) {
        Write-Warning 'No $DeskProfiles defined in this shell; nothing to save.'
        return
    }
    if (-not $PSCmdlet.ShouldProcess($script:DeskProfileFile, 'Save desk profile map')) { return }

    $out = [ordered]@{}
    foreach ($e in $Global:DeskProfiles.GetEnumerator()) {
        $mons = [ordered]@{}
        foreach ($m in $e.Value.Monitors.GetEnumerator()) { $mons[$m.Key] = $m.Value }
        $out[$e.Key] = [ordered]@{ HostName = $e.Value.HostName; Monitors = $mons }
    }
    $out | ConvertTo-Json -Depth 6 | Set-Content $script:DeskProfileFile -Encoding utf8
    Write-Verbose "Saved desk profiles to $($script:DeskProfileFile)."
}

$script:DeskConfigDefaults = [ordered]@{
    # Detach monitors this machine does not own. The whole point of the guard, but easy to
    # turn off for a session where the reflow is more annoying than the hidden desktop.
    AutoDetach         = $true
    # Grace period before detaching. A quick hop to another machine and straight back costs
    # nothing if it fits inside this window, which avoids windows reflowing twice.
    DetachDelaySeconds = 20
    # How often the guard reads the monitors. DDC is slow and the bus dislikes hammering.
    PollSeconds        = 5
    # Consecutive unowned readings required before detaching. Time alone is not enough: a
    # single bad read during a transient would otherwise darken a healthy screen.
    ConfirmPolls       = 3
    # Quiet period after a resume. Displays come back unevenly from Modern Standby, and a
    # monitor mid-rescan can report an input that is not what it settles on.
    ResumeGraceSeconds = 90
}

function Get-DeskConfig {
    <#
    .SYNOPSIS
    Current DeskSwitch guard settings, merged over the defaults.
    #>
    [CmdletBinding()]
    param()

    $cfg = [ordered]@{}
    foreach ($k in $script:DeskConfigDefaults.Keys) { $cfg[$k] = $script:DeskConfigDefaults[$k] }

    if (Test-Path $script:DeskConfigFile) {
        try {
            $saved = Get-Content $script:DeskConfigFile -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
            }
        }
        catch { Write-Verbose "Ignoring unreadable $($script:DeskConfigFile): $($_.Exception.Message)" }
    }
    [pscustomobject]$cfg
}

function Set-DeskConfig {
    <#
    .SYNOPSIS
    Updates one or more guard settings and persists them.
    .EXAMPLE
    Set-DeskConfig -DetachDelaySeconds 45
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [nullable[bool]]$AutoDetach,
        [ValidateRange(0, 600)][nullable[int]]$DetachDelaySeconds,
        [ValidateRange(1, 300)][nullable[int]]$PollSeconds,
        [ValidateRange(1, 20)][nullable[int]]$ConfirmPolls,
        [ValidateRange(0, 900)][nullable[int]]$ResumeGraceSeconds
    )

    $cfg = Get-DeskConfig
    if ($null -ne $AutoDetach)         { $cfg.AutoDetach         = [bool]$AutoDetach }
    if ($null -ne $DetachDelaySeconds) { $cfg.DetachDelaySeconds = [int]$DetachDelaySeconds }
    if ($null -ne $PollSeconds)        { $cfg.PollSeconds        = [int]$PollSeconds }
    if ($null -ne $ConfirmPolls)       { $cfg.ConfirmPolls       = [int]$ConfirmPolls }
    if ($null -ne $ResumeGraceSeconds) { $cfg.ResumeGraceSeconds = [int]$ResumeGraceSeconds }

    if (-not $PSCmdlet.ShouldProcess($script:DeskConfigFile, 'Save DeskSwitch settings')) { return $cfg }

    $cfg | ConvertTo-Json -Depth 4 | Set-Content $script:DeskConfigFile -Encoding utf8
    $cfg
}

function Set-DeskAutoDetach {
    <#
    .SYNOPSIS
    Turns auto-detach on or off. Takes effect immediately, including in a running guard.
    .DESCRIPTION
    Off is the escape hatch for "I am hopping to the other machine for ten seconds and do
    not want the desktop reflowing twice".
    .EXAMPLE
    Set-DeskAutoDetach Off
    .EXAMPLE
    autodetach On
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory, Position = 0)][ValidateSet('On', 'Off')][string]$State)

    $enabled = $State -eq 'On'
    $cfg = Set-DeskConfig -AutoDetach $enabled
    Write-Host ("Auto-detach {0} (grace {1}s, poll {2}s)" -f `
        $(if ($cfg.AutoDetach) { 'ON' } else { 'OFF' }), $cfg.DetachDelaySeconds, $cfg.PollSeconds) `
        -ForegroundColor $(if ($cfg.AutoDetach) { 'Green' } else { 'Yellow' })
    $cfg
}

function Get-DeskExpectedInput {
    <#
    .SYNOPSIS
    Which input this machine expects to own, per desk role.
    .DESCRIPTION
    Read from the $DeskProfiles entry whose HostName matches this computer - the same map
    Switch-DeskProfile applies. That map already encodes "which cable am I on", so ownership
    needs no extra configuration.

    A machine wired to a single panel reports the role 'Only', while its profile names a
    position; when the profile owns exactly one monitor those are the same thing, so the
    single entry is used whatever it is called.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Monitor = @())

    $map = @{}
    $profiles = Get-DeskProfileMap
    if (-not $profiles) { return $map }

    $mine = $null
    foreach ($entry in $profiles.GetEnumerator()) {
        if ($entry.Value.HostName -eq $env:COMPUTERNAME) { $mine = $entry.Value; break }
    }
    if (-not $mine) { return $map }

    $owned = @($mine.Monitors.GetEnumerator())
    foreach ($e in $owned) { $map[$e.Key] = $e.Value }

    # Single-panel machine: its one monitor is whatever the profile's single entry names.
    $mons = @($Monitor)
    if ($owned.Count -eq 1 -and $mons.Count -eq 1 -and -not $map.ContainsKey($mons[0].Role)) {
        $map[$mons[0].Role] = $owned[0].Value
    }
    $map
}

function Get-DeskOwnership {
    <#
    .SYNOPSIS
    Shows, per monitor, whether this machine is the one currently driving it.
    .DESCRIPTION
    Owned is $true when the monitor's live input matches the input this machine is wired to,
    $false when another machine has taken it, and $null when there is no profile entry for
    that role - in which case nothing is ever detached, because no opinion exists.

    Detached monitors cannot answer DDC at all, so they are listed from the saved state file
    instead, with Attached = $false.
    .EXAMPLE
    gown
    #>
    [CmdletBinding()]
    param()

    $mons = @(Get-DeskMonitor)
    try {
        $expected = Get-DeskExpectedInput -Monitor $mons
        foreach ($m in $mons) {
            $want = if ($expected.ContainsKey($m.Role)) { $expected[$m.Role] } else { $null }
            [PSCustomObject]@{
                Role     = $m.Role
                Monitor  = $m.Description
                Device   = $m.Device
                Input    = $m.Input
                Expected = $want
                Owned    = if ($want) { $m.Input -eq $want } else { $null }
                Attached = $true
                Primary  = $m.Primary
            }
        }
    }
    finally { Close-DeskMonitorHandle $script:LastHandleSets }

    foreach ($d in (Get-DeskDetachedState).GetEnumerator()) {
        [PSCustomObject]@{
            Role     = $d.Key
            Monitor  = 'detached'
            Device   = $d.Value.Device
            Input    = $null
            Expected = $null
            Owned    = $false
            Attached = $false
            Primary  = $false
        }
    }
}

function Get-DeskDetachedState {
    <#
    .SYNOPSIS
    Role -> saved geometry for every display this module has detached.
    #>
    [CmdletBinding()]
    param()

    $state = @{}
    if (-not (Test-Path $script:DeskDetachedFile)) { return $state }
    try {
        $raw = Get-Content $script:DeskDetachedFile -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $state[$p.Name] = $p.Value }
    }
    catch { Write-Verbose "Ignoring unreadable $($script:DeskDetachedFile): $($_.Exception.Message)" }
    $state
}

function Save-DeskDetachedState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$State)

    if ($State.Count) { $State | ConvertTo-Json -Depth 5 | Set-Content $script:DeskDetachedFile -Encoding utf8 }
    else { Remove-Item $script:DeskDetachedFile -Force -ErrorAction SilentlyContinue }
}

function Get-DeskAttachedDevice {
    <#
    .SYNOPSIS
    Attached displays straight from GDI, which still works for a monitor gone dark.
    #>
    [CmdletBinding()]
    param()

    $rows = @()
    foreach ($line in [DeskSwitch.Native]::ListAttached()) {
        $f = "$line" -split '\|'
        if (@($f).Count -lt 7) { continue }
        $rows += [pscustomobject]@{
            Device  = $f[0]
            X       = [int]$f[1]
            Y       = [int]$f[2]
            Width   = [int]$f[3]
            Height  = [int]$f[4]
            Hz      = [int]$f[5]
            Primary = ($f[6] -eq '1')
        }
    }
    # Returned plainly, NOT as ", $rows". That idiom wraps the result in an outer array, so
    # "foreach ($a in Get-DeskAttachedDevice)" bound $a to the whole array and $a.X returned
    # every X at once - which produced an Object[] where an int was expected. Callers wrap
    # with @() when they need a guaranteed array.
    $rows
}

function Get-DeskInternalDevice {
    <#
    .SYNOPSIS
    Attached displays that answer no DDC - in practice the laptop's built-in panel.
    .DESCRIPTION
    Used to choose a safe primary. A panel with no DDC cannot be switched to another
    machine's input, so it is the one display this machine can always still see. Promoting
    it is what makes detaching a stolen external possible.
    #>
    [CmdletBinding()]
    param()

    $ddc = @{}
    $mons = @(Get-DeskMonitor)
    try {
        foreach ($m in $mons) { $ddc[$m.Device] = $true }
    }
    finally { Close-DeskMonitorHandle $script:LastHandleSets }

    @(Get-DeskAttachedDevice | Where-Object { -not $ddc.ContainsKey($_.Device) })
}

function Set-DeskPrimary {
    <#
    .SYNOPSIS
    Makes a display the primary one, shifting the rest of the desktop to match.
    .DESCRIPTION
    Windows defines the primary display as the one at (0,0), so every other display is moved
    by the same delta and the whole thing is committed in a single reflow.

    The reason this exists is narrow but important: Windows silently refuses to detach the
    PRIMARY display. When this machine's only external is primary and another machine takes
    its input, the screen cannot be dropped from the desktop - windows keep landing on a
    panel showing someone else's PC - until "primary" moves somewhere this machine can see.
    .PARAMETER Device
    GDI device name, e.g. "\\.\DISPLAY1".
    .EXAMPLE
    Set-DeskPrimary '\\.\DISPLAY1'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Device,
        [switch]$Quiet
    )

    if ([DeskSwitch.Native]::IsPrimary($Device)) {
        if (-not $Quiet) { Write-Host "  $Device is already primary." -ForegroundColor DarkGray }
        return 0
    }

    if (-not (Get-DeskAttachedDevice | Where-Object { $_.Device -eq $Device })) {
        Write-Warning "$Device is not attached to the desktop; cannot make it primary."
        return 0
    }

    if (-not $PSCmdlet.ShouldProcess($Device, 'Make primary display')) { return 0 }

    $rc = [DeskSwitch.Native]::SetPrimary($Device)
    if ($rc -ne 0) {
        Write-Warning "$Device : SetPrimary returned $rc (see DISP_CHANGE_* codes)."
        return 0
    }

    Start-Sleep -Milliseconds 700
    if (-not [DeskSwitch.Native]::IsPrimary($Device)) {
        Write-Warning "$Device did not become primary; nothing changed."
        return 0
    }

    if (-not $Quiet) { Write-Host "  $Device is now the primary display." -ForegroundColor Green }
    1
}

function Set-DeskMonitorAttached {
    <#
    .SYNOPSIS
    Adds or removes a monitor from the Windows desktop without unplugging it.
    .DESCRIPTION
    Three constraints shape this, all measured rather than assumed:

    1. Detaching WIPES the display's saved mode, and rewrites the saved topology so
       SDC_TOPOLOGY_EXTEND will not bring it back. Geometry is therefore captured to a state
       file BEFORE detaching and replayed explicitly on the way back.
    2. A detached monitor is not reachable over DDC - it leaves the HMONITOR enumeration -
       so the ordering is forced: release = switch input first, then detach; reclaim =
       attach first, then switch input.
    3. Windows silently refuses to detach the PRIMARY display: the call reports success and
       nothing changes. That case is refused up front instead of appearing to work.
    .PARAMETER Role
    Left, Center, Right or Only. Used to look the monitor up when -Device is not given.
    .PARAMETER Device
    GDI device name, e.g. "\\.\DISPLAY6". Preferred whenever the caller already knows it:
    role lookup re-enumerates over DDC, and a monitor that has just had its input switched
    drops out of that enumeration for a few seconds, which silently shifts every role along
    and can resolve "Left" to the wrong panel entirely.
    .PARAMETER Attached
    $false detaches; $true re-attaches using the geometry saved when it was detached.
    .EXAMPLE
    Set-DeskMonitorAttached -Role Left -Attached $false
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Role,
        [Parameter(Mandatory, Position = 1)][bool]$Attached,
        [string]$Device,
        [switch]$Quiet
    )

    $state = Get-DeskDetachedState

    if ($Attached) {
        if (-not $state.ContainsKey($Role)) {
            if (-not $Quiet) { Write-Host "  $Role is not recorded as detached." -ForegroundColor DarkGray }
            return 0
        }
        $saved = $state[$Role]
        if (-not $PSCmdlet.ShouldProcess("$Role - $($saved.Device)", 'Re-attach to desktop')) { return 0 }

        $rc = [DeskSwitch.Native]::Attach($saved.Device, $saved.X, $saved.Y, $saved.Width, $saved.Height, $saved.Hz)
        if ($rc -ne 0) {
            Write-Warning "$Role : ChangeDisplaySettingsEx returned $rc (see DISP_CHANGE_* codes)."
            return 0
        }

        $state.Remove($Role)
        Save-DeskDetachedState -State $state
        if (-not $Quiet) {
            Write-Host "  $Role re-attached at $($saved.Width)x$($saved.Height) @ $($saved.X),$($saved.Y)" -ForegroundColor Green
        }
        return 1
    }

    # --- detach ---
    # Prefer the caller's device. Re-resolving by role here is unsafe straight after an
    # input switch: the monitor stops answering DDC for a few seconds, the survivors are
    # re-ranked by position, and "Left" can resolve to the centre panel.
    $device = $Device
    $label = $Role
    if (-not $device) {
        $mons = @(Get-DeskMonitor)
        try {
            foreach ($m in $mons) {
                if ($m.Role -eq $Role) { $device = $m.Device; $label = $m.Description; break }
            }
        }
        finally { Close-DeskMonitorHandle $script:LastHandleSets }
    }

    if (-not $device) {
        Write-Warning "No DDC-capable monitor in the '$Role' position (already detached?)."
        return 0
    }

    # NOT $attached: PowerShell variable names are case-insensitive, so that would be the
    # [bool]$Attached parameter, and assigning an array to a [bool]-typed variable coerces
    # it to $true - making the count 1 and refusing every detach.
    $attachedDevices = Get-DeskAttachedDevice
    if (@($attachedDevices).Count -le 1) {
        Write-Warning 'Refusing to detach the only active display.'
        return 0
    }
    # Windows silently refuses to detach the PRIMARY display. Rather than giving up - which
    # left the monitor on the desktop with windows landing on a screen showing another
    # machine - hand "primary" to a display this machine can still see. The built-in panel
    # is preferred because it has no DDC and so can never be taken by another machine.
    $isPrimary = $false
    foreach ($a in $attachedDevices) {
        if ($a.Device -eq $device -and $a.Primary) { $isPrimary = $true; break }
    }

    if ($isPrimary) {
        $candidate = @(Get-DeskInternalDevice | Where-Object { $_.Device -ne $device })
        if (-not $candidate) {
            $candidate = @($attachedDevices | Where-Object { $_.Device -ne $device })
        }
        if (-not $candidate) {
            Write-Warning "$Role ($device) is the PRIMARY display and there is nothing else to promote."
            return 0
        }

        $newPrimary = $candidate[0].Device
        if (-not $Quiet) {
            Write-Host "  $Role is primary; moving primary to $newPrimary first." -ForegroundColor Cyan
        }
        if (-not (Set-DeskPrimary -Device $newPrimary -Quiet:$Quiet)) {
            Write-Warning "$Role ($device) is the PRIMARY display and primary could not be moved; not detaching."
            return 0
        }

        # Positions shift when the origin moves, so the saved geometry has to come from
        # after the promotion or the monitor would be restored to a stale place.
        $attachedDevices = Get-DeskAttachedDevice
    }

    # Only chance to read this: the detach wipes it.
    $mode = [DeskSwitch.Native]::GetMode($device)
    if (-not $mode) {
        Write-Warning "Could not read the current mode for $device; refusing to detach without a way back."
        return 0
    }
    $parts = $mode -split ','

    if (-not $PSCmdlet.ShouldProcess("$Role - $label [$device]", 'Detach from desktop')) { return 0 }

    $state[$Role] = [ordered]@{
        Device = $device
        X      = [int]$parts[0]
        Y      = [int]$parts[1]
        Width  = [int]$parts[2]
        Height = [int]$parts[3]
        Hz     = [int]$parts[4]
    }
    Save-DeskDetachedState -State $state

    $rc = [DeskSwitch.Native]::Detach($device)
    if ($rc -ne 0) { Write-Warning "ChangeDisplaySettingsEx returned $rc for $device." }

    Start-Sleep -Milliseconds 700
    $stillOn = @(Get-DeskAttachedDevice | Where-Object { $_.Device -eq $device })
    if (@($stillOn).Count -gt 0) {
        Write-Warning "$device is still attached; nothing changed."
        $state.Remove($Role)
        Save-DeskDetachedState -State $state
        return 0
    }

    if (-not $Quiet) {
        Write-Host "  $Role ($label) detached - saved $($parts[2])x$($parts[3]) @ $($parts[0]),$($parts[1])" -ForegroundColor Green
    }
    1
}

function Sync-DeskAttachment {
    <#
    .SYNOPSIS
    Makes the desktop match who actually owns each monitor.
    .DESCRIPTION
    Detaches every monitor another machine has taken. That is the common case: the desktop
    has drifted from the hardware and windows are landing on a panel you cannot see.

    Re-attaching is NOT the default. A detached monitor cannot answer DDC, so the only way
    to discover whether it came back is to attach it and look - and if it is still the other
    machine's, it has to be dropped again, which flaps the desktop. Use -Reclaim when you
    want that check, or just run "swdesk", which attaches and sets the inputs properly.
    .PARAMETER Reclaim
    Also re-attach previously detached monitors, keeping the ones that came back.
    .PARAMETER Force
    Detach even when auto-detach is switched off.
    .EXAMPLE
    syncmon
    .EXAMPLE
    syncmon -Reclaim
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Reclaim, [switch]$Force, [switch]$Quiet)

    $changed = 0

    if ($Reclaim) {
        foreach ($role in @((Get-DeskDetachedState).Keys)) {
            $changed += Set-DeskMonitorAttached -Role $role -Attached $true -Quiet:$Quiet
        }
        if ($changed) { Start-Sleep -Seconds 3 }
    }

    $cfg = Get-DeskConfig
    if (-not $cfg.AutoDetach -and -not $Force) {
        if (-not $Quiet) { Write-Host "  Auto-detach is off; not detaching. Use -Force or 'autodetach On'." -ForegroundColor DarkGray }
        return $changed
    }

    foreach ($o in (Get-DeskOwnership)) {
        if ($o.Attached -and $o.Owned -eq $false) {
            $changed += Set-DeskMonitorAttached -Role $o.Role -Device $o.Device -Attached $false -Quiet:$Quiet
        }
    }

    if (-not $Quiet -and $changed -eq 0) { Write-Host '  Desktop already matches monitor ownership.' -ForegroundColor DarkGray }
    $changed
}

function Repair-DeskDetachedState {
    <#
    .SYNOPSIS
    Drops saved detach entries for displays that are attached again.
    .DESCRIPTION
    Windows re-attaches displays on its own across sleep, docking and driver restarts, which
    leaves the saved state claiming something is detached when it is not. That produced a
    phantom "detached" row in gown and made swdesk try to re-attach a display that was
    already back.
    #>
    [CmdletBinding()]
    param()

    $state = Get-DeskDetachedState
    if (-not $state.Count) { return 0 }

    $live = @{}
    foreach ($d in (Get-DeskAttachedDevice)) { $live[$d.Device] = $true }

    $dropped = 0
    foreach ($role in @($state.Keys)) {
        if ($live.ContainsKey($state[$role].Device)) {
            Write-Verbose "$role ($($state[$role].Device)) is attached again; clearing stale detach state."
            $state.Remove($role)
            $dropped++
        }
    }
    if ($dropped) { Save-DeskDetachedState -State $state }
    $dropped
}

$script:DeskBaselineFile = Join-Path $env:LOCALAPPDATA 'deskswitch-baseline.json'

function Get-DeskBaseline {
    <#
    .SYNOPSIS
    The last known-good snapshot of this desk.
    .DESCRIPTION
    Records which monitors are normally here, by EDID name and geometry, so a later fault
    can be described as "one of your monitors is missing" rather than just "three screens".
    #>
    [CmdletBinding()]
    param()

    if (-not (Test-Path $script:DeskBaselineFile)) { return $null }
    try {
        Get-Content $script:DeskBaselineFile -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    catch {
        Write-Verbose "Ignoring unreadable $($script:DeskBaselineFile): $($_.Exception.Message)"
        $null
    }
}

function Update-DeskBaseline {
    <#
    .SYNOPSIS
    Snapshots the desk, but only while it looks healthy.
    .DESCRIPTION
    Only records a state where every display the driver reports a monitor for is actually
    attached. Snapshotting a broken desk would bake the fault in as normal and the warning
    would never fire again - which is the one way this feature could make things worse.
    .PARAMETER Force
    Snapshot even if the desk looks incomplete.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([switch]$Force)

    $rows = @()
    $unhealthy = 0
    foreach ($line in [DeskSwitch.Native]::ListAllDisplays()) {
        $f = "$line" -split '\|'
        if (@($f).Count -lt 3 -or -not $f[2]) { continue }   # no monitor behind it
        if ($f[1] -ne '1') { $unhealthy++; continue }        # monitor present but detached
        $mode = [DeskSwitch.Native]::GetMode($f[0])
        $p = if ($mode) { "$mode" -split ',' } else { $null }
        $rows += [pscustomobject]@{
            Monitor = $f[2]
            X       = if ($p) { [int]$p[0] } else { 0 }
            Y       = if ($p) { [int]$p[1] } else { 0 }
            Width   = if ($p) { [int]$p[2] } else { 0 }
            Height  = if ($p) { [int]$p[3] } else { 0 }
            Hz      = if ($p) { [int]$p[4] } else { 60 }
        }
    }

    if (-not $rows) { return 0 }
    if ($unhealthy -and -not $Force) {
        Write-Verbose "Desk has $unhealthy detached monitor(s); not snapshotting a broken state."
        return 0
    }

    # Never shrink the baseline silently: fewer monitors than last time usually means one is
    # missing, not that the desk changed. -Force is how a genuine desk change is recorded.
    $existing = Get-DeskBaseline
    if ($existing -and @($existing.Monitors).Count -gt $rows.Count -and -not $Force) {
        Write-Verbose "Only $($rows.Count) monitors vs $(@($existing.Monitors).Count) in the baseline; not overwriting."
        return 0
    }

    if (-not $PSCmdlet.ShouldProcess($script:DeskBaselineFile, 'Save desk baseline')) { return 0 }

    [pscustomobject]@{ Saved = (Get-Date).ToString('o'); Monitors = $rows } |
        ConvertTo-Json -Depth 5 | Set-Content $script:DeskBaselineFile -Encoding utf8
    $rows.Count
}

function Get-DeskMissingMonitor {
    <#
    .SYNOPSIS
    Monitors in the baseline that are not physically reachable now.
    .DESCRIPTION
    The distinction that decides whether software can help at all:

      detached but present - Windows still reads its EDID, so it can be attached back
      absent entirely      - no EDID on any input, so there is nothing to command

    Only the second kind needs the cable or the dock power-cycled. Comparison is by EDID
    name and count, because device names renumber across a dock cycle while the names do not.
    #>
    [CmdletBinding()]
    param()

    $baseline = Get-DeskBaseline
    if (-not $baseline) { return @() }

    $have = @{}
    foreach ($line in [DeskSwitch.Native]::ListAllDisplays()) {
        $f = "$line" -split '\|'
        if (@($f).Count -lt 3 -or -not $f[2]) { continue }
        if ($have.ContainsKey($f[2])) { $have[$f[2]]++ } else { $have[$f[2]] = 1 }
    }

    $want = @{}
    foreach ($m in @($baseline.Monitors)) {
        if ($want.ContainsKey($m.Monitor)) { $want[$m.Monitor]++ } else { $want[$m.Monitor] = 1 }
    }

    $missing = @()
    foreach ($name in $want.Keys) {
        $hadCount = $want[$name]
        $nowCount = if ($have.ContainsKey($name)) { $have[$name] } else { 0 }
        for ($i = 0; $i -lt ($hadCount - $nowCount); $i++) { $missing += $name }
    }
    $missing
}

function Restore-DeskDisplays {
    <#
    .SYNOPSIS
    Puts back any monitor that is connected but missing from the desktop.
    .DESCRIPTION
    The recovery hatch for a display that is physically present - Windows can read its EDID -
    yet is not being driven, so it sits showing "no signal" while the desktop ignores it.

    Unlike the re-attach in swdesk and syncmon, this needs no saved state. It scans every
    display the driver knows about, finds ones that are detached but have a monitor behind
    them, and attaches them. That matters because the saved record is keyed by device name,
    and a dock power-cycle or driver restart renumbers those - which once left a monitor
    stranded with nothing able to restore it.

    Position comes from whatever Windows still has on record for that display; if it has
    none, the monitor is placed beside the existing desktop rather than stacked at 0,0.
    .PARAMETER Width
    Fallback width when Windows has no remembered mode. Default 2560.
    .PARAMETER Height
    Fallback height. Default 1440.
    .PARAMETER Hz
    Fallback refresh rate. Default 60.
    .EXAMPLE
    fixmon
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [int]$Width = 2560,
        [int]$Height = 1440,
        [int]$Hz = 60,
        [switch]$Quiet
    )

    $candidates = @()
    foreach ($line in [DeskSwitch.Native]::ListAllDisplays()) {
        $f = "$line" -split '\|'
        if (@($f).Count -lt 3) { continue }
        # Detached, but a monitor is present behind it: that is a screen showing "no signal".
        if ($f[1] -eq '0' -and $f[2]) {
            $candidates += [pscustomobject]@{ Device = $f[0]; Monitor = $f[2] }
        }
    }

    if (-not $candidates) {
        $missingNow = @(Get-DeskMissingMonitor)
        if ($missingNow) {
            Write-Warning ("Not reachable at all: {0}." -f ($missingNow -join ', '))
            Write-Host '  Nothing is detached, so there is nothing to attach - this monitor has no EDID link.' -ForegroundColor Yellow
            Write-Host '  Try Reset-Dock -Depth Controller, then a real dock power-cycle at the wall.' -ForegroundColor Cyan
            return 0
        }
        if (-not $Quiet) { Write-Host '  Every connected monitor is already on the desktop.' -ForegroundColor DarkGray }
        [void](Update-DeskBaseline)
        return 0
    }

    # Anything with no remembered position goes to the RIGHT of the current desktop. Placing
    # it left would push into negative space that the other monitors already occupy, and an
    # int is forced here because a stray array would silently break the arithmetic.
    $rightEdge = 0
    foreach ($a in @(Get-DeskAttachedDevice)) {
        $edge = [int]$a.X + [int]$a.Width
        if ($edge -gt $rightEdge) { $rightEdge = $edge }
    }

    $restored = 0
    foreach ($c in $candidates) {
        $mode = [DeskSwitch.Native]::GetMode($c.Device)
        $x = $rightEdge; $y = 0; $w = $Width; $h = $Height; $r = $Hz
        if ($mode) {
            $p = "$mode" -split ','
            if (@($p).Count -ge 5 -and [int]$p[2] -gt 0) {
                $x = [int]$p[0]; $y = [int]$p[1]; $w = [int]$p[2]; $h = [int]$p[3]; $r = [int]$p[4]
            }
        }

        if (-not $PSCmdlet.ShouldProcess("$($c.Monitor) [$($c.Device)]", "Attach at ${w}x${h} @ $x,$y")) { continue }

        $rc = [DeskSwitch.Native]::Attach($c.Device, $x, $y, $w, $h, $r)
        Start-Sleep -Seconds 2
        if ($rc -eq 0) {
            $restored++
            if (($x + $w) -gt $rightEdge) { $rightEdge = $x + $w }
            if (-not $Quiet) { Write-Host "  restored $($c.Monitor) [$($c.Device)] at ${w}x${h} @ $x,$y" -ForegroundColor Green }
        }
        else {
            Write-Verbose "$($c.Device): ChangeDisplaySettingsEx returned $rc (likely an output with no real monitor)."
        }
    }

    # Anything we restored is by definition no longer handed away.
    [void](Repair-DeskDetachedState)

    # A monitor in the baseline that is not reachable at all is a different fault: there is
    # no EDID, so nothing here can command it. Say so, and say what actually works.
    $missing = @(Get-DeskMissingMonitor)
    if ($missing) {
        Write-Host ''
        Write-Warning ("Not reachable at all: {0}." -f ($missing -join ', '))
        Write-Host '  Windows cannot see this monitor on any input, so there is no link to command -' -ForegroundColor Yellow
        Write-Host '  attaching, re-detecting and switching inputs all have nothing to act on.' -ForegroundColor Yellow
        Write-Host '  Try, in order:' -ForegroundColor Yellow
        Write-Host '    1. Reset-Dock -Depth Controller   (software dock cycle)' -ForegroundColor Cyan
        Write-Host '    2. POWER-CYCLE THE DOCK at the wall - this is what worked before when' -ForegroundColor Cyan
        Write-Host '       the software cycle did not; USB-C alt mode only renegotiates on a real power loss' -ForegroundColor Cyan
        Write-Host '    3. Unplug/replug that monitor''s own cable' -ForegroundColor Cyan
        Write-Host '  Then run fixmon again.' -ForegroundColor Yellow
    }
    elseif ($restored -gt 0) {
        # Desk is whole again, so this is a good moment to refresh what "normal" means.
        [void](Update-DeskBaseline)
    }

    if (-not $Quiet -and $restored -eq 0 -and -not $missing) { Write-Host '  Nothing could be restored.' -ForegroundColor DarkGray }
    $restored
}

function Start-DeskGuard {
    <#
    .SYNOPSIS
    Watches for another machine taking a monitor, and drops it from this desktop.
    .DESCRIPTION
    Windows raises no event for this. An input switch happens entirely inside the monitor,
    so the display config never changes and there is nothing to subscribe to - the only way
    to notice is to read VCP 0x60 periodically. The poll is cheap because it stops at the
    first read: nothing is written unless ownership actually changed.

    A monitor must look unowned for DetachDelaySeconds AND across several consecutive polls
    before it is dropped. Elapsed time alone is not enough: a single bad reading during a
    transient - waking, re-docking, the monitor rescanning its inputs - would otherwise be
    enough to detach a healthy screen, which is how a glitch turns into a dark primary
    monitor that only the monitor's own OSD can recover.

    Nothing is detached for ResumeGraceSeconds after a sleep. Sleep is detected by noticing
    that far more time passed between two polls than the poll interval, which needs no event
    subscription and cannot be missed.

    Re-attaching is deliberately NOT automatic: a detached monitor leaves the HMONITOR
    enumeration, so this loop cannot see it come back. Take monitors back with
    "smin <role> <input>", "swdesk", or "syncmon -Reclaim", all of which attach first.

    Settings are re-read every pass, so "autodetach Off" takes effect without restarting.
    .EXAMPLE
    Start-DeskGuard -Verbose
    #>
    [CmdletBinding()]
    param()

    Write-Host "DeskGuard watching. Ctrl+C to stop." -ForegroundColor Cyan
    $unownedSince = @{}
    $unownedCount = @{}
    $lastPass = Get-Date
    $resumeUntil = [datetime]::MinValue

    while ($true) {
        try {
            $cfg = Get-DeskConfig

            # A gap far longer than the poll interval means the machine was asleep. Displays
            # come back unevenly afterwards, so hold off rather than act on the first read.
            $now = Get-Date
            $gap = ($now - $lastPass).TotalSeconds
            if ($gap -gt ([Math]::Max(30, $cfg.PollSeconds * 6))) {
                $resumeUntil = $now.AddSeconds($cfg.ResumeGraceSeconds)
                Write-Verbose ("Gap of {0:N0}s suggests a resume; holding off until {1:HH:mm:ss}." -f $gap, $resumeUntil)
                $unownedSince.Clear()
                $unownedCount.Clear()
            }
            $lastPass = $now

            [void](Repair-DeskDetachedState)

            # Keep the record of "normal" current while the desk is healthy, so a later fault
            # can be named rather than just counted. Update-DeskBaseline refuses to snapshot
            # a desk that has a detached monitor, so a fault cannot become the new normal.
            [void](Update-DeskBaseline)

            if (-not $cfg.AutoDetach -or $now -lt $resumeUntil) {
                $unownedSince.Clear()
                $unownedCount.Clear()
                Start-Sleep -Seconds $cfg.PollSeconds
                continue
            }

            $seen = @{}
            foreach ($o in (Get-DeskOwnership)) {
                if (-not $o.Attached) { continue }
                $seen[$o.Role] = $true

                if ($o.Owned -eq $false) {
                    if (-not $unownedSince.ContainsKey($o.Role)) {
                        $unownedSince[$o.Role] = $now
                        $unownedCount[$o.Role] = 0
                        Write-Verbose "$($o.Role) shows $($o.Input), expected $($o.Expected)."
                    }
                    $unownedCount[$o.Role] = $unownedCount[$o.Role] + 1
                    $waited = ($now - $unownedSince[$o.Role]).TotalSeconds

                    # Both gates: long enough AND consistently, so one bad read cannot do it.
                    if ($waited -ge $cfg.DetachDelaySeconds -and $unownedCount[$o.Role] -ge $cfg.ConfirmPolls) {
                        Write-Host "$($o.Role) taken by another machine (input $($o.Input)) - detaching." -ForegroundColor Yellow
                        [void](Set-DeskMonitorAttached -Role $o.Role -Device $o.Device -Attached $false -Quiet)
                        $unownedSince.Remove($o.Role)
                        $unownedCount.Remove($o.Role)
                    }
                }
                elseif ($unownedSince.ContainsKey($o.Role)) {
                    # Came back, or the earlier reading was a blip: reset, no reflow.
                    Write-Verbose "$($o.Role) is ours again; cancelling its pending detach."
                    $unownedSince.Remove($o.Role)
                    $unownedCount.Remove($o.Role)
                }
            }

            # A monitor that stopped answering DDC entirely is NOT evidence of a handover -
            # it is what a dropped link looks like - so forget it rather than counting on.
            foreach ($role in @($unownedSince.Keys)) {
                if (-not $seen.ContainsKey($role)) {
                    Write-Verbose "$role is no longer enumerated; cancelling its pending detach."
                    $unownedSince.Remove($role)
                    $unownedCount.Remove($role)
                }
            }
        }
        catch {
            Write-Warning "DeskGuard: $($_.Exception.Message)"
        }

        Start-Sleep -Seconds (Get-DeskConfig).PollSeconds
    }
}

function Register-DeskGuard {
    <#
    .SYNOPSIS
    Runs Start-DeskGuard at logon as a per-user scheduled task.
    .DESCRIPTION
    Unelevated: neither DDC/CI nor ChangeDisplaySettingsEx needs administrator rights.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$TaskName = 'DeskGuard', [string]$ModulePath = $PSCommandPath)

    $cmd = "Import-Module '$ModulePath'; Start-DeskGuard"
    $action = New-ScheduledTaskAction -Execute 'pwsh.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -Command `"$cmd`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    if ($PSCmdlet.ShouldProcess($TaskName, 'Register logon task')) {
        # The task runs -NoProfile, so $DeskProfiles will not exist in it. Snapshot the
        # map to disk now, or the watcher silently matches no profile and does nothing.
        Save-DeskProfileMap -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Force | Out-Null
        Write-Host "Registered '$TaskName' to start at logon." -ForegroundColor Green
    }
}

function Unregister-DeskGuard {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$TaskName = 'DeskGuard')
    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister task')) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Removed '$TaskName'." -ForegroundColor Green
    }
}

Set-Alias -Name swdesk -Value Switch-DeskProfile -Force
Set-Alias -Name gmin   -Value Get-MonitorInput   -Force
Set-Alias -Name smin   -Value Set-MonitorInput   -Force
Set-Alias -Name gmb    -Value Get-MonitorBrightness  -Force
Set-Alias -Name smb    -Value Set-MonitorBrightness  -Force
Set-Alias -Name syncbr -Value Sync-MonitorBrightness -Force
Set-Alias -Name rot    -Value Set-MonitorOrientation -Force
Set-Alias -Name grot   -Value Get-MonitorOrientation -Force
Set-Alias -Name gown       -Value Get-DeskOwnership   -Force
Set-Alias -Name syncmon    -Value Sync-DeskAttachment -Force
Set-Alias -Name autodetach -Value Set-DeskAutoDetach  -Force
Set-Alias -Name fixmon     -Value Restore-DeskDisplays -Force
Set-Alias -Name setprim    -Value Set-DeskPrimary      -Force

Export-ModuleMember -Function Get-MonitorInput, Set-MonitorInput, Switch-DeskProfile,
    Test-DeskProfileApplied, Start-DeskFollow, Register-DeskFollow, Unregister-DeskFollow,
    Get-DeskMonitor, Close-DeskMonitorHandle, Resolve-DeskMonitor, ConvertTo-DeskInputCode, ConvertFrom-DeskInputCode,
    Get-MonitorBrightness, Set-MonitorBrightness, Sync-MonitorBrightness,
    Get-LaptopBrightness, Set-LaptopBrightness,
    Start-BrightnessFollow, Register-BrightnessFollow, Unregister-BrightnessFollow,
    Get-MonitorOrientation, Set-MonitorOrientation,
    Get-DeskConfig, Set-DeskConfig, Set-DeskAutoDetach,
    Get-DeskProfileMap, Save-DeskProfileMap,
    Get-DeskOwnership, Get-DeskExpectedInput, Get-DeskDetachedState, Get-DeskAttachedDevice,
    Repair-DeskDetachedState, Restore-DeskDisplays,
    Get-DeskBaseline, Update-DeskBaseline, Get-DeskMissingMonitor,
    Set-DeskMonitorAttached, Sync-DeskAttachment,
    Set-DeskPrimary, Get-DeskInternalDevice,
    Start-DeskGuard, Register-DeskGuard, Unregister-DeskGuard `
    -Alias swdesk, gmin, smin, gmb, smb, syncbr, rot, grot, gown, syncmon, autodetach, fixmon, setprim
