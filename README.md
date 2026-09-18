# dotfiles

Personal dotfiles for Windows / PowerShell and macOS / zsh.

## Install

```powershell
# 1. Clone the repo
git clone https://github.com/felickz/dotfiles.git "$env:USERPROFILE\dotfiles"

# 2. Run the install script (requires Admin for symlinks)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
& "$env:USERPROFILE\dotfiles\install.ps1"
```

The install script creates a **symbolic link** from your `$PROFILE` path to [`pwsh/Microsoft.PowerShell_profile.ps1`](pwsh/Microsoft.PowerShell_profile.ps1), so edits in either location stay in sync.

If an existing profile is found, it is backed up with a timestamp before creating the symlink.

### macOS

```bash
git clone https://github.com/felickz/dotfiles.git "$HOME/dotfiles"
cd "$HOME/dotfiles"
./install-macos.sh
```

The installer links the version-controlled [`.zshrc`](.zshrc) to `~/.zshrc` and
[`desk-monitor`](macos/bin/desk-monitor) to `~/.local/bin/desk-monitor`. Existing
files are backed up with a timestamp before a link is created. The command uses Dell
Display and Peripheral Manager's CLI when DDPM is installed, with `m1ddc` as an
optional fallback. The profile supplies:

```bash
swmon list    # identify the external display (this P2725DE is index 1)
swmon status
swmon pc      # switch the right Dell to the Windows PC's DisplayPort
swmon mac     # switch it back to the Mac's USB-C input
```

`desk-monitor` remains the underlying command, and the older `desk-pc` and
`desk-mac` convenience aliases remain available.

The default display and Dell input codes are version controlled in
[`macos/desk-monitor.conf`](macos/desk-monitor.conf). DDPM currently identifies the
P2725DE as index `1`.

To create only the zsh profile link manually:

```bash
# Back up an existing regular profile first, if present.
mv "$HOME/.zshrc" "$HOME/.zshrc.backup.$(date +%Y%m%d%H%M%S)"

ln -s "$HOME/Repos/dotfiles/.zshrc" "$HOME/.zshrc"
source "$HOME/.zshrc"
```

If `~/.zshrc` is already the correct symlink, no backup is needed. Verify it with:

```bash
readlink "$HOME/.zshrc"
```

## Modern Standby

The profile includes a reversible sleep optimization for the Surface Laptop Studio 2 and
Plugable UD-ULTC4K dock:

```powershell
DeepSleep On       # Disable standby networking and the unused dock audio interface
DeepSleep Off      # Restore both settings to their original enabled values
Get-DeepSleep      # Report the current state
```
`DeepSleep` requires elevation and opens a UAC prompt when needed. It does not change
DisplayLink video, Ethernet, USB, charging, wake devices, hibernation, or PowerToys Awake.
DisplayLink video, Ethernet, USB, charging, wake devices, hibernation, or PowerToys Awake.
