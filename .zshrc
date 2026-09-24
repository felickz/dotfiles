# User-local tool installers may add environment setup here.
[ -r "$HOME/.local/bin/env" ] && . "$HOME/.local/bin/env"

export PATH="$HOME/.local/bin:$PATH"

# Monitor input switching. These names match the Windows module deliberately: swdesk hands
# the desk to a machine and smin sets one monitor's input, so the same word means the same
# thing on both platforms.
#
# Keep swmon as a macOS compatibility alias because it was the original published name.
# On Windows it still means Switch-MonitorSetup, so scripts shared across operating systems
# should prefer swdesk.
alias swdesk='desk-monitor'
alias swmon='desk-monitor'
alias smin='desk-monitor'
alias desk-mac='desk-monitor mac'
alias desk-pc='desk-monitor pc'
