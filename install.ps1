#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs dotfiles by creating symbolic links to the correct locations.
.DESCRIPTION
    Creates a symlink from the PowerShell profile in this repo to the
    current user's $PROFILE path. Must be run as Administrator (symlinks
    require elevated privileges on Windows).
.EXAMPLE
    # Clone and install
    git clone https://github.com/felickz/dotfiles.git "$env:USERPROFILE\dotfiles"
    & "$env:USERPROFILE\dotfiles\install.ps1"
#>

$ErrorActionPreference = 'Stop'

# Mirrors the macOS guard in install-macos.sh. This installer links the Windows
# PowerShell profile, which pulls in DeskSwitch and its user32/dxva2 P/Invokes, so it is
# Windows-only. $IsWindows exists in PowerShell 6+; on Windows PowerShell 5.1 it is
# undefined, and that only ever runs on Windows anyway.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Error 'install.ps1: Windows is required. On macOS run ./install-macos.sh instead.'
    return
}

$dotfilesRoot = $PSScriptRoot

# --- PowerShell Profile ---
$source = Join-Path $dotfilesRoot 'pwsh\Microsoft.PowerShell_profile.ps1'
$target = $PROFILE.CurrentUserCurrentHost

if (-not (Test-Path $source)) {
    Write-Error "Source profile not found: $source"
    return
}

$targetDir = Split-Path $target -Parent
if (-not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    Write-Host "Created directory: $targetDir" -ForegroundColor Green
}

if (Test-Path $target) {
    $item = Get-Item $target -Force
    if ($item.LinkType -eq 'SymbolicLink') {
        $existingTarget = $item.Target
        if ($existingTarget -eq $source) {
            Write-Host "Symlink already exists and points to the correct source. Nothing to do." -ForegroundColor Green
            return
        }
        Write-Host "Existing symlink points to: $existingTarget" -ForegroundColor Yellow
    }

    $backup = "$target.backup.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Move-Item -Path $target -Destination $backup -Force
    Write-Host "Backed up existing profile to: $backup" -ForegroundColor Yellow
}

New-Item -ItemType SymbolicLink -Path $target -Target $source -Force | Out-Null
Write-Host "Symlinked: $target -> $source" -ForegroundColor Green
Write-Host "Done! Restart PowerShell to load the new profile." -ForegroundColor Cyan
