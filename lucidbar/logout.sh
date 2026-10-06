#!/bin/sh
# End only this graphical login session.
#
# Ask Hyprland to exit first. A display manager such as SDDM waits for the
# compositor to return, then shows its greeter again. `loginctl
# terminate-session` would also kill the display manager's session helper,
# which leads the logind session. SDDM treats that as a crash, does not restart
# the greeter, and leaves a black screen.
if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && command -v hyprctl >/dev/null 2>&1; then
    # Lua configs take a dispatcher call; hyprlang configs take its name.
    hyprctl dispatch 'hl.dsp.exit()' >/dev/null 2>&1 && exit 0
    hyprctl dispatch exit >/dev/null 2>&1 && exit 0
fi

# Without a running Hyprland, fall back to logind.
if [ -n "${XDG_SESSION_ID:-}" ] && command -v loginctl >/dev/null 2>&1; then
    exec loginctl terminate-session "$XDG_SESSION_ID"
fi

exec hyprctl dispatch 'hl.dsp.exit()'
