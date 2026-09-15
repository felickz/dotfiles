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
| Left | Dell P2725D | DP, HDMI | main on DP, personal Surface on HDMI |
| Center | Dell P3425WE (34" UW) | **USB-C**, DP, HDMI | main only |
| Right | Dell P2725DE | DP, HDMI, **USB-C** | main on DP, Mac on USB-C |
| Below | Surface Laptop Studio 2 panel | *(no DDC/CI)* | main |

| Easy-Switch | Machine | Hostname | Result |
|---|---|---|---|
| 1 | Surface Laptop Studio 2 | `SURFACESTUDIO2` | all three monitors on DP |
| 2 | Mac M5 Pro | `H17MX7TXMT` | right monitor to USB-C |
| 3 | Surface Laptop 5 | `SURFACE-LAPTOP5` | left monitor to HDMI |

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

## Windows setup (main and personal)

Both Windows machines run the same module. The profile map decides what each claims:

```powershell
$Global:DeskProfiles = [ordered]@{
    main     = @{ HostName = 'SURFACESTUDIO2'  ; Monitors = [ordered]@{ Left = 'DP'; Center = 'DP'; Right = 'DP' } }
    mac      = @{ HostName = 'H17MX7TXMT'      ; Monitors = [ordered]@{ Right = 'USBC' } }
    personal = @{ HostName = 'SURFACE-LAPTOP5' ; Monitors = [ordered]@{ Left  = 'HDMI' } }
}
```

Make it automatic:

```powershell
Start-DeskFollow          # run in the foreground to watch it work
Register-DeskFollow       # or install it as a logon task (no admin needed)
```

`Register-DeskFollow` runs unelevated on purpose: DDC/CI needs no administrator rights.

On the **personal Surface Laptop 5**, install the same module and keep the same map. It
resolves `personal` from its own hostname and claims only the left monitor.

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
swmon list
swmon status
swmon pc            # input 15: DisplayPort 1, connected to the main Windows PC
swmon mac           # input 27: USB-C, connected to this Mac
```

The installer links the command into `~/.local/bin` and links the repository's
`.zshrc` to `~/.zshrc`; the implementation and configuration remain in this
repository and are therefore version controlled. If DDPM is absent, the wrapper can fall back to
[`m1ddc`](https://github.com/waydabber/m1ddc). Manual commands are intentional.
Automatically claiming USB-C on any Mac input can steal the screen when the built-in
keyboard or trackpad is touched while the Logitech devices are still assigned to
Windows.

> DDPM supports this P2725DE on Apple Silicon. BetterDisplay exposes similar CLI
> controls if neither DDPM nor `m1ddc` can see a future display.

## Upgrading the side monitors to USB-C (P2725DE)

Forward compatible by design. The input list is read from each monitor's own MCCS
capability string, so after fitting the new panels:

```powershell
gmin -Detailed
```

`USBC` will appear in the `Supports` column for the side monitors (the P3425WE already
advertises it today). Then change only the profile map:

```powershell
mac      = @{ HostName = 'H17MX7TXMT'      ; Monitors = [ordered]@{ Right = 'USBC' } }
personal = @{ HostName = 'SURFACE-LAPTOP5' ; Monitors = [ordered]@{ Left  = 'USBC' } }
```

The checked-in Mac configuration already uses input `27`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `No DDC-capable monitor in the 'X' position` | Monitor asleep or on an input whose cable is unplugged. DDC only answers on a connected cable. |
| A monitor never switches back | Some monitors only answer DDC on the **active** input (not the case on these P2725Ds, which were tested). Use the monitor's OSD to return it once, then invert the release so the machine leaving hands the monitor back while its own input is still active. |
| Inputs flip back and forth | Two machines both claim the same monitor. Check the profile map: each monitor should be claimed by exactly one machine per Easy-Switch position. |
| Nothing happens after docking | Roles are resolved at call time from screen X. If Windows has not finished re-arranging displays, re-run. |
