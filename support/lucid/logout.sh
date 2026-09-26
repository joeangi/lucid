#!/bin/sh
# End only this graphical login session. This also works when Hyprland was
# started by a display manager rather than uwsm.
if [ -n "${XDG_SESSION_ID:-}" ] && command -v loginctl >/dev/null 2>&1; then
    loginctl terminate-session "$XDG_SESSION_ID" && exit 0
fi

# A compositor launched without a logind session can still exit itself.
exec hyprctl dispatch exit
