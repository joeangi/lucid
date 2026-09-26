#!/usr/bin/env bash
# brightness.sh <brightnessctl options and operation>
#   e.g. brightness.sh -e4 -n2 set 5%+     brightness.sh set 40%
#
# brightnessctl writes /sys/class/backlight/*/brightness directly, which only
# the video group may do, and distro builds of it (Ubuntu's 0.5 among them)
# often lack its logind fallback. so a user outside video gets "Permission
# denied" and a dead slider. when that happens, brightnessctl --pretend still
# works out the target value, and logind's SetBrightness - open to the active
# session without any group - writes it instead

brightnessctl -q "$@" 2>/dev/null && exit 0

# device,class,raw,percent,max for the value brightnessctl would have set
IFS=, read -r dev class raw _ < <(brightnessctl -p -m "$@" 2>/dev/null) || exit 1
[[ -n "$dev" && "$raw" =~ ^[0-9]+$ ]] || exit 1

busctl call org.freedesktop.login1 /org/freedesktop/login1/session/auto \
    org.freedesktop.login1.Session SetBrightness ssu "$class" "$dev" "$raw"
