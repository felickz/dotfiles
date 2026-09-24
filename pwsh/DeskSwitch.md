# DeskSwitch

Point three machines at one set of monitors, without a KVM.

```powershell
swdesk            # claim this machine's monitors (profile auto-picked by hostname)
swdesk mac        # hand the right monitor to the Mac
gmin -Detailed    # what each monitor is on, and what it supports
```

## The desk

| Position | Monitor | Inputs it advertises | Used by |
|---|---|---|---|
| Left | Dell P2725DE | DP, HDMI, **USB-C** | main on DP, personal Surface on USB-C |
| Center | Dell P3425WE (34" UW) | **USB-C**, DP, HDMI | main only |
| Right | Dell P2725DE | DP, HDMI, **USB-C** | main on DP, Mac on USB-C |
| Below | Surface Laptop Studio 2 panel | *(no DDC/CI)* | main |

| Easy-Switch | Machine | Hostname | Result |
|---|---|---|---|
| 1 | Surface Laptop Studio 2 | `SURFACESTUDIO2` | all three monitors on DP |
| 2 | Mac M5 Pro | `H17MX7TXMT` | right monitor to USB-C |
| 3 | Surface Laptop 5 | `SURFACE-LAPTOP5` | left monitor to USB-C |

Only **DP** and **USB-C** are used in practice. HDMI is listed because the monitors
advertise it, but nothing on this desk is wired to it - the left panel used to be a
P2725D whose only second input was HDMI, and it was replaced by a USB-C P2725DE. Passing
`HDMI` explicitly still works; nothing chooses it on your behalf.

## Why the Easy-Switch key is not the trigger

The obvious design is "detect the Easy-Switch press and switch inputs." That is not
possible on the machine you are leaving, on Windows or macOS. The Easy-Switch buttons
are consumed by the Logitech device firmware to change its radio connection; they are
not delivered to the host as normal key events. On Windows this was also measured
rather than assumed:

- The keyboard connects through a **Logi Bolt receiver** (`VID_046D&PID_C548`). The
  receiver presents a **fixed** set of HID endpoints (`MI_00`–`MI_03`). Pressing
  Easy-Switch moves the keyboard's radio link to a different host but leaves every one
  of those endpoints enumerated, so no device arrives or departs. PnP sees nothing.
- The receiver's keyboard and mouse collections are claimed by `kbdclass`/`mouclass`,
  so user-mode cannot read their reports either. A capture across a full
  switch-away-and-back cycle recorded zero reports on every collection, including the
  vendor HID++ channels.
- Even if a signal existed, the machine being left cannot tell whether you pressed 2 or
  3. It only knows the keyboard is gone.

So DeskSwitch inverts it. **No machine detects the key. Each machine claims the inputs
it owns when it sees local user input.** Press Easy-Switch, start typing, and that
machine takes its monitors. Nothing is networked, paired or synchronised.

DDPM's input-source hotkey is useful, but it cannot bind the firmware-only Easy-Switch
buttons either. It can bind an ordinary keyboard shortcut, and Logi Options+ can map a
normal remappable mouse button to that shortcut. The three MX Keys device-selection
buttons and a mouse's underside Easy-Switch button cannot be used as the trigger.

This also means the return path is automatic: come back to the main PC, type, and it
pulls all three monitors back to DP.

## How the switching works

Input selection is the MCCS **Input Source** control, VCP code `0x60`, sent over DDC/CI
on the display cable's I2C channel. That is a monitor-side standard, so no Dell agent,
driver or vendor tool is involved. Dell Display and Peripheral Manager can stay
installed or be removed; DeskSwitch does not use it.

| Input | VCP (hex) | m1ddc (decimal) |
|---|---|---|
| DisplayPort 1 | `0x0F` | 15 |
| HDMI 1 | `0x11` | 17 |
| USB-C | `0x1B` | 27 |

Two implementation details that matter:

- **Roles are resolved by screen X position, not display index or model.** Windows
  renumbers `\\.\DISPLAYn` across docking and driver updates, and both side monitors are
  the same model, so neither index nor model can reliably identify "the left one".
- **A machine that reaches one monitor does not need a role at all.** The personal laptop
  is USB-C to the left panel and the Mac is USB-C to the right one, so each sees exactly
  one DDC-capable monitor and there is nothing to choose between. A lone monitor is
  reported as role `Only`, `smin DP` targets it without naming a position, and a role that
  does not match - `smin Left DP` from the personal laptop - still lands on it. The
  fallback is disabled when applying a profile that owns more than one position, so a
  three-monitor profile can never drive one panel three times.
- **A monitor already on the target input is skipped.** That is what makes the follow
  watcher safe to poll forever: while you work on one machine the monitors already
  match, so no DDC traffic is generated and nothing flickers. Work happens only on the
  transition.

### Verified: DDC answers on an inactive cable

The return path depends on the main PC commanding a monitor whose DP cable is *not* the
active input. Some monitors only answer DDC on the input they are currently showing,
which would let a machine give a monitor away but never take it back.

Measured on this desk: the right P2725D was switched to HDMI, and while it was showing
HDMI the main PC could still **read** it over the inactive DP cable (`0x11`) and switch
it straight back to DP on the first attempt. So reclaiming works here.

If a future monitor does not behave this way, the fix is to invert the release: have the
machine that is *leaving* hand the monitor back while its own input is still active
(e.g. the Mac sets the right monitor to DP once it has been idle for a while), rather
than the returning machine reclaiming it.

## Handing a monitor over

Implemented - see "Ownership and auto-detach" below. A handover both switches the input
and drops the monitor from this desktop, so neither the cursor nor a window can land on
a screen that is showing another machine.

## Windows setup (main and personal)

Both Windows machines run the same module. The profile map decides what each claims:

```powershell
$Global:DeskProfiles = [ordered]@{
    main     = @{ HostName = 'SURFACESTUDIO2'  ; Monitors = [ordered]@{ Left = 'DP'; Center = 'DP'; Right = 'DP' } }
    mac      = @{ HostName = 'H17MX7TXMT'      ; Monitors = [ordered]@{ Right = 'USBC' } }
    personal = @{ HostName = 'SURFACE-LAPTOP5' ; Monitors = [ordered]@{ Left  = 'USBC' } }
}
```

Make it automatic:

```powershell
Start-DeskFollow          # run in the foreground to watch it work
Register-DeskFollow       # or install it as a logon task (no admin needed)
```

`Register-DeskFollow` runs unelevated on purpose: DDC/CI needs no administrator rights.

On the **personal Surface Laptop 5**, install the same module and keep the same map. It
resolves `personal` from its own hostname and claims only the left monitor - and because
that is the only monitor it can reach, `smin USBC` and `smin Left USBC` both work there
without arguing about positions.

> Editing this map is the whole upgrade path, and it is the one thing to re-check after a
> monitor swap. When the left P2725D became a USB-C P2725DE this entry stayed on `HDMI`
> for a while, so `swdesk` kept driving the panel to a dead input. A shell started before
> the edit keeps the old map in memory, so re-run `. $PROFILE` or open a new window after
> changing it.

## macOS setup (Mac M5 Pro)

The installed Dell Display and Peripheral Manager 2.3 CLI can control the P2725DE:

```bash
/Applications/DDPM/DDPM.app/Contents/MacOS/DDPM \
  /get -Display=ActiveInputSource -Index=1
/Applications/DDPM/DDPM.app/Contents/MacOS/DDPM \
  /set -Display=ActiveInputSource -Index=1 -value=DP
```

DDPM also offers this through its **Input Source > Hotkey** UI. The CLI is preferable
for dotfiles because the command, aliases, display index, and source names can all be
reviewed and version controlled instead of living only in DDPM's local preferences.

The repository wraps this in a simpler, version-controlled setup:

```bash
./install-macos.sh
swdesk list
swdesk status
swdesk              # toggle USB-C (Mac) <-> DP (main PC)
swdesk pc           # input 15: DisplayPort 1, connected to the main Windows PC
swdesk mac          # input 27: USB-C, connected to this Mac
```

The display index is `auto` by default, matching the Windows side: this Mac is USB-C to a
single monitor, so the one it can see is used and no index has to be named. Pass one
(`swdesk pc 2`) or set `DESK_MONITOR_DISPLAY` only if several are ever attached.

The installer links the command into `~/.local/bin` and links the repository's
`.zshrc` to `~/.zshrc`; the implementation and configuration remain in this
repository and are therefore version controlled. If DDPM is absent, the wrapper can fall back to
[`m1ddc`](https://github.com/waydabber/m1ddc). Manual commands are intentional.
Automatically claiming USB-C on any Mac input can steal the screen when the built-in
keyboard or trackpad is touched while the Logitech devices are still assigned to
Windows.

The cable is part of the DDC path. A third-party cable labeled Thunderbolt 4, USB4, and
40 Gbps delivered 90 W but exposed neither USB data nor DisplayPort Alt Mode here. With
the USB-C cable supplied with the P2725DE, macOS and DDPM keep the monitor enumerated
while it is showing DP, and the Mac can reclaim it with bare `swdesk`.

`install-macos.sh` also builds the repository's `display-topology` helper. `swdesk pc`
switches the Dell to DP and then disables it from the macOS desktop; reclaiming it
re-enables the desktop before selecting USB-C. The helper uses the private
`CGSConfigureDisplayEnabled` API with session-scoped changes and safety checks. Its
source credits the MIT-licensed
[macos-displayctl](https://github.com/hiberabyss/macos-displayctl) and
[displayplacer](https://github.com/jakehilborn/displayplacer) projects, with full
license notices in `macos/THIRD_PARTY_NOTICES.md`.

> DDPM supports this P2725DE on Apple Silicon. BetterDisplay exposes similar CLI
> controls if neither DDPM nor `m1ddc` can see a future display.

## Rotation

```powershell
grot                    # how each monitor is currently rotated
rot Right Portrait      # turn the right monitor vertical
rot Right               # toggle back (bare = flip landscape <-> portrait)
rot Right Landscape     # explicit
rot Portrait            # no role needed when only one monitor is attached
```

Rotation is a **Windows display-config change, not a DDC one** - the monitor panel itself
has no idea it happened. So this uses `ChangeDisplaySettingsEx` with `DM_DISPLAYORIENTATION`
rather than a VCP code, which also means it works on a display that is not answering DDC.

Width and height are swapped automatically when crossing between landscape and portrait.
Without that the call fails with `DISP_CHANGE_BADMODE`: the driver validates the requested
mode against the requested orientation, so a 2560x1440 panel has to be asked for 1440x2560
when turned on its side.

Windows repacks the desktop around the new shape, so neighbouring monitors may shift.

## Ownership and auto-detach

```powershell
gown                 # who actually drives each monitor right now
swdesk               # take everything back: re-attach, then set inputs
syncmon              # drop monitors another machine took
setprim '\\.\DISPLAY1'   # move "primary" by hand, if ever needed
autodetach Off       # pause it for a quick hop to the other machine
autodetach On

Start-DeskGuard      # watch continuously
Register-DeskGuard   # ...and do that from every logon (no admin)
```

`swdesk` is the "give me all my monitors back" shortcut: it re-attaches anything the guard
dropped, then switches each one to this machine's input. `syncmon` only reconciles the
desktop, and does not re-attach by default - a detached monitor cannot answer DDC, so the
only way to test whether it came back is to attach it and look, which flaps the desktop if
it is still the other machine's. Use `syncmon -Reclaim` if you want that check.

Switching a monitor's input is only half a handover. The cable this machine is on stays
trained, so Windows keeps extending the desktop onto a panel that is now showing another
machine: the cursor vanishes into it and windows land there invisibly. That happens in both
directions, so the same fix is needed on the side machines too.

Detection works because these Dells keep answering DDC over an **inactive** cable. This
machine reads VCP `0x60`, sees `USBC` on a monitor it reaches over DisplayPort, and
concludes someone else owns it:

```
Role   Monitor                        Input Expected Owned
Left   Dell P2725DE (DisplayPort 1_4) USBC  DP       False
Center Dell P3425WE(DisplayPort 1.4)  DP    DP       True
```

`Expected` comes from the `$DeskProfiles` entry matching this hostname - the map already
records which cable each machine is on, so ownership needs no extra configuration. A role
with no profile entry reports `Owned` as null and is never touched.

### Why it polls

Windows raises no event for this. The input switch happens entirely inside the monitor, so
the display configuration never changes and there is nothing to subscribe to. Reading
VCP `0x60` on a timer is the only way to notice.

The poll is cheap: it stops after the read unless ownership actually changed.

### The grace period

A monitor must look unowned for `DetachDelaySeconds` (default 20) before it is dropped, so
hopping to another machine and straight back does not reflow the desktop twice. Settings
live in `%LOCALAPPDATA%\deskswitch-config.json` and are re-read every pass, so
`autodetach Off` takes effect immediately in a guard that is already running - it does not
need restarting.

### Re-attaching is deliberate, not automatic

A detached monitor leaves the HMONITOR enumeration entirely, so it cannot answer DDC and
the guard cannot see it come back. Take monitors back explicitly:

```powershell
smin Left DP     # re-attaches first, then switches the input
swdesk           # same, for every monitor this machine owns
syncmon          # re-attach anything previously detached
```

`Set-MonitorInput` handles both directions: asking for an input this machine owns
re-attaches first, and handing a monitor to another machine detaches it afterwards.

### Constraints worth knowing

- Detaching **wipes** the display's saved mode, and rewrites the saved topology so
  `SDC_TOPOLOGY_EXTEND` will not undo it. Geometry is saved to
  `%LOCALAPPDATA%\deskswitch-detached.json` before detaching and replayed on the way back.
- Windows silently refuses to detach the **primary** display: the call reports success and
  nothing changes. Rather than giving up, primary is first handed to a display this machine
  can still see, then the detach proceeds. The built-in laptop panel is preferred because it
  has no DDC and so can never be taken by another machine. This is the common case on the
  side machines, where the single external monitor *is* the primary display - before it was
  handled, `syncmon` simply refused and the screen stayed on the desktop.
- Roles are worked out from screen X **including** detached monitors, so handing over the
  left panel does not silently promote the centre one to "Left".
- A monitor that has just had its input switched **drops out of the DDC enumeration for a
  few seconds**, which shifts the roles of everything still visible. Anything acting on a
  monitor it has already found therefore passes the GDI device name rather than re-resolving
  by role - without that, detaching "Left" could target the centre panel.
- The watchers run as `-NoProfile` scheduled tasks, where `$DeskProfiles` does not exist.
  Registering one snapshots the map to `%LOCALAPPDATA%\deskswitch-profiles.json`. After
  editing `$DeskProfiles`, run `Save-DeskProfileMap` to refresh it.

## Brightness

```powershell
gmb                # every monitor + the laptop panel
smb 40             # all externals to 40%
smb 65 Center      # just one
syncbr             # match externals to the laptop right now
syncbr -10         # ...but keep externals 10 points dimmer

Start-BrightnessFollow           # externals track the laptop's brightness keys live
Register-BrightnessFollow        # ...and do that from every logon (no admin)
```

The first argument is positional throughout, so `smb 40` and `smin Right HDMI` work without
naming parameters. The named forms (`smb -Percent 40 -Role Center`) still bind as before.
The role is optional as well: `smin DP` and `rot Portrait` are enough on a machine wired
to a single monitor.

**Dell Display and Peripheral Manager is not involved.** Brightness is the MCCS
"Luminance" control, VCP `0x10`, on the same DDC/CI channel as input switching, so it works
with no vendor agent and the same code path everywhere.

The laptop panel is the exception: it is not on DDC at all. It is driven by the graphics
driver and exposed through WMI (`root\wmi` `WmiMonitorBrightness` /
`WmiMonitorBrightnessMethods`). That split is why the follow watcher reads one API and
writes another.

### Following the laptop's brightness keys

Windows raises `WmiMonitorBrightnessEvent` whenever the built-in panel changes, and the
event carries the new value. So the keyboard brightness keys, the Action Center slider and
adaptive brightness all drive the externals equally, with no polling, no hotkey to steal
and no key interception.

Holding a brightness key fires a burst of events. They are coalesced: the watcher waits
for a quiet period (`-DebounceMs`, default 400) and applies only the final value, so each
gesture costs one DDC write per monitor instead of one per keystroke. A monitor already at
the target value is skipped entirely.

Verified end to end: driving the laptop panel to 30%, 70% and 50% moved all three monitors
to exactly 30, 70 and 50.

### The one-time power-consumption prompt

Raising brightness past a Dell monitor's energy threshold (75% here) makes the monitor pop
an on-screen "power consumption" confirmation. While that dialog is up **the monitor stops
answering DDC brightness entirely** - the write is held, reads fail, and the value does not
move until someone presses a button on the monitor itself. That looks exactly like a silent
failure: `SetVCPFeature` returns success and the readback still shows the old value.

It only appears once per monitor. Once acknowledged, values above the threshold apply
normally, so brightness is not clamped by default. If a monitor has not been acknowledged
yet, or an unattended follow should stay in a comfortable band:

```powershell
$Global:DeskBrightnessMax = 75   # never exceed this when syncing/following
$Global:DeskBrightnessMin = 10   # never dim below this
```

These bound the unattended paths only. An explicit `smb 90` is treated as deliberate and is
never clamped.

### macOS

`m1ddc` drives the same VCP control, so the Mac can match:

```bash
m1ddc display 1 set luminance 40
m1ddc display 1 get luminance
```

## USB-C on the side monitors (P2725DE) - done

The side monitors have been upgraded from P2725D to **P2725DE**, and the forward-compatible
design held: nothing in the module changed. Because the input list is read from each
monitor's own MCCS capability string, the new capability simply appeared:

```
Role   Monitor                        Input  Supports
Left   Dell P2725DE (DisplayPort 1_4) DP     USBC,DP,HDMI
Center Dell P3425WE(DisplayPort 1.4)  DP     USBC,DP,HDMI
Right  Dell P2725DE (DisplayPort 1_4) DP     USBC,DP,HDMI
```

All three now advertise `USBC`, where the old P2725Ds offered only `DP,HDMI`. Moving a
machine onto the single-cable USB-C path is now a one-word edit per line:

```powershell
mac      = @{ HostName = 'H17MX7TXMT'      ; Monitors = [ordered]@{ Right = 'USBC' } }
personal = @{ HostName = 'SURFACE-LAPTOP5' ; Monitors = [ordered]@{ Left  = 'USBC' } }
```

The checked-in Mac configuration already uses input `27`.

Run `gmin -Detailed` after any hardware change to see what each monitor actually offers.

## Two display paths, and why that decides which fix works

The three external monitors are not driven the same way, and every recovery attempt that
failed did so because it was aimed at the wrong path.

| Monitor | GDI slots | Driven by | Recovers with |
| --- | --- | --- | --- |
| 2x P2725DE (sides) | `DISPLAY25-28` | **DisplayLink** over USB | `rtmon`, `Reset-Dock` |
| P3425WE (centre) | `DISPLAY30-33` | **Intel Iris Xe** via the dock's alt-mode output | dock power-cycle only |

The centre monitor hangs off the dock's **alt-mode output**: DisplayPort passed through to the
laptop's own GPU, not rendered by DisplayLink. So:

- `rtmon` resets failed DisplayLink devices and can never reach it. It used to log
  "No failed DisplayLink adapters found" and stop, which read like a no-op rather than the
  wrong tool; it now says so.
- Updating the DisplayLink driver does not touch its video path either.

Measured against this fault, none of these recovered it: cycling the dock's USB controller
(`Reset-Dock -Depth Controller`), cycling the Intel GPU that owns the output, or cycling the
UCSI connector manager. **Only a power-cycle of the dock at the wall has worked**, twice.
USB-C alt mode is negotiated between the dock's PD controller and the laptop's PD/retimer
chips, and Windows cannot re-drive that handshake - it only renegotiates on real power loss.

### Why the discrete GPU is not involved at all

This laptop has an RTX 4060, but it drives no monitors:

| Adapter | GDI display slots | Monitors attached |
| --- | --- | --- |
| Intel Iris Xe | 4 | laptop panel, alt-mode output |
| DisplayLink | 4 | both side monitors |
| **NVIDIA RTX 4060** | **0** | **none** |

That is muxless hybrid graphics, not a misconfiguration. The physical display outputs - the
internal panel and the USB-C lanes carrying DP alt mode - are wired to the Intel iGPU's
display engine. The discrete GPU renders into its own memory and copies finished frames into
Intel's framebuffer, and Intel scans them out. It never owns a display, so it has no display
outputs to enumerate. The point is power: the iGPU can keep screens lit while the dGPU sleeps.

Two consequences worth remembering:

- **An NVIDIA driver update can never fix a monitor fault on this machine.** It owns no
  outputs, so nothing it does reaches a display link.
- **Intel is the display driver here** for everything that is not DisplayLink. That is why the
  Intel driver being well out of date matters for the alt-mode fault, and why it is the one
  worth updating.

Games and GPU work still use the 4060 normally; only scan-out belongs to Intel.

### Where these drivers actually come from

Neither ships through Windows Update, which reports zero updates even with optional ones
included - so an empty update list is not evidence that things are current.

| | Source |
| --- | --- |
| DisplayLink | `winget install DisplayLink.GraphicsDriver`, or Synaptics directly. The package also flashes the dock's own firmware, which tracks the driver version. Installing updates the tray app immediately but leaves the old kernel driver bound - the installer ships a DisplayLinkDriverSwapService that completes the swap on reboot, so check the driver version rather than the app's About box to confirm. |
| Intel Iris Xe | Not on winget as a driver package. Closest is `winget install Intel.IntelDriverAndSupportAssistant` (Intel DSA, which scans and offers), or "Intel Graphics Software" from the Store. DSA normally refuses on Surface with "your manufacturer customized this driver", but this machine already runs a driver whose provider is "Intel Corporation" rather than Microsoft, so the direct route may be open. |
| Fallback | The Surface driver pack MSI, which is not on winget and must match the installed Windows build. |

Because the dock's firmware ships inside the DisplayLink package, updating DisplayLink is
still worth trying for an alt-mode fault even though it cannot touch that video path - the
dock is the device failing to renegotiate.

That was tried. The 11.7 -> 12.2 upgrade completed after a reboot (driver 12.2.2412.0 dated
2026-06-18, Ethernet 12.2.1708.0), and the dock still reports the same USB revision,
`REV_3110`, so the DL chip firmware it carries was already current. The ultrawide did not
come back. Worth doing for its own sake - a major version of link-stability fixes - but it is
not a fix for this fault, and the alt-mode path remains power-cycle-only.

### The dock's MST chipset firmware is a separate thing

The DisplayLink package carries firmware for the **DisplayLink** chip, which drives the side
monitors. The alt-mode output is handled by a different chip: a Synaptics **VMM5200
DisplayPort MST** controller, whose firmware the DisplayLink package does not touch. That
chip is the one negotiating the link that keeps failing, so its firmware is the remaining
plausible software-level fix.

Plugable publishes a VMM5200 firmware update guide, but **for the UD-3900C4, not the
UD-ULTC4K**. Do not run it here: the guide states the update is one-way and the dock cannot
be reflashed to the previous version, so a wrong-model flash is unrecoverable. There is no
published tool for the UD-ULTC4K, and there are two hardware revisions of it, so Plugable
handles this through support with the unit's serial number.

If the fault keeps recurring, that is the request to make - quoting the exact symptom:

> The DisplayPort alt-mode output stops being detected after Modern Standby. Windows reports
> no EDID on any input, so the monitor is invisible to the OS rather than merely on the wrong
> input. Cycling the dock's USB controller, the host GPU that owns the output, and the UCSI
> connector manager all fail to recover it; only a physical power-cycle of the dock does.
> DisplayLink is current at 12.2.2412.0 and the dock reports USB revision REV_3110.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `No DDC-capable monitor in the 'X' position` | Monitor asleep or on an input whose cable is unplugged. DDC only answers on a connected cable. |
| A monitor never switches back | Some monitors only answer DDC on the **active** input (not the case on these P2725Ds, which were tested). Use the monitor's OSD to return it once, then invert the release so the machine leaving hands the monitor back while its own input is still active. |
| Inputs flip back and forth | Two machines both claim the same monitor. Check the profile map: each monitor should be claimed by exactly one machine per Easy-Switch position. |
| Nothing happens after docking | Roles are resolved at call time from screen X. If Windows has not finished re-arranging displays, re-run. |
| Brightness write "succeeds" but nothing changes | The monitor is showing its one-time power-consumption prompt and has stopped answering DDC. Press a button on the monitor to acknowledge it. |
| `[DeskSwitch.Native] does not contain a method named ...` | That shell loaded an older version of the module. .NET cannot replace a type once it is in the AppDomain, so `Import-Module -Force` and re-sourcing `$PROFILE` both leave the old one in place. **Open a new window.** The module now detects this at import and says so. |
| A monitor shows "no signal" and `fixmon` says it is not reachable | Its link is down, not merely detached - there is no EDID for anything to command. See the two display paths above: if it is on the dock's alt-mode output, only a dock power-cycle at the wall has ever recovered it. |
| `rtmon` reports "no failed DisplayLink adapters" and does nothing | The missing monitor is not DisplayLink-driven, so `rtmon` is the wrong tool. It now says this instead of stopping silently. |
