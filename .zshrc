# User-local tool installers may add environment setup here.
[ -r "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

export PATH="$HOME/.local/bin:$PATH"

alias desk-mac='desk-monitor mac'
alias desk-pc='desk-monitor pc'
