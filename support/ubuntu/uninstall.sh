#!/usr/bin/env bash
# Lucid uninstaller — puts the machine back the way install.sh found it.
#
# install.sh writes every change it makes to a manifest as it makes it
# (~/.local/state/lucid/manifest), with a copy of anything it replaced. this
# replays that manifest backwards: files Lucid created are removed, files it
# changed get their originals back, desktop settings return to what they were,
# and what it installed - apt packages and their dependencies, PPAs, Flatpaks,
# pipx, the builds in /usr/local - comes off again.
#
# the running shell keeps writing after install (the Environment page into gtk
# and qt settings, the Displays and Idle pages into ~/.config/hypr, matugen
# into kitty and starship), and install.sh captured those files up front, so
# they are put back too.
#
# nothing is lost on the way out: everything about to be removed or
# overwritten is archived first to ~/lucid-uninstall-<timestamp>.tar.gz.
#
# manifest records, one a line, tab separated:
#   lucid-install <version> <stamp>       header
#   created <path>                        did not exist: remove it
#   saved <path> <copy>                   existed: put <copy> back
#   moved <path> <aside>                  existed, was moved aside: move back
#   mkdir <dir>                           parent made on the way: drop if empty
#   keep <dir>                            a *-noshadow cursor theme not ours
#   gsetting <schema> <key> <value>       the value before install
#   unit <name> <is-enabled state>        a user unit's state before install
#   mask <unit>                           a unit install.sh masked
#   account <property> <value>            your AccountsService record
#   apt <package>                         installed by install.sh
#   ppa <ppa:owner/name>                  added by install.sh
#   usrlocal <file>                       a file a build put in /usr/local
#   root-created <dir>                    made outside $HOME with sudo
#   flatpak <app-id>                      installed from Flathub, per user
#   flatpak-remote <name>                 a remote install.sh added
#   pipx <package>                        installed with pipx
#   vscode-ext <extension> <cli...>       an editor extension it installed

set -euo pipefail
export LC_ALL=C
umask 077

SHELL_DIR="$HOME/.config/quickshell"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lucid"
MANIFEST="$STATE_DIR/manifest"
STAMP="$(date +%Y%m%d-%H%M%S-%N)"
ARCHIVE="$HOME/lucid-uninstall-$STAMP.tar.gz"

ASSUME_YES=0
KEEP_PACKAGES=0
NO_ARCHIVE=0
DELETE_APP_DATA=0

b=""; dim=""; red=""; grn=""; ylw=""; r=""
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]; then
    b=$'\e[1m'; dim=$'\e[2m'; red=$'\e[31m'; grn=$'\e[32m'
    ylw=$'\e[33m'; r=$'\e[0m'
fi
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s%s==>%s %s\n' "$b" "$grn" "$r" "$*"; }
warn() { printf '%s!%s %s\n' "$ylw" "$r" "$*" >&2; }
die()  { printf '%sx%s %s\n' "$red" "$r" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
${b}Lucid uninstaller${r}

  ./support/ubuntu/uninstall.sh [options]

  --keep-packages    put files and settings back, but leave every package,
                     PPA, Flatpak and /usr/local build installed
  --delete-app-data  also delete the dock apps' own data (~/.var/app/<id>):
                     browser profiles, logins, game saves
  --no-archive       don't archive what is removed to
                     ~/lucid-uninstall-<timestamp>.tar.gz first
  -y, --yes          don't prompt
  -h, --help         this message
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep-packages)   KEEP_PACKAGES=1 ;;
        --delete-app-data) DELETE_APP_DATA=1 ;;
        --no-archive)      NO_ARCHIVE=1 ;;
        -y|--yes)          ASSUME_YES=1 ;;
        -h|--help)         usage ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

[[ $EUID -ne 0 ]] || die "run this as yourself, not root — it restores files in your home directory"

ask() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply
    say "  ${b}[1] Uninstall and restore${r}"
    say "  [2] Cancel — leave everything unchanged"
    while true; do
        read -rp "$1 Choose 1 or 2 [2]: " reply || reply=2
        case "${reply,,}" in
            1|u|uninstall|y|yes) return 0 ;;
            ""|2|c|cancel|n|no) return 1 ;;
            *) say "  Please choose 1 (uninstall) or 2 (cancel)." ;;
        esac
    done
}

