<#
Read the USB BOS / Billboard capability descriptor from a USB-C device bound to winusb.sys.

The Billboard capability is how a USB-C device reports the outcome of Alternate Mode
entry. bmConfigured carries two bits per alternate mode:

    00  unspecified error
    01  configuration not attempted
    10  configuration attempted but UNSUCCESSFUL
    11  configuration successful

So this answers, from the dock's own descriptor, whether DP alt-mode entry was tried and
failed rather than never attempted.
#>
[CmdletBinding()]
param([string[]]$DevicePath)

$ErrorActionPreference = 'Stop'

Add-Type -Namespace BB -Name Native -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
    IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(IntPtr hObject);

[DllImport("winusb.dll", SetLastError = true)]
public static extern bool WinUsb_Initialize(IntPtr DeviceHandle, out IntPtr InterfaceHandle);

[DllImport("winusb.dll", SetLastError = true)]
public static extern bool WinUsb_Free(IntPtr InterfaceHandle);

[DllImport("winusb.dll", SetLastError = true)]
public static extern bool WinUsb_GetDescriptor(IntPtr InterfaceHandle, byte DescriptorType, byte Index,
    ushort LanguageID, byte[] Buffer, uint BufferLength, out uint LengthTransferred);
'@

function Read-Descriptor {
    param([string]$Path)

    # 0xC0000000 parses as a negative Int32 in PowerShell, so force it wide before casting.
    $GENERIC_RW = [uint32]0xC0000000L
    $SHARE_RW = [uint32]3
    $OPEN_EXISTING = [uint32]3
    $OVERLAPPED = [uint32]0x40000000L

    $h = [BB.Native]::CreateFileW($Path, $GENERIC_RW, $SHARE_RW, [IntPtr]::Zero, $OPEN_EXISTING, $OVERLAPPED, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::new(-1)) {
        return [pscustomobject]@{ Path = $Path; Error = "CreateFile failed: $([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message)" }
    }

    $ih = [IntPtr]::Zero
    try {
        if (-not [BB.Native]::WinUsb_Initialize($h, [ref]$ih)) {
            return [pscustomobject]@{ Path = $Path; Error = "WinUsb_Initialize failed: $([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message)" }
        }

        # 0x0F = BOS descriptor.
        $buf = [byte[]]::new(1024)
        $got = 0
        if (-not [BB.Native]::WinUsb_GetDescriptor($ih, 0x0F, 0, 0, $buf, $buf.Length, [ref]$got)) {
            return [pscustomobject]@{ Path = $Path; Error = "GetDescriptor(BOS) failed: $([ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error()).Message)" }
        }

        [pscustomobject]@{ Path = $Path; Bytes = $buf[0..($got - 1)]; Length = $got; Error = $null }
    }
    finally {
        if ($ih -ne [IntPtr]::Zero) { [void][BB.Native]::WinUsb_Free($ih) }
        [void][BB.Native]::CloseHandle($h)
    }
}

function Show-Bos {
    param([byte[]]$b)

    if ($b.Length -lt 5 -or $b[1] -ne 0x0F) { "    not a BOS descriptor"; return }
    $total = [BitConverter]::ToUInt16($b, 2)
    $caps = $b[4]
    "    BOS: wTotalLength=$total bNumDeviceCaps=$caps"

    $o = 5
    while ($o -lt [Math]::Min($total, $b.Length) -and $b[$o] -gt 0) {
        $len = $b[$o]
        $capType = if ($o + 2 -lt $b.Length) { $b[$o + 2] } else { 0 }
        $name = switch ($capType) {
            0x02 { 'USB 2.0 Extension' }
            0x03 { 'SuperSpeed' }
            0x0A { 'SuperSpeedPlus' }
            0x0D { 'BILLBOARD' }
            0x0F { 'Billboard Alternate Mode' }
            default { "type 0x{0:X2}" -f $capType }
        }
        "    cap @$o len=$len : $name"

        if ($capType -eq 0x0D -and $len -ge 44) {
            $numAlt = $b[$o + 4]
            $pref = $b[$o + 5]
            # bmConfigured is 32 bytes starting at offset 8 within the capability.
            $cfgOff = $o + 8
            $failInfo = $b[$o + 42]
            "      bNumberOfAlternateModes = $numAlt"
            "      bPreferredAlternateMode = $pref"
            "      bAdditionalFailureInfo  = 0x{0:X2}{1}" -f $failInfo, $(
                $f = @()
                if ($failInfo -band 0x01) { $f += 'no USB PD communication' }
                if ($failInfo -band 0x02) { $f += 'no battery/insufficient power' }
                if ($f) { "  (" + ($f -join '; ') + ")" } else { '' }
            )

            $modeOff = $o + 44
            for ($i = 0; $i -lt $numAlt; $i++) {
                $mo = $modeOff + ($i * 4)
                if ($mo + 3 -ge $b.Length) { break }
                $svid = [BitConverter]::ToUInt16($b, $mo)
                $alt = $b[$mo + 2]
                # Two bits per mode, packed little-endian across bmConfigured.
                $bitPos = $i * 2
                $byte = $b[$cfgOff + [Math]::Floor($bitPos / 8)]
                $state = ($byte -shr ($bitPos % 8)) -band 0x3
                $stateName = switch ($state) {
                    0 { 'UNSPECIFIED ERROR' }
                    1 { 'not attempted' }
                    2 { 'ATTEMPTED BUT UNSUCCESSFUL' }
                    3 { 'successful' }
                }
                $svidName = switch ($svid) {
                    0xFF01 { ' (DisplayPort)' }
                    0x8087 { ' (Intel/TBT)' }
                    default { '' }
                }
                "      mode[$i]: SVID=0x{0:X4}{1} bAlternateMode={2} -> {3}" -f $svid, $svidName, $alt, $stateName
            }
        }

        if ($len -le 0) { break }
        $o += $len
    }
}

if (-not $DevicePath) {
    # Enumerate Billboard devices that are actually present. The registry keeps stale
    # instance IDs after a hub re-enumerates, and USB instance IDs churn often enough
    # that acting on a stale one produces a confusing "file not found".
    $present = @(Get-PnpDevice -PresentOnly -EA SilentlyContinue |
            Where-Object { $_.InstanceId -like 'USB\*' -and $_.FriendlyName -match 'illboard' } |
            Select-Object -ExpandProperty InstanceId)

    $DevicePath = @()
    foreach ($id in $present) {
        $dp = "HKLM:\SYSTEM\CurrentControlSet\Enum\$id\Device Parameters"
        $sn = (Get-ItemProperty $dp -EA SilentlyContinue)
        if ($sn -and $sn.PSObject.Properties['SymbolicName']) {
            $DevicePath += ($sn.SymbolicName -replace '^\\\?\?\\', '\\?\')
        }
    }

    if (-not $DevicePath) {
        Write-Warning "No Billboard device is present. A USB-C device exposes one to report that an Alternate Mode could not be entered, so its absence can itself be meaningful."
        return
    }
}

foreach ($p in $DevicePath) {
    "=== $p ==="
    $r = Read-Descriptor -Path $p
    if ($r.Error) { "    $($r.Error)" }
    else {
        "    raw ($($r.Length) bytes): " + (($r.Bytes | ForEach-Object { $_.ToString('X2') }) -join ' ')
        Show-Bos -b $r.Bytes
    }
    ""
}
