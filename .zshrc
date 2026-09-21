# User-local tool installers may add environment setup here.
[ -r "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

export PATH="$HOME/.local/bin:$PATH"

# Monitor input switching. These names match the Windows module deliberately: swdesk hands
# the desk to a machine and smin sets one monitor's input, so the same word means the same
# thing on both platforms.
#
# swmon is NOT an alias here. On Windows it is Switch-MonitorSetup, which toggles the
# desktop between multi-monitor and laptop-only - a different job entirely, and this Mac has
# no equivalent. It used to point at desk-monitor, which made "swmon list" look valid on
# Windows where it is not.
alias swdesk='desk-monitor'
alias smin='desk-monitor'
alias desk-mac='desk-monitor mac'
alias desk-pc='desk-monitor pc'