# only ever touch what is under $HOME, and never $HOME itself
home_path() {
    local p=$1 ancestor
    [[ -n "$p" && "$p" == "$HOME"/* && "$p" != *'/../'* && "$p" != */.. && "$p" != *'/./'* && "$p" != */. ]] || return 1
    # The leaf may be a symlink (remove/restore the link, never its target).
    ancestor=$(dirname "$p")
    while [[ "$ancestor" != "$HOME" && "$ancestor" != / ]]; do
        [[ ! -L "$ancestor" ]] || return 1
        ancestor=$(dirname "$ancestor")
    done
    [[ "$ancestor" == "$HOME" ]]
}

# ------------------------------------------------------------ no manifest

# an install from before the manifest existed. nothing says what it
# changed, so do the part that is unambiguously Lucid's and say the rest
if [[ ! -s "$MANIFEST" ]]; then
    warn "no install record at $MANIFEST"
    say  "  this install predates it, so only the parts that are unambiguously"
    say  "  Lucid's can be taken back. (re-running ./support/ubuntu/install.sh would not help: it"
    say  "  would record Lucid's own files as the originals to restore.)"
    say "No files or packages were removed. Restore an install manifest/backup to undo an older installation safely."
    exit 0
fi

ORIG_DIR="$STATE_DIR/originals"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/support/install-state.sh"
exec 9>"$STATE_DIR/lock"
flock -n 9 || die "another Lucid install/uninstall is running"
# Recover journal entries left by an interrupted dependency operation.
journal_packages
journal_flatpaks
finish_apt_sources
FAILED=0
failure() { FAILED=1; warn "$*"; }
restore_apt_marks() {
    [[ -f "$STATE_DIR/apt-manual-before-uninstall" ]] || return 0
    local package
    while IFS= read -r package; do
        grep -qxF "$package" "$STATE_DIR/apt-manual-before-uninstall" || continue
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -qE ' (installed|unpacked|half-installed|half-configured|triggers-awaited|triggers-pending|config-files)$'; then
            sudo apt-mark manual "$package" >/dev/null || return 1
        fi
    done < <(awk -F'\t' '$1 == "apt" {print $2}' "$MANIFEST")
}
finish_uninstall() {
    local rc=$?
    trap - EXIT
    restore_apt_marks || rc=1
    (( rc == 0 )) || warn "Uninstall incomplete; recovery state retained at $STATE_DIR"
    exit "$rc"
}
trap finish_uninstall EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
DONE_FILE="$STATE_DIR/uninstall-done"
completed() { grep -qxF "$1" "$DONE_FILE" 2>/dev/null; }
complete() { printf '%s\n' "$1" >> "$DONE_FILE"; }
root_path() {
    local p=$1 ancestor
    [[ "$p" != *'/../'* && "$p" != */.. && "$p" != *'/./'* && "$p" != */. ]] || return 1
    case "$p" in /usr/local/*/*|/usr/share/sddm/themes/lucid|/etc/apt/*) ;; *) return 1;; esac
    ancestor=$(dirname "$p")
    while [[ "$ancestor" != / ]]; do
        [[ ! -L "$ancestor" ]] || return 1
        ancestor=$(dirname "$ancestor")
    done
}

# ---------------------------------------------------------- read the record

RECS=()
while IFS= read -r line; do
    [[ -n "$line" ]] && RECS+=("$line")
done < "$MANIFEST"

field() { # field <record> <n>  (0-based)
    local IFS=$'\t' f
    read -r -a f <<< "$1"
    printf '%s' "${f[$2]:-}"
}
# everything after the first <n> fields, one per line
fields_from() {
    local IFS=$'\t' f
    read -r -a f <<< "$1"
    printf '%s\n' "${f[@]:$2}"
}

# the first record for a path describes the original; later ones are only
# Lucid replacing its own work
declare -A FIRST=()
ROOT_IDX=(); FLATPAK_REFS=(); FILE_IDX=(); APT=(); PPAS=(); USRLOCAL=(); ROOT_DIRS=(); FLATPAKS=(); REMOTES=()
DAEMONS=(); PIPX=(); VSCODE=(); GSET=(); UNITS=(); MASKS=(); ACCOUNT=()
declare -A KEEP=()
INSTALLED_VERSION=""
for i in "${!RECS[@]}"; do
    rec=${RECS[$i]}
    kind=$(field "$rec" 0)
    case "$kind" in
        created|saved|moved|mkdir)
            p=$(field "$rec" 1)
            if [[ -z "${FIRST[$p]:-}" ]]; then FIRST[$p]=$i; FILE_IDX+=("$i"); fi ;;
        keep)           KEEP[$(field "$rec" 1)]=1 ;;
        apt)            APT+=("$(field "$rec" 1)") ;;
        ppa)            PPAS+=("$(field "$rec" 1)") ;;
        usrlocal)       USRLOCAL+=("$(field "$rec" 1)") ;;
        root-created|root-saved|root-mkdir) ROOT_IDX+=("$i"); ROOT_DIRS+=("$(field "$rec" 1)") ;;
        ppa-tracked|runtime-baseline) : ;;
        flatpak-ref) FLATPAK_REFS+=("$(field "$rec" 1)") ;;
        flatpak)        FLATPAKS+=("$(field "$rec" 1)") ;;
        flatpak-remote) REMOTES+=("$(field "$rec" 1)") ;;
        pipx)           PIPX+=("$(field "$rec" 1)") ;;
        vscode-ext)     VSCODE+=("$i") ;;
        gsetting|gsetting-reset) GSET+=("$i") ;;
        daemon)         DAEMONS+=("$i") ;;
        unit)           UNITS+=("$i") ;;
        mask)           MASKS+=("$(field "$rec" 1)") ;;
        account)        ACCOUNT+=("$i") ;;
        lucid-install)  INSTALLED_VERSION=$(field "$rec" 1) ;;
        *)              failure "unknown record in the manifest, skipped: $kind" ;;
    esac
done

n_restore=0; n_remove=0
for i in "${FILE_IDX[@]}"; do
    case "$(field "${RECS[$i]}" 0)" in
        saved|moved) n_restore=$((n_restore + 1)) ;;
        created)     n_remove=$((n_remove + 1)) ;;
    esac
done
# cursor themes the Environment page rebuilt without their shadow
# New runtime assets are recorded individually; never infer ownership from a
# name suffix that could also belong to an independently installed theme.
NOSHADOW=()

# ------------------------------------------------------------------ plan

step "Lucid ${INSTALLED_VERSION:+$INSTALLED_VERSION }— what uninstalling puts back"
say "  files        $n_restore restored to how they were, $n_remove removed"
(( ${#NOSHADOW[@]} )) && say "               ${#NOSHADOW[@]} shadowless cursor theme(s) removed"
(( ${#ROOT_DIRS[@]} )) && say "               ${ROOT_DIRS[*]} (sudo)"
say "  settings     ${#GSET[@]} gsettings key(s), your account details, hypridle's autostart${MASKS[*]:+, unmasking ${MASKS[*]}}"
if (( KEEP_PACKAGES )); then
    say "  packages     ${dim}left installed (--keep-packages)${r}"
else
    (( ${#APT[@]} ))      && say "  apt          ${#APT[@]} package(s) Lucid installed, dependencies included"
    (( ${#PPAS[@]} ))     && say "  PPAs         ${PPAS[*]} (anything they upgraded goes back to Ubuntu's version)"
    (( ${#USRLOCAL[@]} )) && say "  /usr/local   ${#USRLOCAL[@]} file(s): quickshell, awww, matugen"
    (( ${#FLATPAKS[@]} )) && say "  flatpak      ${FLATPAKS[*]}$( (( DELETE_APP_DATA )) && echo ' — and their data')"
    (( ${#PIPX[@]} ))     && say "  pipx         ${PIPX[*]}"
    (( ${#VSCODE[@]} ))   && say "  editors      the Matugen theme extension"
fi
if (( NO_ARCHIVE )); then
    say "  ${ylw}no archive (--no-archive): what is removed is gone${r}"
else
    say "  ${dim}everything removed or overwritten is archived first to $ARCHIVE${r}"
fi
echo

ask "Uninstall Lucid and restore all of this?" || { say "Nothing changed."; exit 0; }
touch "$STATE_DIR/uninstall-started"

# ------------------------------------------------------------ stop Lucid

step "Stopping Lucid"
# only the instance running this config, never someone else's shell
if [[ -n "${FIRST[$SHELL_DIR]:-}" ]]; then
    qs kill -p "$SHELL_DIR" 2>/dev/null || true
    for i in "${DAEMONS[@]}"; do
        daemon=$(field "${RECS[$i]}" 1); was=$(field "${RECS[$i]}" 2)
        if [[ "$was" == inactive && ( "$daemon" == awww-daemon || "$daemon" == swww-daemon ) ]]; then
            pkill -u "$(id -u)" -x "$daemon" 2>/dev/null || true
        fi
    done
fi
say "  stopped"

# ------------------------------------------------------------- archive

if (( ! NO_ARCHIVE )); then
    step "Archiving what is about to change"
    list=$(mktemp)
    for i in "${FILE_IDX[@]}"; do
        [[ "$(field "${RECS[$i]}" 0)" == mkdir ]] && continue
        completed "file:$i" && continue
        p=$(field "${RECS[$i]}" 1)
        home_path "$p" && [[ -e "$p" || -L "$p" ]] && printf '%s\0' "${p#/}" >> "$list"
        # a config moved aside is moved back over what is there now
        if [[ "$(field "${RECS[$i]}" 0)" == moved ]]; then
            a=$(field "${RECS[$i]}" 2)
            home_path "$a" && [[ -e "$a" ]] && printf '%s\0' "${a#/}" >> "$list"
        fi
    done
    for d in "${NOSHADOW[@]}"; do printf '%s\0' "${d#/}" >> "$list"; done
    printf '%s\0' "${STATE_DIR#/}" >> "$list"
    if (( DELETE_APP_DATA && ! KEEP_PACKAGES )); then
        for a in "${FLATPAKS[@]}"; do
            p="$HOME/.var/app/$a"
            home_path "$p" && [[ -e "$p" ]] && printf '%s\0' "${p#/}" >> "$list"
        done
    fi
    tar_cmd=(tar)
    if (( ${#ROOT_IDX[@]} || ${#USRLOCAL[@]} )); then
        tar_cmd=(sudo tar)
        for i in "${ROOT_IDX[@]}"; do
            [[ "$(field "${RECS[$i]}" 0)" == root-mkdir ]] && continue
            p=$(field "${RECS[$i]}" 1)
            root_path "$p" && [[ -e "$p" || -L "$p" ]] && printf '%s\0' "${p#/}" >> "$list"
        done
        for p in "${USRLOCAL[@]}"; do
            root_path "$p" && [[ -e "$p" || -L "$p" ]] && printf '%s\0' "${p#/}" >> "$list"
        done
    fi
    if "${tar_cmd[@]}" -C / -cf - --null -T "$list" | gzip > "$ARCHIVE"; then
        say "  $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
    else
        rm -f "$list"
        die "could not write $ARCHIVE — stopped before changing anything (--no-archive skips it)"
    fi
    rm -f "$list"
fi

# --------------------------------------------------------------- files

step "Restoring files"

# newest first, so a file comes back before the directory around it
for (( k = ${#FILE_IDX[@]} - 1; k >= 0; k-- )); do
    i=${FILE_IDX[$k]}
    completed "file:$i" && continue
    rec=${RECS[$i]}
    kind=$(field "$rec" 0); p=$(field "$rec" 1); src=$(field "$rec" 2)
    if ! home_path "$p"; then
        warn "  refusing to touch $p — not under $HOME"; FAILED=1; continue
    fi
    case "$kind" in
        created)
            rm -rf -- "$p" ;;
        saved)
            [[ "$src" == "$ORIG_DIR/"* ]] && home_path "$src" || { failure "invalid saved original: $src"; continue; }
            if [[ -e "$src" || -L "$src" ]]; then
                rm -rf -- "$p"
                mkdir -p "$(dirname "$p")"
                cp -a -- "$src" "$p"
            else
                failure "  the saved original of $p is missing — left as it is"
                continue
            fi ;;
        moved)
            home_path "$src" || { failure "invalid backup: $src"; continue; }
            if [[ -e "$src" || -L "$src" ]]; then
                rm -rf -- "$p"
                cp -a -- "$src" "$p"
            else
                failure "  $src is gone; leaving $p and the recovery record intact"
                continue
            fi ;;
        mkdir)
            # only if empty: you may have put your own things in it since
            rmdir -- "$p" 2>/dev/null || true ;;
    esac
    complete "file:$i"
done
say "  file restoration pass complete"

for d in "${NOSHADOW[@]}"; do rm -rf -- "$d"; done
(( ${#NOSHADOW[@]} )) && say "  removed ${#NOSHADOW[@]} shadowless cursor theme(s)"

# fonts and icons Lucid added or took away need their caches told
command -v fc-cache &>/dev/null && fc-cache -f >/dev/null 2>&1 || true

# ------------------------------------------------------------- settings

step "Restoring settings"

if command -v gsettings &>/dev/null; then
    for i in "${GSET[@]}"; do
        completed "setting:$i" && continue
        rec=${RECS[$i]}
        schema=$(field "$rec" 1); key=$(field "$rec" 2); val=$(field "$rec" 3)
        gs_args=(set "$schema" "$key" "$val")
        [[ "$(field "$rec" 0)" != gsetting-reset ]] || gs_args=(reset "$schema" "$key")
        if gsettings "${gs_args[@]}" 2>/dev/null; then complete "setting:$i"
        else failure "  could not restore $schema $key to $val"; fi
    done
    (( ${#GSET[@]} )) && say "  gsettings restoration attempted"
elif (( ${#GSET[@]} )); then
    failure "gsettings unavailable; settings retained for retry"
fi

systemctl --user daemon-reload >/dev/null 2>&1 || true
for unit in "${MASKS[@]}"; do
    completed "mask:$unit" && continue
    if systemctl --user unmask "$unit" &>/dev/null; then complete "mask:$unit"
    else failure "could not unmask $unit"; fi
done
for i in "${UNITS[@]}"; do
    completed "unit:$i" && continue
    unit=$(field "${RECS[$i]}" 1); was=$(field "${RECS[$i]}" 2)
    active=$(field "${RECS[$i]}" 3)
    case "$was" in
        enabled) action=enable ;; enabled-runtime) action=enable ;;
        masked) action=mask ;; masked-runtime) action=mask ;;
        disabled|not-found|'') action=disable ;; *) action="" ;;
    esac
    unit_args=(--user)
    [[ "$was" != *-runtime ]] || unit_args+=(--runtime)
    if [[ -n "$action" ]] && ! systemctl "${unit_args[@]}" "$action" "$unit" &>/dev/null; then
        if [[ "$(systemctl --user is-enabled "$unit" 2>/dev/null || true)" != not-found ]]; then
            failure "could not restore $unit to $was"; continue
        fi
    fi
    if [[ "$active" == active ]]; then
        systemctl --user start "$unit" &>/dev/null || { failure "could not restart $unit"; continue; }
    elif [[ "$active" == inactive || "$active" == failed ]]; then
        # An absent unit is already stopped.
        current=$(systemctl --user is-active "$unit" 2>/dev/null || true)
        if [[ "$current" == active ]]; then systemctl --user stop "$unit" &>/dev/null || { failure "could not stop $unit"; continue; }; fi
    fi
    complete "unit:$i"
done

# your AccountsService record. what you may change about yourself is put back;
# the rest needs an administrator, so it is only reported
acct() { busctl call org.freedesktop.Accounts "/org/freedesktop/Accounts/User$(id -u)" \
             org.freedesktop.Accounts.User "$@" >/dev/null 2>&1; }
acct_get() {
    busctl -j get-property org.freedesktop.Accounts "/org/freedesktop/Accounts/User$(id -u)" \
        org.freedesktop.Accounts.User "$1" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"])' 2>/dev/null
}
ACCT_NOTES=()
if (( ${#ACCOUNT[@]} )) && command -v busctl &>/dev/null; then
    for i in "${ACCOUNT[@]}"; do
        prop=$(field "${RECS[$i]}" 1); was=$(field "${RECS[$i]}" 2)
        completed "account:$i" && continue
        if ! now=$(acct_get "$prop"); then failure "cannot read account property $prop"; continue; fi
        case "$prop" in
            RealName|Email|Location)
                [[ "$now" == "$was" ]] && continue
                if acct "Set$prop" s "$was"; then say "  account: $prop restored"
                else FAILED=1; ACCT_NOTES+=("$prop was \"$was\" — change it back in your desktop's account settings"); fi ;;
            IconFile)
                copy=$(field "${RECS[$i]}" 3)
                if [[ "$was" == none || "$was" != /var/lib/AccountsService/* ]]; then
                    # no stored picture before, only the fallback: anything
                    # stored since is the Users page's, and comes off
                    [[ "$now" == "$was" || ( "$was" == none && -z "$now" ) ]] && continue
                    [[ "$now" == /var/lib/AccountsService/* ]] || continue
                    if acct SetIconFile s ""; then
                        say "  account: picture set on the Users page removed"
                        [[ "$was" != none ]] && ACCT_NOTES+=("your picture falls back to $was again once accounts-daemon reloads (next boot, or: sudo systemctl restart accounts-daemon)")
                    else
                        FAILED=1; ACCT_NOTES+=("your account picture could not be reset — the Users page's is still set")
                    fi
                elif [[ -n "$copy" && -f "$copy" ]]; then
                    # a stored picture before: put it back only if it changed
                    [[ -n "$now" && -f "$now" ]] && cmp -s "$now" "$copy" && continue
                    if acct SetIconFile s "$copy"; then
                        say "  account: picture restored"
                    else
                        FAILED=1; ACCT_NOTES+=("your account picture could not be restored — the old one is in $ARCHIVE")
                    fi
                fi ;;
            *)
                [[ "$now" == "$was" ]] && continue
                ACCT_NOTES+=("$prop is now \"$now\", was \"$was\" — needs an administrator to change back") ;;
        esac
        (( FAILED )) || complete "account:$i"
    done
elif (( ${#ACCOUNT[@]} )); then
    failure "busctl unavailable; account restoration pending"
fi

# ------------------------------------------------------------- packages

if (( ! KEEP_PACKAGES )); then
    step "Removing what Lucid installed"

    for i in "${VSCODE[@]}"; do
        mapfile -t w < <(fields_from "${RECS[$i]}" 1)
        ext=${w[0]}; cli=("${w[@]:1}")
        completed "extension:$i" && continue
        if ! command -v "${cli[0]}" &>/dev/null; then failure "missing editor command ${cli[0]} to remove $ext"; continue; fi
        if "${cli[@]}" --uninstall-extension "$ext" &>/dev/null; then complete "extension:$i"
        else failure "could not remove $ext from ${cli[*]}"; fi
    done

    if (( ${#FLATPAKS[@]} || ${#FLATPAK_REFS[@]} || ${#REMOTES[@]} )) && ! command -v flatpak &>/dev/null; then
        failure "flatpak is unavailable; cannot verify/remove recorded apps, runtimes and remotes"
    elif (( ${#FLATPAKS[@]} || ${#FLATPAK_REFS[@]} || ${#REMOTES[@]} )); then
        fp_args=(--user -y --noninteractive)
        (( DELETE_APP_DATA )) && fp_args+=(--delete-data)
        for a in "${FLATPAKS[@]}"; do
            if (( DELETE_APP_DATA )); then
                data="$HOME/.var/app/$a"
                home_path "$data" || { failure "invalid Flatpak data path"; continue; }
                rm -rf -- "$data"
            fi
            flatpak info --user "$a" &>/dev/null || continue
            if flatpak uninstall "${fp_args[@]}" "$a" >/dev/null 2>&1; then
                say "  flatpak: removed $a"
            else
                failure "  could not remove $a — flatpak uninstall --user $a"
            fi
        done
        for ref in "${FLATPAK_REFS[@]}"; do
            flatpak info --user "$ref" &>/dev/null || continue
            flatpak uninstall --user -y --noninteractive "$ref" >/dev/null 2>&1 || failure "could not remove tracked Flatpak ref $ref (may be in use)"
        done
        (( DELETE_APP_DATA )) || say "  ${dim}their data is kept in ~/.var/app (--delete-app-data removes it)${r}"
        for rm_remote in "${REMOTES[@]}"; do
            # only when nothing else still comes from it
            if flatpak list --user --columns=origin 2>/dev/null | grep -qx "$rm_remote"; then
                failure "keeping the $rm_remote remote — other apps use it"
            else
                if flatpak remotes --user --columns=name | grep -qxF "$rm_remote"; then
                    flatpak remote-delete --user "$rm_remote" >/dev/null 2>&1 || failure "could not remove $rm_remote"
                fi
            fi
        done
    fi

    for pkg in "${PIPX[@]}"; do
        completed "pipx:$pkg" && continue
        if command -v pipx &>/dev/null && pipx list --short > "$STATE_DIR/pipx-list" 2>/dev/null && ! grep -q "^$pkg " "$STATE_DIR/pipx-list"; then complete "pipx:$pkg"; continue; fi
        if command -v pipx &>/dev/null && pipx uninstall "$pkg" >/dev/null 2>&1; then complete "pipx:$pkg"
        else failure "could not remove pipx package $pkg"; fi
    done

    if (( ${#USRLOCAL[@]} )); then
        dirs=()
        for f in "${USRLOCAL[@]}"; do
            root_path "$f" || { failure "  refusing to remove $f"; continue; }
            sudo rm -f -- "$f"
            dirs+=("$(dirname "$f")")
        done
        # directories a build made below /usr/local/<x>, once they are empty.
        # /usr/local/bin and its siblings stay whatever happens
        printf '%s\n' "${dirs[@]}" | sort -ru | while IFS= read -r d; do
            while [[ "$d" == /usr/local/*/* ]]; do
                sudo rmdir -- "$d" 2>/dev/null || break
                d=$(dirname "$d")
            done
        done
        say "  /usr/local: removed ${#USRLOCAL[@]} file(s) (quickshell, awww, matugen)"
    fi

    if (( ${#APT[@]} )); then
        present=()
        for p in "${APT[@]}"; do
            dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -qE ' (installed|unpacked|half-installed|half-configured|triggers-awaited|triggers-pending|config-files)$' && present+=("$p")
        done
        if (( ${#present[@]} )); then
            # Temporarily mark only our additions automatic, then purge only the
            # intersection of apt's unused set and our journal. No global autoremove.
            marks="$STATE_DIR/apt-manual-before-uninstall"
            [[ -f "$marks" ]] || apt-mark showmanual > "$marks"
            sudo apt-mark auto "${present[@]}" >/dev/null
            plan=$(apt-get -s autoremove) || die "APT simulation failed; state retained"
            unused=$(awk '/^Remv /{print $2}' <<< "$plan")
            remove=()
            for p in "${present[@]}"; do
                if grep -qxF "$p" <<< "$unused" || dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q ' config-files$'; then
                    remove+=("$p")
                fi
            done
            if (( ${#remove[@]} )); then
                plan=$(apt-get -s purge "${remove[@]}") || die "APT purge simulation failed"
                safe=1
                while IFS= read -r p; do
                    [[ -z "$p" ]] && continue
                    printf '%s\n' "${APT[@]}" | grep -qxF "$p" || safe=0
                done < <(awk '/^(Remv|Purg) /{print $2}' <<< "$plan")
                if (( safe )); then
                    sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${remove[@]}" || failure "APT removal failed"
                else failure "APT would remove unrelated packages; skipped"; fi
            fi
            for p in "${present[@]}"; do
                if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -qE ' (installed|unpacked|half-installed|half-configured|triggers-awaited|triggers-pending|config-files)$'; then
                    grep -qxF "$p" "$marks" && sudo apt-mark manual "$p" >/dev/null
                    warn "keeping $p: still needed by another package"
                fi
            done
        fi
    fi

    if (( ${#PPAS[@]} )); then
        for ppa in "${PPAS[@]}"; do
            failure "legacy PPA record $ppa lacks original source/package snapshots. Restore this repository and any upgraded packages manually before discarding the recovery record."
        done
    fi

fi

# Restore system files only after package removal; this includes exact source
# and signing-key files changed by add-apt-repository, and pre-existing builds.
for (( k=${#ROOT_IDX[@]}-1; k>=0; k-- )); do
    i=${ROOT_IDX[$k]}
    completed "root:$i" && continue
    rec=${RECS[$i]}; kind=$(field "$rec" 0); p=$(field "$rec" 1); src=$(field "$rec" 2)
    if (( KEEP_PACKAGES )) && [[ "$p" != /usr/share/sddm/themes/lucid ]]; then continue; fi
    root_path "$p" || { failure "refusing system path $p"; continue; }
    if [[ "$kind" == root-mkdir ]]; then
        sudo rmdir -- "$p" 2>/dev/null || true
        complete "root:$i"; continue
    fi
    if [[ -d "$p" && ! -L "$p" && "$p" != /usr/share/sddm/themes/lucid ]]; then
        failure "refusing recursive removal of system directory $p"; continue
    fi
    if [[ "$p" == /usr/share/sddm/themes/lucid && "$kind" == root-created ]]; then
        if grep -qsE '^[[:space:]]*Current[[:space:]]*=[[:space:]]*lucid[[:space:]]*$' /etc/sddm.conf /etc/sddm.conf.d/*.conf; then
            failure "SDDM still selects Lucid. Select your previous greeter theme in /etc/sddm.conf or /etc/sddm.conf.d, then retry."; continue
        fi
    fi
    if [[ "$kind" == root-saved ]]; then
        [[ "$src" == "$ORIG_DIR/root/"* && ( -e "$src" || -L "$src" ) ]] || { failure "missing original for $p"; continue; }
        sudo rm -rf -- "$p"
        sudo install -d -m755 "$(dirname "$p")"
        sudo cp -a -- "$src" "$p"
    else
        sudo rm -rf -- "$p"
    fi
    complete "root:$i"
done

if (( ! KEEP_PACKAGES )); then
    sources_changed=0
    for p in "${ROOT_DIRS[@]}"; do [[ "$p" != /etc/apt/* ]] || sources_changed=1; done
    if (( sources_changed )); then
        sudo apt-get update -qq || failure "APT sources were restored, but refreshing package indexes failed; fix connectivity/repository errors and retry"
    fi
fi

# --------------------------------------------------------------- done

step "Result"
if (( FAILED )); then
    warn "Uninstall incomplete. Recovery state is retained at $STATE_DIR. Fix the reported errors and rerun ./support/ubuntu/uninstall.sh."
elif (( KEEP_PACKAGES )); then
    say "  Files/settings restored; package recovery records retained at $STATE_DIR."
    say "  Run ./support/ubuntu/uninstall.sh without --keep-packages later to finish removal."
else
    for i in "${FILE_IDX[@]}"; do
        [[ "$(field "${RECS[$i]}" 0)" == moved ]] || continue
        src=$(field "${RECS[$i]}" 2)
        home_path "$src" && rm -rf -- "$src"
    done
    sudo_needed=0
    (( ${#ROOT_IDX[@]} )) && sudo_needed=1
    if (( sudo_needed )); then sudo rm -rf -- "$STATE_DIR"; else rm -rf -- "$STATE_DIR"; fi
    for (( k=${#FILE_IDX[@]}-1; k>=0; k-- )); do
        rec=${RECS[${FILE_IDX[$k]}]}
        [[ "$(field "$rec" 0)" == mkdir ]] || continue
        p=$(field "$rec" 1)
        home_path "$p" && rmdir -- "$p" 2>/dev/null || true
    done
    say "  Recorded Lucid changes have been removed/restored."
fi
(( NO_ARCHIVE )) || say "  everything it removed or overwrote: ${b}$ARCHIVE${r}"
say ""
say "  Not undone — no install record can bring these back:"
say "    · a password changed on the Users page"
say "    · accounts added or deleted on the Users page"
for n in "${ACCT_NOTES[@]}"; do say "    · $n"; done
(( KEEP_PACKAGES )) && say "    · packages, PPAs, Flatpaks and /usr/local builds (--keep-packages)"
say ""
say "  Log out and pick your previous session on the login screen."

if (( FAILED )); then exit 1; fi
