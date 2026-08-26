# dotfiles

Personal dotfiles for Windows / PowerShell.

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