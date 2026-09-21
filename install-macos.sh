#!/bin/sh

set -eu

if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' "install-macos.sh: macOS is required." >&2
    exit 1
fi

dotfiles_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
config_root="$HOME/.config/dotfiles"
bin_root="$HOME/.local/bin"
zshrc="$HOME/.zshrc"

mkdir -p "$config_root" "$bin_root"

link_path() {
    source_path=$1
    target_path=$2

    if [ -L "$target_path" ] && [ "$(readlink "$target_path")" = "$source_path" ]; then
        printf 'Already linked: %s\n' "$target_path"
        return
    fi

    if [ -e "$target_path" ] || [ -L "$target_path" ]; then
        backup="${target_path}.backup.$(date +%Y%m%d%H%M%S)"
        mv "$target_path" "$backup"
        printf 'Backed up: %s -> %s\n' "$target_path" "$backup"
    fi

    ln -s "$source_path" "$target_path"
    printf 'Linked: %s -> %s\n' "$target_path" "$source_path"
}

link_path "$dotfiles_root/macos" "$config_root/macos"
link_path "$dotfiles_root/macos/bin/desk-monitor" "$bin_root/desk-monitor"
link_path "$dotfiles_root/.zshrc" "$zshrc"

if [ ! -x "/Applications/DDPM/DDPM.app/Contents/MacOS/DDPM" ] &&
    ! command -v m1ddc >/dev/null 2>&1; then
    printf '%s\n' \
        "Warning: neither DDPM nor m1ddc is installed." \
        "Install Dell Display and Peripheral Manager, or run: brew install m1ddc" >&2
fi

printf '\nInstalled. Start a new shell or run:\n  source "%s"\n\n' "$zshrc"
printf 'Then verify the display and switch it:\n'
printf '  swdesk list\n'
printf '  swdesk pc     # right Dell: USB-C -> Windows DisplayPort\n'
printf '  swdesk mac    # right Dell: DisplayPort -> Mac USB-C\n'
