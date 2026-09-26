#!/usr/bin/env bash
# Lucid installer — Ubuntu, Arch Linux, and Fedora + Hyprland
#
# installs dependencies, places the shell at ~/.config/quickshell, and sets up
# the full bundle: the Hyprland config (binds, window rules, blur, autostart),
# the theming layer, the Lucid look, and the apps the dock ships pinned.
# safe to re-run: existing config and personal state are backed up, never
# overwritten in place.
#
# dependencies come in two tiers. essential is what Lucid needs to be a working
# desktop at all and is always offered. optional is grouped by feature, each
# group taken or left on its own - see --list-optional.

set -euo pipefail
export LC_ALL=C
umask 077

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Keep the existing Arch/Fedora package flow separate from Ubuntu's journaled
# APT flow. Sourcing os-release in a subshell avoids replacing Lucid's VERSION.
OS_ID=$([[ -r /etc/os-release ]] && . /etc/os-release; printf '%s' "${ID:-}")
if [[ "$OS_ID" == fedora || -f /etc/arch-release ]]; then
    exec "$SRC/support/install-arch-fedora.sh" "$@"
fi
# the VERSION file ships inside the shell tree, so the installed copy can tell
# the update check which version it is. bump it to cut a release
VERSION="unknown"
if [[ -f "$SRC/VERSION" ]]; then
    VERSION="$(tr -d '[:space:]' < "$SRC/VERSION")"
fi
SHELL_DIR="$HOME/.config/quickshell"
LUCID_DIR="$HOME/.config/lucid"
MATUGEN_DIR="$HOME/.config/matugen"
WALL_SCRIPT_DIR="$HOME/.config/hypr/scripts/wallpaper"
STAMP="$(date +%Y%m%d-%H%M%S-%N)"
BACKUP=""

WITH_THEMING=1
WITH_LOOK=1
WITH_HYPR=1
WITH_APPS=1
WITH_WALLPAPERS=1
HYPR_FORCE=0
HYPR_LUA_INSTALLED=0
ASSUME_YES=0
ALLOW_THIRD_PARTY=0
CHECK_ONLY=0
TEMP_DIRS=()
SKIP_DEPS=0
# empty: ask per group. otherwise a comma list, "all" or "none"
OPTIONAL_ARG=""
LIST_OPTIONAL=0

b=""; dim=""; red=""; grn=""; ylw=""; cyn=""; r=""
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != dumb ]]; then
    b=$'\e[1m'; dim=$'\e[2m'; red=$'\e[31m'; grn=$'\e[32m'
    ylw=$'\e[33m'; cyn=$'\e[36m'; r=$'\e[0m'
fi
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s%s==>%s %s\n' "$b" "$grn" "$r" "$*"; }
warn() { printf '%s!%s %s\n' "$ylw" "$r" "$*" >&2; }
die()  { printf '%sx%s %s\n' "$red" "$r" "$*" >&2; exit 1; }

# ------------------------------------------------------------ what to install

# essential, from Ubuntu's archive. without any of these the shell does not
# start, or starts visibly broken: no wallpaper, no palette, dead panels
ESSENTIAL_APT=(
    # the compositor. Lucid's config is lua, which needs Hyprland 0.55+ -
    # newer than Ubuntu ships, so the resolver below reaches for a PPA
    hyprland xdg-desktop-portal-hyprland
    # the qt runtime quickshell loads the shell against. Ubuntu splits every
    # qml module into its own package, and a missing one is a shell that
    # refuses to load rather than a feature that goes quiet
    qt6-wayland qt6-svg-plugins qt6-image-formats-plugins
    qml6-module-qtqml qml6-module-qtqml-models qml6-module-qtqml-workerscript
    qml6-module-qtquick qml6-module-qtquick-shapes qml6-module-qtquick-effects
    qml6-module-qtquick-controls qml6-module-qtquick-templates
    qml6-module-qtquick-layouts qml6-module-qtquick-window
    qml6-module-qt5compat-graphicaleffects qml6-module-qtmultimedia
    # the palette and wallpaper pipeline, weather, the update check, and
    # importing a theme from a git repo
    jq curl git python3
    # the system services the bar and its panels drive
    network-manager bluez pipewire pipewire-pulse wireplumber pulseaudio-utils
    upower brightnessctl
    # the shell is the session's own polkit agent; polkitd and its setuid
    # helper are the backend it drives
    polkitd pkexec
    libnotify-bin xdg-utils wl-clipboard gsettings-desktop-schemas
    fonts-noto-color-emoji
)
# the apps Lucid's binds launch. only wanted with the Hyprland config: without
# them it installs fine but F9, SUPER+E, F12 and the media keys do nothing
ESSENTIAL_BINDS=(kitty nautilus playerctl gnome-calculator)

# essential, but not in Ubuntu's archive at all, so built or fetched from
# upstream and installed to /usr/local. pinned, so a re-run is repeatable. a
# tag can be moved upstream, so each build also checks the commit it expects
# and each download its sha256 - a mismatch is a failed install, never a guess
QS_TAG=v0.3.1
QS_COMMIT=1a4716cde794a59928d9d9fc15f2afc7a95de360
QS_REPOS=(https://git.outfoxxed.me/quickshell/quickshell.git
          https://github.com/quickshell-mirror/quickshell.git)
QS_BUILD_DEPS=(
    build-essential cmake ninja-build pkg-config git spirv-tools
    qt6-base-dev qt6-base-private-dev qt6-declarative-dev qt6-declarative-private-dev
    qt6-shadertools-dev qt6-wayland-dev qt6-wayland-private-dev qt6-svg-dev
    libcli11-dev libjemalloc-dev libwayland-dev libwayland-bin wayland-protocols
    libdrm-dev libgbm-dev libegl-dev libvulkan-dev libpipewire-0.3-dev libpam0g-dev
    libpolkit-agent-1-dev libpolkit-gobject-1-dev libglib2.0-dev libxcb1-dev
)
AWWW_TAG=v0.12.1
AWWW_COMMIT=f66e12a76dbc4c669b2f1375f78bce49f5b19d66
AWWW_REPO=https://codeberg.org/LGFae/awww.git
AWWW_BUILD_DEPS=(cargo rustc pkg-config git libwayland-dev wayland-protocols liblz4-dev)
MATUGEN_TAG=v4.2.0
# matugen-4.2.0-x86_64.tar.gz. the cargo fallback needs no sum: a crates.io
# version can never be replaced once published
MATUGEN_SHA256=a2e3b50e49ed6439999ba3c252ed04fabd98ee4e9d12e5e5dff2e66370569751

# the optional downloads, pinned the same way
NERDFONT_TAG=v3.5.1
NERDFONT_SHA256=04d5e8f903693f9dd13e16f867e994834e681eb3c72c0d337a770dcda09010cf
ADW_TAG=v6.5
ADW_SHA256=a81780fadfc432be0fc3d89c4ebb41aa28e4f032d42c36f9789c57dd10cfa41c
FAIRYWREN_REPO=https://gitlab.com/FreshDoctor/FairyWren-Icons.git
FAIRYWREN_COMMIT=ba2ff9d8ddb3a9cae7466a59e0227bb7947b9175
# the original pywal has had no release since 2019; pywal16 is its maintained
# fork and installs the same `wal` command
PYWAL_PKG=pywal16
PYWAL_VERSION=3.8.15

HYPR_MIN=0.55
HYPR_PPA=ppa:cppiber/hyprland

# optional, one group per feature. a group left out costs only its feature,
# and the shell says so wherever that feature shows
OPT_ORDER=(capture clipboard media system phone pywal look apps)
declare -A OPT_DESC=(
    [capture]="screenshots, screen recording, OCR and the colour picker"
    [clipboard]="clipboard history, and typing emoji and GIFs into windows"
    [media]="audio visualisers and song identification"
    [system]="idle dim/lock/suspend, the Users page, Qt theming, the file picker"
    [phone]="KDE Connect: your phone's notifications, media and files"
    [pywal]="the Pywal theme"
    [look]="fish, the starship prompt, a nerd font, adw-gtk3 and icons"
    [apps]="the dock's default apps: Zen, VSCodium, Spotify, Vesktop, Steam, Proton VPN"
)
declare -A OPT_APT=(
    [capture]="grim swappy wf-recorder ffmpeg imagemagick hyprpicker
               tesseract-ocr tesseract-ocr-eng python3-pil python3-numpy python3-fonttools"
    [clipboard]="cliphist wtype"
    # songrec is not in the archive; its author's PPA carries it
    [media]="cava songrec"
    # librsvg2-bin re-renders a cursor theme when its shadow is turned off
    [system]="hypridle accountsservice gir1.2-accountsservice-1.0 python3-gi
              qt6ct xdg-desktop-portal-gtk librsvg2-bin zenity"
    [phone]="kdeconnect python3-gi"
    # pywal16 is not packaged; pipx installs it. wal extracts with imagemagick
    [pywal]="pipx imagemagick"
    # the nerd font and adw-gtk3 are not packaged either - fetched below
    [look]="fish starship fonts-jetbrains-mono papirus-icon-theme xz-utils fontconfig"
    [apps]="flatpak"
)
# what the pipx / download / flatpak side of a group adds, for the summary
declare -A OPT_EXTRA=(
    [media]="songrec from ppa:marin-m/songrec"
    [pywal]="pywal16 $PYWAL_VERSION (PyPI, via pipx)"
    [look]="JetBrainsMono Nerd Font $NERDFONT_TAG, adw-gtk3 $ADW_TAG (GitHub releases), FairyWren icons (GitLab)"
    [apps]="6 Flatpaks from Flathub, several GB"
)
SONGREC_PPA=ppa:marin-m/songrec

# the dock's default pins, from Flathub: one source for all six, installed
# per-user so none of it needs root. order matches the dock
FLATPAK_APPS=(
    app.zen_browser.zen com.vscodium.codium dev.vencord.Vesktop
    com.spotify.Client com.protonvpn.www com.valvesoftware.Steam
)
# an app already there some other way - deb, snap, a vendor repo - counts
declare -A APP_ALTS=(
    [app.zen_browser.zen]="zen zen-browser"
    [com.vscodium.codium]="codium"
    [dev.vencord.Vesktop]="vesktop discord"
    [com.spotify.Client]="spotify"
    [com.protonvpn.www]="protonvpn-app"
    [com.valvesoftware.Steam]="steam"
)
# said in each app's consent prompt: two of the six are not free software
declare -A APP_LICENSE=(
    [app.zen_browser.zen]="open source (MPL-2.0)"
    [com.vscodium.codium]="open source (MIT)"
    [dev.vencord.Vesktop]="open source (GPL-3.0); connects to Discord, a proprietary service"
    [com.spotify.Client]="proprietary; Flathub repackages Spotify's own build"
    [com.protonvpn.www]="open source (GPL-3.0)"
    [com.valvesoftware.Steam]="proprietary; Flathub repackages Valve's own client"
)
# a package already covered by an equivalent one the user chose themselves
declare -A PKG_ALTS=(
    [xdg-desktop-portal-gtk]="xdg-desktop-portal-gnome xdg-desktop-portal-kde"
    [imagemagick]="imagemagick-7.q16 imagemagick-6.q16"
)

usage() {
    cat <<EOF
${b}Lucid $VERSION installer${r}

  ./install.sh [options]

  --minimal      install only the essential dependencies; skip every
                 optional group
  --optional=LIST
                 optional groups to install, comma separated, or
                 "all" / "none". without it you are asked per group
  --list-optional
                 describe the optional groups and exit
  --no-theming   skip the palette layer; leave ~/.config/lucid
                 and ~/.config/matugen untouched
  --no-look      don't touch kitty.conf, starship.toml or VSCode
                 settings (and drops the "look" group)
  --no-hypr      keep your Hyprland config; Lucid's binds, window
                 rules and blur are not installed
  --no-apps      don't install the apps pinned to the dock by
                 default (drops the "apps" group)
  --no-wallpapers
                 don't copy the bundled wallpapers to
                 ~/Pictures/wallpapers
  --with-hypr    reinstall Lucid's Hyprland config even when one
                 is already in place
  --skip-deps    don't install packages, only check for them
  --check        read-only Ubuntu/runtime compatibility check
  --allow-third-party
                 explicitly consent to the listed external sources in
                 unattended mode (only for selected features)
  -y, --yes      accept configuration prompts; optional groups default
                 to none. Use --optional=LIST to select them explicitly
  -h, --help     this message
EOF
    exit 0
}

list_optional() {
    printf '%sessential%s  always offered\n' "$b" "$r"
    printf '  apt:    %s\n' "${ESSENTIAL_APT[*]}" | fold -s -w 78 | sed '2,$s/^/          /'
    printf '  binds:  %s  (with the Hyprland config)\n' "${ESSENTIAL_BINDS[*]}"
    printf '  built:  quickshell %s, awww %s, matugen %s -> /usr/local\n\n' "$QS_TAG" "$AWWW_TAG" "$MATUGEN_TAG"
    printf '%soptional%s   --optional=%s\n' "$b" "$r" "$(IFS=,; echo "${OPT_ORDER[*]}")"
    local g
    for g in "${OPT_ORDER[@]}"; do
        printf '  %-10s %s\n' "$g" "${OPT_DESC[$g]}"
        printf '             %sapt: %s%s\n' "$dim" "$(echo ${OPT_APT[$g]})" "$r"
        [[ -n "${OPT_EXTRA[$g]:-}" ]] && printf '             %s+ %s%s\n' "$dim" "${OPT_EXTRA[$g]}" "$r"
    done
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --minimal)    OPTIONAL_ARG=none ;;
        --optional=*) OPTIONAL_ARG="${1#--optional=}" ;;
        --optional)   shift; OPTIONAL_ARG="${1:-}" ;;
        --list-optional) LIST_OPTIONAL=1 ;;
        --no-theming) WITH_THEMING=0 ;;
        --no-look)    WITH_LOOK=0 ;;
        --no-hypr)    WITH_HYPR=0 ;;
        --no-apps)    WITH_APPS=0 ;;
        --no-wallpapers) WITH_WALLPAPERS=0 ;;
        --with-hypr)  WITH_HYPR=1; HYPR_FORCE=1 ;;
        --skip-deps)  SKIP_DEPS=1 ;;
        --check) CHECK_ONLY=1 ;;
        --allow-third-party) ALLOW_THIRD_PARTY=1 ;;
        -y|--yes)     ASSUME_YES=1 ;;
        -h|--help)    usage ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

[[ $LIST_OPTIONAL -eq 1 ]] && list_optional

say "${b}${cyn}Lucid $VERSION${r}  ${dim}Ubuntu installer${r}"
say "${dim}A reversible install with explicit dependency choices${r}"

# ask <question> [y|n]: a bare Enter takes the default, which is no unless a
# caller says otherwise - nothing that changes the system happens by accident
ask() {
    [[ $ASSUME_YES -eq 1 ]] && return 0
    local reply default=${2:-n} hint="[y/N]"
    [[ "$default" == y ]] && hint="[Y/n]"
    read -rp "$1 $hint " reply || return 1
    [[ -n "$reply" ]] || reply=$default
    [[ "$reply" =~ ^[Yy] ]]
}

# Third-party software is always a separate, explicit decision. Selecting an
# optional feature does not silently consent to its external repository or
# download, and --yes is not source consent.
declare -a SKIPPED_CAPABILITIES=()
software_consent() {
    local name=$1 reason=$2 source=$3 dest=$4 requirement=$5 impact=$6 reply
    say ""
    say "  ${b}${ylw}THIRD-PARTY DEPENDENCY${r}  $name"
    say "  ${dim}------------------------------------------------------------${r}"
    say "  Needed for       $reason"
    say "  Requirement      $requirement"
    say "  Source           $source"
    say "  Installs to      $dest"
    say "  If you skip      $impact"
    say ""
    say "  ${b}[1] Install $name${r}"
    say "  [2] Skip — $impact"
    if (( SKIP_DEPS )); then
        say "  ${dim}Choice: skip (--skip-deps)${r}"
        SKIPPED_CAPABILITIES+=("$name: $impact")
        return 1
    fi
    if (( ASSUME_YES )); then
        if (( ALLOW_THIRD_PARTY )); then
            say "  ${grn}Choice: install (--allow-third-party)${r}"
            return 0
        fi
        say "  ${dim}Choice: skip (use --allow-third-party for unattended consent)${r}"
        SKIPPED_CAPABILITIES+=("$name: $impact")
        return 1
    fi
    while true; do
        read -rp "  Choose 1 or 2 [2]: " reply || reply=2
        case "${reply,,}" in
            1|i|install|y|yes) say "  ${grn}Choice: install${r}"; return 0 ;;
            ""|2|s|skip|n|no)
                say "  ${dim}Choice: skip${r}"
                SKIPPED_CAPABILITIES+=("$name: $impact")
                return 1 ;;
            *) say "  Please choose 1 (install) or 2 (skip)." ;;
        esac
    done
}

# ------------------------------------------------------------- the manifest

# every change is written down as it is made, so uninstall.sh can put the
# machine back exactly as it was. originals are copied into the state dir;
# the first record for a path is the one that describes the original, so a
# re-run never buries what the first install found. one tab-separated record
# a line - uninstall.sh documents the kinds it replays.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/lucid"
MANIFEST="$STATE_DIR/manifest"
ORIG_DIR="$STATE_DIR/originals"
declare -A TRACKED=()
source "$SRC/support/install-state.sh"

# track <path>: call before creating or changing a file or directory. an
# existing one is copied aside whole; a missing one is recorded as created,
# with each missing parent recorded as a directory to drop once it is empty
track() {
    local p=$1
    [[ "$p" != *$'\t'* && "$p" != *$'\n'* ]] || die "unsupported control character in path"
    # Writes through symlinked configs cannot be restored by backing up the link.
    local ancestor=$p
    while [[ "$ancestor" != "$HOME" && "$ancestor" != / ]]; do
        [[ ! -L "$ancestor" ]] || die "symlinked install path: $ancestor; use a regular config directory"
        ancestor=$(dirname "$ancestor")
    done
    [[ -n "${TRACKED[$p]:-}" ]] && return 0
    TRACKED[$p]=1
    path_known "$p" && return 0
    if [[ -e "$p" || -L "$p" ]]; then
        local copy="$ORIG_DIR$p"
        mkdir -p "$(dirname "$copy")"
        rm -rf "$copy"
        cp -a "$p" "$copy"
        record saved "$p" "$copy"
    else
        local parents=() d
        d=$(dirname "$p")
        while [[ ! -e "$d" && "$d" != / ]]; do parents=("$d" "${parents[@]}"); d=$(dirname "$d"); done
        for d in "${parents[@]}"; do
            TRACKED[$d]=1
            path_known "$d" || record mkdir "$d"
        done
        record created "$p"
    fi
}
# the whole installed package set, for telling what an apt run added


# ---------------------------------------------------------------- preflight

step "Checking the system"

[[ -r /etc/os-release ]] || die "no /etc/os-release - can't tell which distro this is"
# read in a subshell: os-release sets VERSION, which would clobber Lucid's own
OS_ID=$(. /etc/os-release; echo "${ID:-}")
OS_LIKE=$(. /etc/os-release; echo "${ID_LIKE:-}")
OS_NAME=$(. /etc/os-release; echo "${PRETTY_NAME:-$ID}")
OS_VER=$(. /etc/os-release; echo "${VERSION_ID:-}")
# a derivative (Mint, Pop!_OS, ...) names the Ubuntu base it builds on here,
# and that base is what the PPAs are published for
OS_CODENAME=$(. /etc/os-release; echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")

if [[ "$OS_ID" != ubuntu && " $OS_LIKE " != *" ubuntu "* ]]; then
    die "this installer is for Ubuntu and its derivatives (found: $OS_NAME). see the README for a manual install."
fi
command -v apt-get &>/dev/null || die "apt-get not found"
command -v dpkg &>/dev/null    || die "dpkg not found"
[[ $EUID -ne 0 ]] || die "don't run this as root — it installs into your home directory"
[[ -f "$SRC/shell.qml" ]] || die "run this from inside the Lucid repo (no shell.qml next to install.sh)"

# older releases carry a Qt too old for quickshell's private-API build, and
# the Hyprland PPA is not published for them
# Check the actual Qt candidate, including derivatives, before writing state.
qt_candidate=$(apt-cache policy qt6-base-dev | awk '/Candidate:/{c=$2} END {print c}')
if [[ -z "$qt_candidate" || "$qt_candidate" == '(none)' ]] || ! dpkg --compare-versions "$qt_candidate" ge 6.6; then
    die "$OS_NAME supplies Qt ${qt_candidate:-unknown}; Quickshell $QS_TAG needs Qt >= 6.6. Stock Ubuntu 24.04 is unsupported. Use Ubuntu 26.04 with current package indexes."
fi
[[ "$OS_CODENAME" == resolute ]] || warn "$OS_NAME has not been validated; checking available packages instead of assuming compatibility"
[[ "$SRC" != "$SHELL_DIR" && "$SRC" != "$SHELL_DIR/"* ]] || die "run from a separate checkout, not the installed shell directory"
if (( CHECK_ONLY )); then
    missing=()
    policies=$(apt-cache policy "${ESSENTIAL_APT[@]}")
    for p in "${ESSENTIAL_APT[@]}"; do
        [[ "$p" == hyprland ]] && continue
        c=$(awk -v package="$p:" '$0 == package {wanted=1; next} wanted && /Candidate:/ {c=$2; wanted=0} END {print c}' <<< "$policies")
        [[ -n "$c" && "$c" != '(none)' ]] || missing+=("$p")
    done
    say "Ubuntu base: $OS_CODENAME; Qt candidate: $qt_candidate"
    say "Hyprland >= $HYPR_MIN, qs, awww/swww and matugen must be available before deployment."
    for cmd in Hyprland qs matugen; do command -v "$cmd" || missing+=("$cmd (runtime)"); done
    command -v awww || command -v swww || missing+=("awww/swww (runtime)")
    hv=$(Hyprland --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    [[ -n "$hv" ]] && dpkg --compare-versions "$hv" ge "$HYPR_MIN" || missing+=("Hyprland >= $HYPR_MIN")
    (( ${#missing[@]} == 0 )) || die "missing/unavailable: ${missing[*]}"
    say "Compatibility checks passed; graphical session still needs testing."
    exit 0
fi
[[ ! -f "$STATE_DIR/uninstall-started" ]] || die "uninstall is pending; finish ./uninstall.sh before reinstalling"
[[ "$STATE_DIR" == "$HOME/"* && "$STATE_DIR" != *'/../'* && "$STATE_DIR" != *'/./'* ]] || die "XDG_STATE_HOME must be inside HOME for reversible installation"
for managed in "$SHELL_DIR" "$LUCID_DIR" "$MATUGEN_DIR" "$HOME/.config/hypr" "$HOME/.cache/quickshell"; do
    [[ "$STATE_DIR" != "$managed" && "$STATE_DIR" != "$managed/"* ]] || die "state directory overlaps managed config: $STATE_DIR"
done
state_parents=()
d=$(dirname "$STATE_DIR")
while [[ ! -e "$d" && "$d" != "$HOME" ]]; do state_parents=("$d" "${state_parents[@]}"); d=$(dirname "$d"); done
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
flock -n 9 || die "another Lucid install/uninstall is running"

say "  distro          $OS_NAME ${grn}ok${r}"
say "  install target  $SHELL_DIR"
say "  theming layer   $([[ $WITH_THEMING -eq 1 ]] && echo yes || echo 'no (--no-theming)')"
say "  hyprland config $([[ $WITH_HYPR   -eq 1 ]] && echo yes || echo 'no (--no-hypr)')"
say "  wallpapers      $([[ $WITH_WALLPAPERS -eq 1 ]] && echo yes || echo 'no (--no-wallpapers)')"

FIRST_RUN=1; [[ -s "$MANIFEST" ]] && FIRST_RUN=0
[[ -s "$MANIFEST" ]] || record lucid-install "$VERSION" "$STAMP"
for d in "${state_parents[@]}"; do path_known "$d" || record mkdir "$d"; done

# ------------------------------------------------------------- dependencies

# true when the package, or anything standing in for it, is installed
have_deb() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
}
have_pkg() {
    have_deb "$1" && return 0
    local alt
    for alt in ${PKG_ALTS[$1]:-}; do
        have_deb "$alt" && return 0
    done
    return 1
}
# the version apt would install, empty when no configured source has it
apt_candidate() {
    local c
    c=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{c=$2} END {print c}')
    [[ "$c" == "(none)" ]] && c=""
    printf '%s' "$c"
}
ppa_added() {
    # ppa:owner/name lands as a sources entry naming ppa.launchpadcontent.net/owner/name
    local path=${1#ppa:}
    grep -rqsF "$path" /etc/apt/sources.list /etc/apt/sources.list.d/
}
# the Origin launchpad signs a PPA's Release file with: LP-PPA-owner-name,
# or LP-PPA-owner for a PPA named "ppa". apt -s prints it for every package
ppa_origin() {
    local path=${1#ppa:}
    local owner=${path%%/*} name=${path#*/}
    if [[ "$name" == ppa ]]; then printf 'LP-PPA-%s' "$owner"
    else printf 'LP-PPA-%s-%s' "$owner" "$name"; fi
}
# apt origins the user has agreed to in this run, so a consented PPA does not
# ask again for each library it brings along
declare -A APPROVED_ORIGINS=()
# Ubuntu's archive, whichever mirror serves it - the Release file carries the
# origin, not the hostname. on a derivative, its own archive is the OS itself
trusted_origin() {
    local o=${1,,}
    [[ "$o" == ubuntu* ]] && return 0
    [[ -n "${APPROVED_ORIGINS[$1]:-}" ]] && return 0
    [[ "$OS_ID" != ubuntu && -n "$OS_ID" && "$o" == "${OS_ID,,}"* ]]
}
PPA_NOTE="the PPA stays enabled, so apt upgrade keeps taking updates from it - for these and any other package it publishes - until ./uninstall.sh removes it"
# Hyprland's own idea of its version: whichever binary is on PATH wins,
# whether it came from apt or a source build
hypr_version() {
    command -v Hyprland &>/dev/null || return 0
    Hyprland --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}
qt_version() {
    dpkg-query -W -f='${Version}' libqt6core6t64 2>/dev/null \
        || dpkg-query -W -f='${Version}' libqt6core6 2>/dev/null || true
}
# quickshell uses private Qt API, so a build is tied to the exact Qt it was
# compiled against - a Qt upgrade without a rebuild crashes on start. the
# stamp records both, so a re-run rebuilds exactly when one has moved
QS_STAMP="$LUCID_DIR/quickshell-build"
qs_wanted_stamp() { printf '%s qt=%s\n' "$QS_TAG" "$(qt_version)"; }
qs_needs_build() {
    if ! command -v qs &>/dev/null; then return 0; fi
    # a quickshell we did not build is the user's; leave it be
    [[ -f "$QS_STAMP" ]] || return 1
    [[ "$(cat "$QS_STAMP")" != "$(qs_wanted_stamp)" ]]
}
have_app() {
    local alt
    flatpak info "$1" &>/dev/null && return 0
    for alt in ${APP_ALTS[$1]:-}; do
        command -v "$alt" &>/dev/null && return 0
    done
    return 1
}

DEPS_OK=1
fail() { DEPS_OK=0; warn "$*"; }

# ---- which optional groups

declare -A WANT=()
if [[ -n "$OPTIONAL_ARG" ]]; then
    case "$OPTIONAL_ARG" in
        all)  for g in "${OPT_ORDER[@]}"; do WANT[$g]=1; done ;;
        none) ;;
        *)
            IFS=, read -ra picked <<< "$OPTIONAL_ARG"
            for g in "${picked[@]}"; do
                [[ -n "${OPT_DESC[$g]:-}" ]] || die "unknown optional group: $g (try --list-optional)"
                WANT[$g]=1
            done ;;
    esac
fi
# the older flags still mean what they did
[[ $WITH_APPS -eq 0 ]] && unset 'WANT[apps]'
[[ $WITH_LOOK -eq 0 ]] && unset 'WANT[look]'

step "Choosing optional features"

if [[ -n "$OPTIONAL_ARG" ]]; then
    :
elif [[ $ASSUME_YES -eq 1 ]]; then
    say "  optional software skipped; select explicitly with --optional=LIST"
else
    say "  essential dependencies are always offered. each of these is extra —"
    say "  leave one out and only its feature goes missing. (--list-optional"
    say "  shows exactly what each pulls in)"
    for g in "${OPT_ORDER[@]}"; do
        [[ "$g" == apps && $WITH_APPS -eq 0 ]] && continue
        [[ "$g" == look && $WITH_LOOK -eq 0 ]] && continue
        say "  $g (optional): ${OPT_DESC[$g]}"
        say "    APT packages: ${OPT_APT[$g]}"
        say "    Source: configured Ubuntu/APT repositories; destination: system package paths"
        [[ -z "${OPT_EXTRA[$g]:-}" ]] || say "    External extras (separate consent): ${OPT_EXTRA[$g]}"
        say "    [1] Install this feature group"
        say "    [2] Skip — ${OPT_DESC[$g]} will be unavailable"
        while true; do
            reply=""
            read -rp "    Choose 1 or 2 [2]: " reply || reply=2
            case "${reply,,}" in
                1|i|install|y|yes) WANT[$g]=1; break ;;
                ""|2|s|skip|n|no) break ;;
                *) say "    Please choose 1 (install) or 2 (skip)." ;;
            esac
        done
    done
fi
chosen=()
for g in "${OPT_ORDER[@]}"; do [[ -n "${WANT[$g]:-}" ]] && chosen+=("$g"); done
say "  optional groups: ${chosen[*]:-none}"

# ---- what is missing

step "Resolving dependencies"

ess_missing=()
for p in "${ESSENTIAL_APT[@]}"; do
    [[ "$p" == hyprland ]] && continue    # judged by version, below
    have_pkg "$p" || ess_missing+=("$p")
done
if [[ $WITH_HYPR -eq 1 ]]; then
    for p in "${ESSENTIAL_BINDS[@]}"; do have_pkg "$p" || ess_missing+=("$p"); done
fi

# Hyprland: installed and new enough is all that matters, however it got here
NEED_HYPR=0; NEED_HYPR_PPA=0
HV=$(hypr_version)
if [[ -z "$HV" ]] || dpkg --compare-versions "$HV" lt "$HYPR_MIN"; then
    NEED_HYPR=1
    ess_missing+=(hyprland)
    cand=$(apt_candidate hyprland); cand=${cand%%[+~-]*}
    if ! ppa_added "$HYPR_PPA" && { [[ -z "$cand" ]] || dpkg --compare-versions "$cand" lt "$HYPR_MIN"; }; then
        NEED_HYPR_PPA=1
    fi
fi

NEED_QS=0;      qs_needs_build && NEED_QS=1
NEED_MATUGEN=0; command -v matugen &>/dev/null || NEED_MATUGEN=1
NEED_AWWW=0;    command -v awww &>/dev/null || command -v swww &>/dev/null || NEED_AWWW=1

if (( NEED_HYPR_PPA )); then
    software_consent Hyprland "Lucid's Lua compositor configuration (version >= $HYPR_MIN)" "$HYPR_PPA (Launchpad, Ubuntu base $OS_CODENAME)" "system APT packages and repository configuration; $PPA_NOTE" "required compositor" "Lucid cannot be deployed; install a compatible Hyprland another way, then retry" \
        || die "Hyprland source skipped. Install a compatible Hyprland yourself, then retry."
    APPROVED_ORIGINS[$(ppa_origin "$HYPR_PPA")]=1
fi
if (( NEED_QS )); then
    software_consent Quickshell "running the Lucid QML desktop" "${QS_REPOS[*]} tag $QS_TAG (commit ${QS_COMMIT:0:12})" /usr/local "required" "Lucid cannot start" \
        || die "Quickshell skipped; cannot deploy a working shell."
fi
if (( NEED_AWWW )); then
    software_consent awww "wallpaper selection (an existing swww also works)" "$AWWW_REPO tag $AWWW_TAG (commit ${AWWW_COMMIT:0:12}); Cargo dependencies from crates.io, locked" /usr/local/bin "required wallpaper backend" "wallpaper selection will not work and Lucid will not be deployed" \
        || die "wallpaper backend skipped; install awww or swww and retry."
fi
if (( NEED_MATUGEN )); then
    software_consent matugen "generating the desktop colour palette from a wallpaper" "https://github.com/InioX/matugen $MATUGEN_TAG release (sha256-checked); fallback crates.io" /usr/local/bin "required palette generator" "wallpaper-derived colours will not work and Lucid will not be deployed" \
        || die "matugen skipped; install it yourself and retry."
fi

build_deps=()
if (( NEED_QS ));   then for p in "${QS_BUILD_DEPS[@]}";   do have_pkg "$p" || build_deps+=("$p"); done; fi
if (( NEED_AWWW )); then for p in "${AWWW_BUILD_DEPS[@]}"; do have_pkg "$p" || build_deps+=("$p"); done; fi
# the matugen release is x86_64 only; anything else builds it with cargo
if (( NEED_MATUGEN )) && [[ "$(uname -m)" != x86_64 ]]; then
    for p in cargo rustc; do have_pkg "$p" || build_deps+=("$p"); done
fi
# one package can be wanted by both builds
mapfile -t build_deps < <(printf '%s\n' "${build_deps[@]}" | awk 'NF && !seen[$0]++')

declare -A OPT_MISSING=()
opt_total=0
for g in "${chosen[@]}"; do
    miss=()
    for p in ${OPT_APT[$g]}; do have_pkg "$p" || miss+=("$p"); done
    OPT_MISSING[$g]="${miss[*]}"
    opt_total=$(( opt_total + ${#miss[@]} ))
done
NEED_SONGREC_PPA=0
if [[ -n "${WANT[media]:-}" ]] && ! have_pkg songrec && ! ppa_added "$SONGREC_PPA" \
   && [[ -z "$(apt_candidate songrec)" ]]; then
    NEED_SONGREC_PPA=1
fi

# the extras outside apt: pipx, downloads and flatpaks
NEED_PYWAL=0; [[ -n "${WANT[pywal]:-}" ]] && ! command -v wal &>/dev/null && NEED_PYWAL=1
NEED_NERDFONT=0
if [[ -n "${WANT[look]:-}" ]] && ! fc-list 2>/dev/null | grep -qi 'JetBrainsMono Nerd Font'; then
    NEED_NERDFONT=1
fi
ADW_DIRS=(/usr/share/themes "$HOME/.themes" "$HOME/.local/share/themes")
NEED_ADW=0
if [[ -n "${WANT[look]:-}" ]]; then
    NEED_ADW=1
    for d in "${ADW_DIRS[@]}"; do [[ -d "$d/adw-gtk3-dark" ]] && NEED_ADW=0; done
fi
apps_missing=()
if [[ -n "${WANT[apps]:-}" ]]; then
    for a in "${FLATPAK_APPS[@]}"; do have_app "$a" || apps_missing+=("$a"); done
fi

if (( NEED_SONGREC_PPA )) && ! software_consent SongRec "song identification in the media panel" "$SONGREC_PPA (Launchpad)" "system APT packages; $PPA_NOTE" "optional part of media" "song identification will be unavailable; audio visualisers will still work"; then
    NEED_SONGREC_PPA=0
    OPT_MISSING[media]=" ${OPT_MISSING[media]} "
    OPT_MISSING[media]=${OPT_MISSING[media]// songrec / }
elif (( NEED_SONGREC_PPA )); then
    APPROVED_ORIGINS[$(ppa_origin "$SONGREC_PPA")]=1
fi
if (( NEED_PYWAL )) && ! software_consent pywal "the Pywal theme" "$PYWAL_PKG $PYWAL_VERSION from PyPI, via pipx" "user pipx environment and ~/.local/bin/wal" "optional part of pywal" "the Pywal theme will be unavailable; the other themes will still work"; then NEED_PYWAL=0; fi
if (( NEED_NERDFONT )) && ! software_consent "JetBrainsMono Nerd Font" "icons in the Lucid terminal prompt" "https://github.com/ryanoasis/nerd-fonts release $NERDFONT_TAG (sha256-checked)" "~/.local/share/fonts/JetBrainsMonoNerd" "optional part of look" "the terminal prompt may show empty boxes instead of icons"; then NEED_NERDFONT=0; fi
if (( NEED_ADW )) && ! software_consent adw-gtk3 "matching GTK application styling" "https://github.com/lassekongo83/adw-gtk3 release $ADW_TAG (sha256-checked)" "~/.local/share/themes" "optional part of look" "GTK apps will keep their current theme; the rest of the Lucid look will still work"; then NEED_ADW=0; fi
approved_apps=()
for a in "${apps_missing[@]}"; do
    software_consent "$a" "the matching default dock shortcut. licence: ${APP_LICENSE[$a]:-see its Flathub page}" "https://flathub.org via https://dl.flathub.org/repo/flathub.flatpakrepo" "per-user Flatpak installation (~/.local/share/flatpak)" "optional dock app" "this app will not be installed or pinned; Lucid and your existing apps will still work" && approved_apps+=("$a")
done
apps_missing=("${approved_apps[@]}")

nothing_to_do=1
(( ${#ess_missing[@]} || ${#build_deps[@]} || NEED_QS || NEED_MATUGEN || NEED_AWWW )) && nothing_to_do=0
(( opt_total || NEED_PYWAL || NEED_NERDFONT || NEED_ADW || ${#apps_missing[@]} )) && nothing_to_do=0

# add-apt-repository is not on every Ubuntu flavour; installed first when a PPA is
NEED_SPC=0
if (( NEED_HYPR_PPA || NEED_SONGREC_PPA )) && ! command -v add-apt-repository &>/dev/null; then
    NEED_SPC=1
    nothing_to_do=0
fi

report_plan() {
    say "  ${b}essential${r}"
    (( ${#ess_missing[@]} )) && say "    apt:    ${ess_missing[*]}"
    (( NEED_HYPR_PPA ))      && say "    ppa:    $HYPR_PPA ${dim}(Ubuntu's Hyprland is older than the $HYPR_MIN the lua config needs)${r}"
    (( NEED_SPC ))           && say "    apt:    software-properties-common ${dim}(provides add-apt-repository, to add the PPA)${r}"
    (( NEED_HYPR )) && [[ -n "$HV" ]] && say "    ${dim}Hyprland $HV is installed, older than $HYPR_MIN${r}"
    (( NEED_QS ))       && say "    build:  quickshell $QS_TAG ${dim}(not in Ubuntu's archive)${r}"
    (( NEED_AWWW ))     && say "    build:  awww $AWWW_TAG ${dim}(the wallpaper daemon)${r}"
    (( NEED_MATUGEN ))  && say "    fetch:  matugen $MATUGEN_TAG ${dim}(the palette generator)${r}"
    (( ${#build_deps[@]} )) && say "    ${dim}build tools: ${build_deps[*]}${r}" \
        && say "    ${dim}(the build tools stay installed afterwards, for rebuilds after a Qt update; ./uninstall.sh removes them)${r}"
    (( ${#ess_missing[@]} || NEED_QS || NEED_AWWW || NEED_MATUGEN )) || say "    ${dim}all present${r}"
    (( ${#chosen[@]} )) || return 0
    say "  ${b}optional${r}"
    local g
    for g in "${chosen[@]}"; do
        local extra=""
        case "$g" in
            media) (( NEED_SONGREC_PPA )) && extra="+ $SONGREC_PPA" ;;
            pywal) (( NEED_PYWAL )) && extra="+ $PYWAL_PKG $PYWAL_VERSION (pipx)" ;;
            look)  (( NEED_NERDFONT )) && extra+="+ JetBrainsMono Nerd Font "
                   (( NEED_ADW ))      && extra+="+ adw-gtk3" ;;
            apps)  (( ${#apps_missing[@]} )) && extra="+ flathub: ${apps_missing[*]}" ;;
        esac
        if [[ -z "${OPT_MISSING[$g]}" && -z "$extra" ]]; then
            say "    ${dim}$g: all present${r}"
        else
            say "    $g: ${OPT_MISSING[$g]} ${dim}$extra${r}"
        fi
    done
    (( ${#apps_missing[@]} )) && say "    ${dim}(the dock apps are several GB — pass --no-apps to skip them)${r}"
    return 0
}

# --- the installers for everything apt does not carry

# clone a pinned tag from the first mirror that answers, and only accept it
# when the tag still points at the commit it was pinned to
clone_tag() {
    local tag=$1 commit=$2 dest=$3; shift 3
    local url head
    for url in "$@"; do
        if git clone -q --depth 1 --branch "$tag" "$url" "$dest" 2>/dev/null; then
            head=$(git -C "$dest" rev-parse HEAD 2>/dev/null || true)
            [[ "$head" == "$commit" ]] && return 0
            warn "  $url: tag $tag is now ${head:-unreadable}, expected $commit - not using it"
        fi
        rm -rf "$dest"
    done
    return 1
}

# fetch_verified <url> <sha256> <file>: download over https and keep the file
# only when its checksum is the pinned one
fetch_verified() {
    local url=$1 sum=$2 out=$3
    curl -fsSL --proto '=https' --tlsv1.2 "$url" -o "$out" || return 1
    if ! printf '%s  %s\n' "$sum" "$out" | sha256sum -c --status -; then
        warn "  checksum mismatch for $url - discarded"
        rm -f "$out"
        return 1
    fi
}

build_quickshell() {
    track "$LUCID_DIR"
    say "  building quickshell $QS_TAG (a few minutes)"
    local tmp; tmp=$(mktemp -d); TEMP_DIRS+=("$tmp")
    # the crash handler needs cpptrace, which Ubuntu does not package
    if clone_tag "$QS_TAG" "$QS_COMMIT" "$tmp/qs" "${QS_REPOS[@]}" \
       && cmake -S "$tmp/qs" -B "$tmp/qs/build" -G Ninja \
            -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr/local \
            -DCRASH_HANDLER=OFF -DDISTRIBUTOR="Lucid installer (Ubuntu)" >"$tmp/log" 2>&1 \
       && cmake --build "$tmp/qs/build" >>"$tmp/log" 2>&1 \
       && (umask 022 && DESTDIR="$tmp/stage" cmake --install "$tmp/qs/build") >>"$tmp/log" 2>&1 \
       && install_staged "$tmp/stage"; then
        mkdir -p "$LUCID_DIR"
        qs_wanted_stamp > "$QS_STAMP"
        say "  quickshell -> /usr/local/bin/qs"
    else
        mkdir -p "$LUCID_DIR"; cp "$tmp/log" "$LUCID_DIR/quickshell-build.log" 2>/dev/null || true
        fail "quickshell failed to build — the shell cannot start without it. log: $LUCID_DIR/quickshell-build.log"
    fi
    rm -rf "$tmp"
}

build_awww() {
    track "$LUCID_DIR"
    say "  building awww $AWWW_TAG"
    local tmp; tmp=$(mktemp -d); TEMP_DIRS+=("$tmp")
    if clone_tag "$AWWW_TAG" "$AWWW_COMMIT" "$tmp/awww" "$AWWW_REPO" \
       && (cd "$tmp/awww" && CARGO_HOME="$tmp/cargo" cargo build --release --locked -q) >"$tmp/log" 2>&1 \
       && install_root_file "$tmp/awww/target/release/awww" /usr/local/bin/awww \
       && install_root_file "$tmp/awww/target/release/awww-daemon" /usr/local/bin/awww-daemon; then
        say "  awww, awww-daemon -> /usr/local/bin"
    else
        mkdir -p "$LUCID_DIR"; cp "$tmp/log" "$LUCID_DIR/awww-build.log" 2>/dev/null || true
        fail "awww failed to build — setting a wallpaper will fail. log: $LUCID_DIR/awww-build.log"
    fi
    rm -rf "$tmp"
}

install_matugen() {
    local tmp; tmp=$(mktemp -d); TEMP_DIRS+=("$tmp")
    local ver=${MATUGEN_TAG#v}
    if [[ "$(uname -m)" == x86_64 ]]; then
        say "  fetching matugen $MATUGEN_TAG"
        if fetch_verified "https://github.com/InioX/matugen/releases/download/$MATUGEN_TAG/matugen-$ver-x86_64.tar.gz" \
               "$MATUGEN_SHA256" "$tmp/matugen.tar.gz" \
           && tar -xzf "$tmp/matugen.tar.gz" -C "$tmp" \
           && install_root_file "$tmp/matugen" /usr/local/bin/matugen; then
            say "  matugen -> /usr/local/bin/matugen"
            rm -rf "$tmp"; return 0
        fi
        warn "  the release download failed, building it with cargo instead"
    fi
    if command -v cargo &>/dev/null \
       && CARGO_HOME="$tmp/cargo" cargo install -q --locked --version "$ver" --root "$tmp/root" matugen >/dev/null 2>&1 \
       && install_root_file "$tmp/root/bin/matugen" /usr/local/bin/matugen; then
        say "  matugen -> /usr/local/bin/matugen"
    else
        fail "could not install matugen — wallpaper-derived colours will not work"
    fi
    rm -rf "$tmp"
}

install_pywal() {
    # pipx lands it in ~/.local/bin, which Ubuntu's ~/.profile puts on PATH
    # at login - so the session finds it even if this terminal does not yet
    pipx list --short 2>/dev/null | grep -qE '^pywal(16)? ' && return 0
    record_once pipx "$PYWAL_PKG"
    if pipx install "$PYWAL_PKG==$PYWAL_VERSION" >/dev/null 2>&1; then
        record_once pipx "$PYWAL_PKG"
    fi
    if pipx list --short 2>/dev/null | grep -q "^$PYWAL_PKG "; then
        say "  pywal -> ~/.local/bin/wal"
        [[ ":$PATH:" == *":$HOME/.local/bin:"* ]] \
            || say "  ${dim}~/.local/bin joins your PATH at your next login${r}"
    else
        fail "could not install pywal with pipx — the Pywal theme will not work"
    fi
}

install_nerdfont() {
    local dest="$HOME/.local/share/fonts/JetBrainsMonoNerd" tmp
    tmp=$(mktemp -d); TEMP_DIRS+=("$tmp")
    say "  fetching JetBrainsMono Nerd Font $NERDFONT_TAG"
    track "$dest"
    mkdir -p "$dest"
    if fetch_verified "https://github.com/ryanoasis/nerd-fonts/releases/download/$NERDFONT_TAG/JetBrainsMono.tar.xz" \
           "$NERDFONT_SHA256" "$tmp/font.tar.xz" \
       && tar -xJf "$tmp/font.tar.xz" -C "$dest"; then
        fc-cache -f "$dest" >/dev/null 2>&1 || true
        say "  JetBrainsMono Nerd Font -> $dest"
    else
        rmdir "$dest" 2>/dev/null || true
        fail "could not fetch JetBrainsMono Nerd Font — the prompt will show boxes"
    fi
}

install_adw_gtk3() {
    local dest="$HOME/.local/share/themes" tmp
    tmp=$(mktemp -d); TEMP_DIRS+=("$tmp")
    track "$dest/adw-gtk3"
    track "$dest/adw-gtk3-dark"
    mkdir -p "$dest"
    if fetch_verified "https://github.com/lassekongo83/adw-gtk3/releases/download/$ADW_TAG/adw-gtk3$ADW_TAG.tar.xz" \
           "$ADW_SHA256" "$tmp/adw.tar.xz" \
       && tar -xJf "$tmp/adw.tar.xz" -C "$tmp" \
       && [[ -d "$tmp/adw-gtk3" && -d "$tmp/adw-gtk3-dark" ]] \
       && cp -a "$tmp/adw-gtk3" "$tmp/adw-gtk3-dark" "$dest/"; then
        say "  adw-gtk3 -> $dest"
    else
        fail "could not fetch adw-gtk3 — GTK apps keep their stock theme"
    fi
}

install_flatpaks() {
    local had_remote=0 before remote_url
    before=$(flatpak list --user --columns=ref 2>/dev/null | sort)
    printf '%s\n' "$before" > "$STATE_DIR/flatpak-before"
    flatpak remotes --user --columns=name 2>/dev/null | grep -qx flathub && had_remote=1
    if (( had_remote )); then
        remote_url=$(flatpak remotes --user --columns=name,url | awk '$1 == "flathub" {print $2}')
        [[ "$remote_url" == https://dl.flathub.org/repo/ || "$remote_url" == https://dl.flathub.org/repo ]] || { fail "existing flathub remote has unexpected URL: $remote_url"; return 0; }
    else
        record_once flatpak-remote flathub
    fi
    flatpak remote-add --user --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 \
        || { fail "could not add Flathub — the dock apps were not installed"; return 0; }
    (( had_remote )) || record_once flatpak-remote flathub
    local a
    # one at a time: a single failure shouldn't take the rest with it
    for a in "${apps_missing[@]}"; do
        record_once flatpak "$a"
        say "  flatpak: $a"
        if flatpak install --user -y --noninteractive flathub "$a" >/dev/null 2>&1; then
            record_once flatpak "$a"
        else
            fail "could not install $a from Flathub"
        fi
    done
    journal_flatpaks

}

finish_install() {
    local rc=$?
    trap - EXIT
    journal_packages || rc=1
    journal_flatpaks || rc=1
    finish_apt_sources || rc=1
    local temp
    for temp in "${TEMP_DIRS[@]}"; do rm -rf -- "$temp"; done
    if (( rc )); then warn "Install incomplete. Recovery state is at $STATE_DIR; ./uninstall.sh can undo recorded changes."; fi
    exit "$rc"
}
trap finish_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ ! -d "$STATE_DIR/apt-source-snapshot" ]] || die "previous source operation was interrupted; run uninstall.sh before reinstalling"

apt_install() {
    local label=$1; shift
    local p pkgs=()
    for p in "$@"; do
        if [[ -n "$(apt_candidate "$p")" ]]; then
            pkgs+=("$p")
        else
            fail "  $p is not in your apt sources — skipping it"
        fi
    done
    (( ${#pkgs[@]} )) || return 0
    # Existing packages must not be upgraded/downgraded or removed:
    # their old versions might no longer be downloadable at uninstall.
    local plan
    plan=$(apt-get -s --no-remove install "${pkgs[@]}") || { fail "cannot resolve $label"; return 0; }
    if grep -Eq '^Remv |^Inst [^ ]+ \[' <<< "$plan"; then
        fail "$label would replace existing system packages; update those separately, then retry. No package changes made for this batch."
        return 0
    fi
    # every package the plan installs, dependencies included, grouped by the
    # origin of the version apt picked: "Inst pkg (ver Origin:rel/suite[, ...] [arch])"
    local line pkg origins o prior_status
    local -A foreign=()
    local re='^Inst ([^ ]+) \(([^ ]+) (.*) \[[^]]*\]\)'
    while IFS= read -r line; do
        [[ "$line" == Inst\ * ]] || continue
        pkg=${line#Inst }; pkg=${pkg%% *}
        prior_status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
        if [[ -n "$prior_status" && "$prior_status" != *' not-installed' ]]; then
            fail "$pkg already has package state/configuration ($prior_status); resolve it separately before installing this batch"
            return 0
        fi
        origins="unknown"
        [[ "$line" =~ $re ]] && origins=${BASH_REMATCH[3]}
        # every origin offering that version must be one the user trusts
        while IFS= read -r o; do
            o=${o%%:*}
            o=${o#"${o%%[![:space:]]*}"}; o=${o%"${o##*[![:space:]]}"}
            [[ -n "$o" ]] || o=unknown
            trusted_origin "$o" || foreign[$o]+="$pkg "
        done < <(tr ',' '\n' <<< "$origins")
    done <<< "$plan"
    local repos first
    for o in "${!foreign[@]}"; do
        first=${foreign[$o]%% *}
        repos=$(apt-cache policy "$first" 2>/dev/null | awk '
            /Candidate:/ { c = $2 }
            NF == 3 && $1 == "***" { v = $2; next }
            NF == 2 && $2 ~ /^-?[0-9]+$/ { v = $1; next }
            v == c && $2 ~ /:\/\// { print $2 }' | sort -u | paste -sd' ' -)
        if software_consent "packages from $o" "$label, including dependencies: ${foreign[$o]% }" \
                "APT origin \"$o\"${repos:+ at $repos}" "system APT package paths" "$label dependency" \
                "$label will not be installed; features that depend on it may be unavailable"; then
            APPROVED_ORIGINS[$o]=1
        else
            fail "skipping $label: packages from $o were declined (${foreign[$o]% })"
            return 0
        fi
    done
    say "  Actual APT candidates and repositories:"
    apt-cache policy "${pkgs[@]}"
    dpkg_list > "$STATE_DIR/apt-before"
    if sudo env DEBIAN_FRONTEND=noninteractive apt-get install --no-remove --no-upgrade -y "${pkgs[@]}"; then
        say "  $label installed"
    else
        fail "some $label packages failed to install — continuing anyway"
    fi
    journal_packages
}

# ---- do it

if (( nothing_to_do )); then
    say "  everything is already installed"
elif [[ $SKIP_DEPS -eq 1 ]]; then
    DEPS_OK=0
    say "  ${ylw}missing (--skip-deps, not installing):${r}"
    report_plan
else
    report_plan
    if ask "  install these now?"; then
        # what is installed now, so everything this run adds - dependencies
        # included - can be told apart from what was already here
        # PPAs first: they change what the update and install below resolve
        ppas=()
        (( NEED_HYPR_PPA ))    && ppas+=("$HYPR_PPA")
        (( NEED_SONGREC_PPA )) && ppas+=("$SONGREC_PPA")
        if (( ${#ppas[@]} )); then
            (( NEED_SPC )) && apt_install "PPA management" software-properties-common
            for ppa in "${ppas[@]}"; do
                snapshot_apt_sources
                if sudo add-apt-repository -y -n "$ppa" >/dev/null 2>&1; then
                    record_once ppa-tracked "$ppa"
                    say "  added $ppa"
                else
                    fail "could not add $ppa"
                fi
                finish_apt_sources
            done
        fi

        say "  refreshing the package lists"
        sudo apt-get update -qq || die "apt-get update failed; fix repository errors before continuing"

        # a name no configured source carries would fail the whole batch, so
        # drop it with a warning instead

        # essential in one batch, each optional group in its own, so a bad
        # optional package can never cost you the essentials
        apt_install "essential" "${ess_missing[@]}" "${build_deps[@]}"
        for g in "${chosen[@]}"; do
            [[ -n "${OPT_MISSING[$g]}" ]] || continue
            # shellcheck disable=SC2086
            apt_install "$g" ${OPT_MISSING[$g]}
        done

        if (( NEED_HYPR )); then
            HV=$(hypr_version)
            if [[ -z "$HV" ]]; then
                fail "Hyprland did not install"
            elif dpkg --compare-versions "$HV" lt "$HYPR_MIN"; then
                warn "Hyprland $HV is older than $HYPR_MIN — it will not read Lucid's lua config"
            fi
        fi
        (( NEED_QS ))      && build_quickshell
        (( NEED_AWWW ))    && build_awww
        (( NEED_MATUGEN )) && install_matugen
        (( NEED_PYWAL ))   && install_pywal
        (( NEED_NERDFONT )) && install_nerdfont
        (( NEED_ADW ))     && install_adw_gtk3
        (( ${#apps_missing[@]} )) && install_flatpaks
        true
    else
        DEPS_OK=0
        warn "skipping. features backed by the missing packages will not work."
    fi
fi

command -v Hyprland &>/dev/null || command -v hyprctl &>/dev/null \
    || warn "Hyprland not found. Lucid uses Hyprland-specific APIs and will not work under another compositor."
command -v qs &>/dev/null \
    || warn "quickshell (qs) not found — the shell is installed but cannot start until it is."


required_missing=()
for p in "${ESSENTIAL_APT[@]}"; do
    [[ "$p" == hyprland ]] && continue
    have_pkg "$p" || required_missing+=("$p")
done
if (( WITH_HYPR )); then
    for p in "${ESSENTIAL_BINDS[@]}"; do have_pkg "$p" || required_missing+=("$p"); done
fi
for cmd in qs matugen; do command -v "$cmd" &>/dev/null || required_missing+=("$cmd"); done
command -v awww &>/dev/null || command -v swww &>/dev/null || required_missing+=(awww/swww)
HV=$(hypr_version)
[[ -n "$HV" ]] && dpkg --compare-versions "$HV" ge "$HYPR_MIN" || required_missing+=("Hyprland >= $HYPR_MIN")
(( ${#required_missing[@]} == 0 )) || die "required dependencies missing: ${required_missing[*]}. Desktop files were not deployed. Run uninstall.sh to undo dependency changes."
qs_needs_build && die "Quickshell rebuild did not complete; desktop files were not deployed."

# --------------------------------------------------------- recording state

# everything the installer or the running shell may write outside its own
# tree, captured before any of it is touched. the shell keeps writing after
# install - the Environment page into gtk and qt settings, the Displays and
# Idle pages into ~/.config/hypr, apply-theme.sh into kitty and starship -
# so these are taken whatever flags this run was given
step "Recording the current state"

FIRST_RUN=1; grep -qsE $'^(runtime-baseline|account)\t' "$MANIFEST" && FIRST_RUN=0

WATCH=(
    "$LUCID_DIR" "$MATUGEN_DIR" "$HOME/.config/hypr"
    "$HOME/.config/cava/quickshell.conf"
    "$HOME/.config/qt6ct/qt6ct.conf"
    "$HOME/.config/gtk-3.0/settings.ini" "$HOME/.config/gtk-3.0/gtk.css" "$HOME/.config/gtk-3.0/colors.css"
    "$HOME/.config/gtk-4.0/settings.ini" "$HOME/.config/gtk-4.0/gtk.css" "$HOME/.config/gtk-4.0/colors.css"
    "$HOME/.gtkrc-2.0" "$HOME/.icons/default/index.theme"
    "$HOME/.config/kitty/kitty.conf" "$HOME/.config/kitty/matugen-colors.conf" "$HOME/.config/kitty/lucid-glass.conf"
    "$HOME/.config/starship.toml"
    "$HOME/.cache/quickshell" "$HOME/.cache/matugen" "$HOME/.cache/wal" "$HOME/.cache/lucidshot-ocr"
    "$HOME/.cache/awww" "$HOME/.cache/current_theme" "$HOME/.cache/current_mode"
    "$HOME/.cache/current_wallpaper" "$HOME/.cache/quickshell-snap-freeze.png"
    "$HOME/.local/share/lucid"
)
# only taken when they are there already: nothing of Lucid's creates them,
# and claiming a missing one would have uninstall delete it after you made
# it yourself. the rc files are taken by the look step, as it edits them
WATCH_IF_PRESENT=(
    "$HOME/.config/qt5ct/qt5ct.conf"
    # apply-theme.sh paints spicetify's Sleek theme when it is installed
    "$HOME/.config/spicetify/Themes/Sleek/color.ini"
)
for p in "${WATCH[@]}"; do track "$p"; done
for p in "${WATCH_IF_PRESENT[@]}"; do
    [[ -e "$p" || -d "$(dirname "$p")" ]] && track "$p"
done

# desktop settings the look and the Environment page write through gsettings
GS_SCHEMA=org.gnome.desktop.interface
if command -v gsettings &>/dev/null; then
    for k in gtk-theme icon-theme cursor-theme cursor-size font-name \
             document-font-name monospace-font-name color-scheme; do
        grep -qsP "^gsetting(?:-reset)?\t$GS_SCHEMA\t$k\t" "$MANIFEST" && continue
        v=$(gsettings get "$GS_SCHEMA" "$k" 2>/dev/null) || continue
        if command -v dconf &>/dev/null && raw=$(dconf read "/org/gnome/desktop/interface/$k" 2>/dev/null); then
            if [[ -z "$raw" ]]; then record gsetting-reset "$GS_SCHEMA" "$k"
            else record gsetting "$GS_SCHEMA" "$k" "$raw"; fi
        else record gsetting "$GS_SCHEMA" "$k" "$v"; fi
    done
fi

# the Idle page enables hypridle's user unit
if ! grep -qsP '^unit\thypridle.service\t' "$MANIFEST"; then
    # is-enabled prints the state and fails for anything but enabled
    unit_state=$(systemctl --user is-enabled hypridle.service 2>/dev/null | head -1 || true)
    unit_active=$(systemctl --user is-active hypridle.service 2>/dev/null || true)
    record unit hypridle.service "${unit_state:-disabled}" "${unit_active:-inactive}"
fi

# Runtime-created cursor themes and imported wallpapers journal their own paths.


# your own account, which the Users page edits through AccountsService
acct_get() {
    busctl -j get-property org.freedesktop.Accounts "/org/freedesktop/Accounts/User$(id -u)" \
        org.freedesktop.Accounts.User "$1" 2>/dev/null \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"])' 2>/dev/null
}
if (( FIRST_RUN )) && command -v busctl &>/dev/null; then
    for prop in RealName Email Location Shell AccountType AutomaticLogin UserName; do
        v=$(acct_get "$prop") && record account "$prop" "$v"
    done
    # IconFile is either a picture AccountsService stores, or - when none is
    # set - the ~/.face fallback it reports instead. the two are put back
    # differently, so the path is kept alongside a copy of the picture
    if icon=$(acct_get IconFile); then
        if [[ -n "$icon" && -r "$icon" ]]; then
            mkdir -p "$ORIG_DIR"
            cp "$icon" "$ORIG_DIR/account-icon"
            record account IconFile "$icon" "$ORIG_DIR/account-icon"
        else
            record account IconFile "${icon:-none}"
        fi
    fi
fi

say "  saved to ${dim}$STATE_DIR${r} — ./uninstall.sh restores recorded changes"

for daemon in awww-daemon swww-daemon; do
    if ! grep -qsP "^daemon\t$daemon\t" "$MANIFEST"; then
        daemon_state=inactive
        pgrep -u "$(id -u)" -x "$daemon" >/dev/null && daemon_state=active
        record daemon "$daemon" "$daemon_state"
    fi
done
record_once runtime-baseline recorded

# --------------------------------------------------------------- the shell

step "Installing the shell"

if [[ "$SRC" == "$SHELL_DIR" ]]; then
    say "  already at $SHELL_DIR, installing in place"
else
    if [[ -e "$SHELL_DIR" ]]; then
        BACKUP="$SHELL_DIR.backup-$STAMP"
        say "  existing config found, moving it to ${dim}$BACKUP${r}"
        # the first install moved someone else's config aside: that is the
        # one uninstall puts back. later backups are Lucid's own, and go
        if path_known "$SHELL_DIR"; then
            record created "$BACKUP"
        else
            record moved "$SHELL_DIR" "$BACKUP"
        fi
        mv "$SHELL_DIR" "$BACKUP"
    else
        path_known "$SHELL_DIR" || record created "$SHELL_DIR"
    fi
    mkdir -p "$SHELL_DIR"
    # everything but the repo's own scaffolding. runtime state is excluded
    # too, so the copy can never carry another machine's settings, pins or
    # api keys — those come from defaults/ in the seed step below
    tar -C "$SRC" -cf - \
        --exclude='.git' --exclude='.github' --exclude='.claude' --exclude='.agents' --exclude='.codex' --exclude='tests' \
        --exclude='support' --exclude='defaults' --exclude='__pycache__' \
        --exclude='wallpapers' \
        --exclude='install.sh' --exclude='uninstall.sh' \
        --exclude='README.md' --exclude='LICENSE' --exclude='.gitignore' \
        --exclude='./lucidprefs/prefs.json' \
        --exclude='./lucidbar/blur.json' \
        --exclude='./lucidbar/clock_reminders.json' \
        --exclude='./lucidbar/mpris_shazam.json' \
        --exclude='./luciddocks/pinned.json' \
        --exclude='./luciddocks/usage.json' \
        --exclude='./luciddocks/wallpaper.json' \
        --exclude='./lucidmoji/config.json' \
        --exclude='./lucidmoji/state.json' \
        --exclude='./lucidkeys/state.json' \
        --exclude='./lucidwidgets/widgets.json' \
        . | tar -C "$SHELL_DIR" -xf -
    say "  shell files -> $SHELL_DIR"
fi

# the launcher sits outside the shell tree so autostart can reach it whether or
# not the Hyprland config was installed. it picks the Qt scene graph backend
# before exec'ing quickshell — see support/lucid/launch-shell.sh
if [[ -f "$SRC/support/lucid/launch-shell.sh" ]]; then
    mkdir -p "$LUCID_DIR"
    install -m755 "$SRC/support/lucid/launch-shell.sh" "$LUCID_DIR/launch-shell.sh"
    say "  shell launcher -> $LUCID_DIR/launch-shell.sh"
else
    warn "support/lucid/launch-shell.sh missing, autostart will run quickshell directly"
fi

if [[ -f "$SRC/support/lucid/logout.sh" ]]; then
    mkdir -p "$LUCID_DIR"
    install -m755 "$SRC/support/lucid/logout.sh" "$LUCID_DIR/logout.sh"
    say "  logout helper -> $LUCID_DIR/logout.sh"
fi

# the brightness slider and keys go through this, so it sits beside the
# launcher for the same reason: the shell needs it with or without the hypr config
if [[ -f "$SRC/support/lucid/brightness.sh" ]]; then
    mkdir -p "$LUCID_DIR"
    install -m755 "$SRC/support/lucid/brightness.sh" "$LUCID_DIR/brightness.sh"
    say "  brightness helper -> $LUCID_DIR/brightness.sh"
fi

# state files. a re-run keeps your settings: anything already in place wins,
# then whatever the previous install left in the backup, and only failing both
# does the shipped default get written
seed() {
    local src="$SRC/defaults/$1" dest="$SHELL_DIR/$2"
    mkdir -p "$(dirname "$dest")"
    if [[ -s "$dest" ]]; then
        say "  ${dim}keeping existing $2${r}"
    elif [[ -n "$BACKUP" && -s "$BACKUP/$2" ]]; then
        cp "$BACKUP/$2" "$dest"
        say "  carried over $2"
    else
        cp "$src" "$dest"
        say "  seeded $2"
    fi
}

# pinned dock apps are detected rather than shipped: a fixed list pins apps the
# machine does not have, and the dock can only draw a letter tile for those
detect_pinned() {
    local dirs=(
        /usr/share/applications
        "$HOME/.local/share/applications"
        /var/lib/flatpak/exports/share/applications
        "$HOME/.local/share/flatpak/exports/share/applications"
        # Ubuntu ships firefox, and offers most of the rest, as snaps
        /var/lib/snapd/desktop/applications
    )
    # the shipped dock lineup, in dock order. one entry per slot and first
    # match wins, so a machine without Lucid's default app still gets that
    # slot filled by whatever equivalent it does have
    local slots=(
        "zen zen-browser app.zen_browser.zen firefox firefox_firefox librewolf chromium brave-browser google-chrome-stable"
        "vscodium codium com.vscodium.codium codium_codium code code_code code-oss com.visualstudio.code zed dev.zed.Zed"
        "spotify com.spotify.Client spotify_spotify spotify-launcher"
        "vesktop dev.vencord.Vesktop discord com.discordapp.Discord discord_discord webcord"
        "org.gnome.Nautilus nautilus org.kde.dolphin dolphin thunar nemo pcmanfm-qt pcmanfm"
        "steam com.valvesoftware.Steam steam_steam"
        "proton.vpn.app.gtk protonvpn-app com.protonvpn.www"
        "kitty alacritty foot org.wezfurlong.wezterm Alacritty com.mitchellh.ghostty"
    )
    local out="" found=0
    for slot in "${slots[@]}"; do
        for cand in $slot; do
            local f=""
            for d in "${dirs[@]}"; do
                [[ -f "$d/$cand.desktop" ]] && { f="$d/$cand.desktop"; break; }
            done
            [[ -n "$f" ]] || continue

            local name icon exec wm
            name=$(sed -n 's/^Name=//p'           "$f" | head -n1)
            icon=$(sed -n 's/^Icon=//p'           "$f" | head -n1)
            # strip desktop field codes, then drop any option left holding
            # nothing (Exec=spotify --uri=%u would otherwise pin "--uri=")
            exec=$(sed -n 's/^Exec=//p' "$f" | head -n1 \
                | sed -E 's/%[fFuUdDnNickvm]//g; s/ +-[^ ]*=( |$)/\1/g; s/  +/ /g; s/ +$//')
            wm=$(  sed -n 's/^StartupWMClass=//p' "$f" | head -n1)
            [[ -n "$name" && -n "$exec" ]] || continue
            # StartupWMClass is an X11 hint. a wayland-native app reports its
            # application-id instead, which is the reverse-dns desktop name -
            # trusting the hint there pins an id no window ever matches
            if [[ "$cand" == *.*.* ]]; then
                wm="$cand"
            else
                [[ -n "$wm" ]] || wm="$cand"
            fi
            [[ -n "$icon" ]] || icon="$cand"
            # escape for json
            esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
            [[ $found -eq 1 ]] && out+=","
            out+=$(printf '\n        {\n            "appId": "%s",\n            "appKey": "%s",\n            "command": "%s",\n            "iconName": "%s",\n            "name": "%s"\n        }' \
                "$(esc "$wm")" "$(esc "$cand")" "$(esc "$exec")" "$(esc "$icon")" "$(esc "$name")")
            found=1
            break
        done
    done
    [[ $found -eq 1 ]] || return 1
    printf '{\n    "pinnedApps": [%s\n    ]\n}\n' "$out"
}

seed_pinned() {
    local dest="$SHELL_DIR/luciddocks/pinned.json"
    mkdir -p "$(dirname "$dest")"
    if [[ -s "$dest" ]]; then
        say "  ${dim}keeping existing luciddocks/pinned.json${r}"
    elif [[ -n "$BACKUP" && -s "$BACKUP/luciddocks/pinned.json" ]]; then
        cp "$BACKUP/luciddocks/pinned.json" "$dest"
        say "  carried over luciddocks/pinned.json"
    elif detect_pinned > "$dest.tmp" 2>/dev/null && [[ -s "$dest.tmp" ]]; then
        mv "$dest.tmp" "$dest"
        say "  pinned $(grep -c '"appId"' "$dest") installed apps to the dock"
    else
        rm -f "$dest.tmp"
        cp "$SRC/defaults/pinned.json" "$dest"
        say "  seeded luciddocks/pinned.json (defaults)"
    fi
}

seed prefs.json            lucidprefs/prefs.json
seed blur.json             lucidbar/blur.json
seed clock_reminders.json  lucidbar/clock_reminders.json
seed mpris_shazam.json     lucidbar/mpris_shazam.json
seed_pinned
seed usage.json            luciddocks/usage.json
seed wallpaper.json        luciddocks/wallpaper.json
seed moji-config.json      lucidmoji/config.json
seed moji-state.json       lucidmoji/state.json
seed keys-state.json       lucidkeys/state.json
seed widgets.json          lucidwidgets/widgets.json

# the media visualiser runs `cava -p ~/.config/cava/quickshell.conf`. without
# that file cava falls back to its own defaults, which emit ncurses output
# instead of the raw ascii frames the bar strip parses - the strip then reads
# one enormous bar and draws it as a circle across the whole popup. not part of
# --no-look: this backs a shell feature, it is not a taste preference.
CAVA_CFG="$HOME/.config/cava/quickshell.conf"
track "$CAVA_CFG"
mkdir -p "$(dirname "$CAVA_CFG")"
if [[ ! -f "$CAVA_CFG" ]]; then
    cp "$SRC/support/cava/quickshell.conf" "$CAVA_CFG"
    say "  cava visualiser config -> ~/.config/cava/quickshell.conf"
elif cmp -s "$SRC/support/cava/quickshell.conf" "$CAVA_CFG"; then
    say "  ${dim}keeping cava/quickshell.conf${r}"
else
    cp "$SRC/support/cava/quickshell.conf" "$CAVA_CFG"
    say "  cava/quickshell.conf refreshed (yours is saved for uninstall)"
fi

# the Environment page writes the Qt half of the appearance - style, icon theme
# and fonts - into qt6ct.conf, and the shipped modules/env.lua exports
# QT_QPA_PLATFORMTHEME=qt6ct so Qt apps read it. envtool.py deliberately never
# creates that file: it refuses to conjure a config for a toolkit the machine
# does not use. so on a fresh machine the page's Qt switch is a silent no-op
# until something writes one. minimal on purpose - the page fills in the style,
# icons and fonts itself on the first apply.
QT6CT_CFG="$HOME/.config/qt6ct/qt6ct.conf"
if ! command -v qt6ct &>/dev/null; then
    say "  ${dim}qt6ct is not installed - the Environment page will skip Qt${r}"
elif [[ -f "$QT6CT_CFG" ]]; then
    say "  ${dim}keeping qt6ct/qt6ct.conf${r}"
else
    track "$QT6CT_CFG"
    mkdir -p "$(dirname "$QT6CT_CFG")"
    printf '[Appearance]\nstyle=Fusion\n' > "$QT6CT_CFG"
    say "  qt6ct.conf -> ~/.config/qt6ct/qt6ct.conf"
fi

# --------------------------------------------------- notification ownership

# org.freedesktop.Notifications is a single-owner D-Bus name and Lucid's bar
# serves it. Any other notification daemon that is merely *installed* can be
# D-Bus-activated the moment something posts a notification - it does not have
# to be autostarted - and whoever claims the name first keeps it for the whole
# session. Lose that race and Lucid's toasts silently never appear: you get the
# other daemon's notification instead, while the bar looks perfectly fine.

step "Checking who serves notifications"

NOTIFY_RIVALS=()
for f in /usr/share/dbus-1/services/*.service "$HOME/.local/share/dbus-1/services/"*.service; do
    [[ -f "$f" ]] || continue
    grep -q '^Name=org.freedesktop.Notifications' "$f" || continue
    grep -qi 'quickshell' "$f" && continue
    # plasma's entry only waits for plasmashell to take the name and never
    # takes it itself, so under Hyprland - no plasmashell - it cannot win
    grep -q '^Exec=.*plasma_waitforname' "$f" && continue
    NOTIFY_RIVALS+=("$f")
done

if [[ ${#NOTIFY_RIVALS[@]} -eq 0 ]]; then
    say "  ${dim}nothing else claims the name — Lucid's notifications win${r}"
else
    for f in "${NOTIFY_RIVALS[@]}"; do
        unit=$(sed -n 's/^SystemdService=//p' "$f" | head -n1)
        exe=$(sed -n 's/^Exec=//p' "$f" | head -n1 | awk '{print $1}')
        say "  ${ylw}$(basename "$exe")${r} also claims org.freedesktop.Notifications"
        say "  ${dim}($f)${r}"
    done
    say "  D-Bus starts it on the first notification, and it then keeps the"
    say "  name for the session — Lucid's own notifications never show."

    if ask "  Stop it taking over?"; then
        for f in "${NOTIFY_RIVALS[@]}"; do
            unit=$(sed -n 's/^SystemdService=//p' "$f" | head -n1)
            exe=$(sed -n 's/^Exec=//p' "$f" | head -n1 | awk '{print $1}')
            base=$(basename "$exe")
            if [[ -n "$unit" ]] && command -v systemctl &>/dev/null; then
                previous=$(systemctl --user is-enabled "$unit" 2>/dev/null || true)
                [[ "$previous" == masked* ]] && continue
                track "$HOME/.config/systemd/user/$unit"
                record_once unit "$unit" "${previous:-disabled}" "$(systemctl --user is-active "$unit" 2>/dev/null || true)"
                record_once mask "$unit"
                if systemctl --user mask "$unit" &>/dev/null; then
                    record_once mask "$unit"
                    say "  masked $unit (uninstall.sh unmasks it)"
                else
                    warn "  could not mask $unit — uninstall $base instead"
                fi
            else
                warn "  $base has no systemd unit to mask — uninstall it to be rid of it"
            fi
            # it may already hold the name in this session; the mask only
            # stops the next activation, so drop the running one too
            if pgrep -x "$base" &>/dev/null; then
                pkill -x "$base" &>/dev/null || true
                say "  stopped the running $base"
            fi
        done
        say "  ${dim}restart Lucid (or log back in) so it claims the name${r}"
    else
        warn "  left alone — expect its notifications instead of Lucid's"
    fi
fi

# ------------------------------------------------------------------ hyprland

# binds, window rules, blur, animations and autostart. this is a whole session
# config, so an existing one is always backed up first and replacing it is a
# question - except when it is Lucid's own from an earlier run, which is just
# refreshed. kept out of the theming step: the modules read no palette, so
# --no-theming should not cost you the binds.
HYPR_DIR="$HOME/.config/hypr"
HYPR_LUA_INSTALLED=0

if [[ $WITH_HYPR -eq 1 ]]; then
    step "Setting up Hyprland"

    HAS_HYPR_CFG=0
    [[ -f "$HYPR_DIR/hyprland.lua" || -f "$HYPR_DIR/hyprland.conf" ]] && HAS_HYPR_CFG=1

    # a config we installed on an earlier run is not "someone else's config":
    # without telling them apart, a re-run asks to replace Lucid's own setup and
    # then tells you to add binds you already have
    HYPR_IS_LUCID=0
    if [[ -f "$HYPR_DIR/modules/binds.lua" ]] && grep -q 'qs ipc call' "$HYPR_DIR/modules/binds.lua" 2>/dev/null; then
        HYPR_IS_LUCID=1
    fi

    DO_HYPR=1
    if [[ $HYPR_IS_LUCID -eq 1 ]]; then
        say "  ${dim}already Lucid's — refreshing it${r}"
    elif [[ $HAS_HYPR_CFG -eq 1 && $HYPR_FORCE -eq 0 ]]; then
        say "  you already have a Hyprland config. Lucid's brings the binds,"
        say "  window rules, blur and animations, and yours is backed up first."
        if ! ask "  Replace it with Lucid's?"; then
            DO_HYPR=0
            say "  ${dim}left alone — re-run with --with-hypr to change your mind${r}"
        fi
    fi

    # the lua config only exists from Hyprland 0.55. an older one reads
    # hyprland.conf and ignores hyprland.lua, so replacing the config would
    # leave it with nothing but its own defaults - worth asking first.
    # `hyprctl version` prints "Hyprland 0.54.0 built from ..." with no v,
    # so the number is taken bare and compared as a number
    if [[ $DO_HYPR -eq 1 ]] && command -v hyprctl &>/dev/null; then
        HYPR_VER=$(hyprctl version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        if [[ -n "$HYPR_VER" ]]; then
            IFS=. read -r hv_major hv_minor _ <<< "$HYPR_VER"
            if (( hv_major == 0 && hv_minor < 55 )); then
                warn "  Hyprland $HYPR_VER predates the lua config (0.55+) — it will ignore hyprland.lua"
                if ! ask "  Install it anyway?"; then
                    DO_HYPR=0
                    say "  ${dim}left alone — update Hyprland, then re-run with --with-hypr${r}"
                fi
            fi
        fi
    fi

    if [[ $DO_HYPR -eq 1 ]]; then
        # the whole directory was saved in "Recording the current state", so
        # uninstall puts back exactly the config you had before Lucid's
        track "$HYPR_DIR"
        if [[ $HAS_HYPR_CFG -eq 1 ]]; then
            say "  your hypr config is saved — ./uninstall.sh puts it back"
        fi
        # this run's starting hyprland.lua, for the require lines kept below
        HYPR_PREV_LUA=""
        if [[ -f "$HYPR_DIR/hyprland.lua" ]]; then
            HYPR_PREV_LUA=$(mktemp)
            cp "$HYPR_DIR/hyprland.lua" "$HYPR_PREV_LUA"
        fi
        mkdir -p "$HYPR_DIR/modules" "$HYPR_DIR/scripts"
        cp "$SRC/support/hypr/hyprland.lua" "$HYPR_DIR/hyprland.lua"
        cp "$SRC/support/hypr/modules/"*.lua "$HYPR_DIR/modules/"
        install -m755 "$SRC/support/hypr/scripts/reload.sh" "$HYPR_DIR/scripts/reload.sh"
        # a hyprland.conf left beside hyprland.lua is ambiguous - Hyprland
        # reads one of them and you cannot tell which, so the install looks
        # like it did nothing. the full directory is already saved above
        if [[ -f "$HYPR_DIR/hyprland.conf" ]]; then
            mv "$HYPR_DIR/hyprland.conf" "$HYPR_DIR/hyprland.conf.replaced-$STAMP"
            say "  hyprland.conf -> hyprland.conf.replaced-$STAMP (lua config wins now)"
        fi
        HYPR_LUA_INSTALLED=1
        say "  hyprland.lua + $(ls "$SRC/support/hypr/modules" | wc -l) modules -> $HYPR_DIR"
        say "  ${dim}binds, window rules, blur, animations and autostart come with it${r}"
        # a refresh replaces hyprland.lua whole, but a require added to it
        # since the last run - hyprmod's require("hyprland-gui"), a module
        # of your own - is not Lucid's to drop. those lines go back in,
        # after Lucid's, so what they set still wins. only on a refresh:
        # a config replaced on request was meant to go
        if [[ $HYPR_IS_LUCID -eq 1 && -n "$HYPR_PREV_LUA" ]]; then
            carried=()
            while IFS= read -r line; do
                grep -qxF -- "$line" "$HYPR_DIR/hyprland.lua" && continue
                printf '%s\n' "${carried[@]:-}" | grep -qxF -- "$line" && continue
                carried+=("$line")
            done < <(grep -E '^[[:space:]]*(pcall[[:space:]]*\([[:space:]]*)?(require|dofile)[[:space:]]*[(,]' \
                        "$HYPR_PREV_LUA" || true)
            if (( ${#carried[@]} )); then
                {
                    printf '\n-- kept by the Lucid installer: these were added to hyprland.lua after it was installed\n'
                    printf '%s\n' "${carried[@]}"
                } >> "$HYPR_DIR/hyprland.lua"
                say "  kept ${#carried[@]} require line(s) added to hyprland.lua since the last install"
            fi
        fi
        [[ -n "$HYPR_PREV_LUA" ]] && rm -f "$HYPR_PREV_LUA"

        # modules/binds.lua binds from this list, which Settings -> Keybinds
        # edits. an existing one is yours and survives the refresh
        mkdir -p "$LUCID_DIR"
        if [[ -s "$LUCID_DIR/keybinds.json" ]]; then
            say "  ${dim}keeping existing $LUCID_DIR/keybinds.json${r}"
            # older lists called brightnessctl directly, which fails without
            # the video group. only the stock commands move to the helper
            if grep -q '"cmd": "brightnessctl -e4 -n2 set 5%[+-]"' "$LUCID_DIR/keybinds.json"; then
                sed -i 's|"cmd": "brightnessctl -e4 -n2 set 5%\([+-]\)"|"cmd": "$HOME/.config/lucid/brightness.sh -e4 -n2 set 5%\1"|' "$LUCID_DIR/keybinds.json"
                say "  brightness binds now go through $LUCID_DIR/brightness.sh"
            fi
        else
            cp "$SRC/support/hypr/keybinds.json" "$LUCID_DIR/keybinds.json"
            say "  keybinds -> $LUCID_DIR/keybinds.json"
        fi

        # the binds shell out to these, so a missing one is a dead key rather
        # than a visible error. worth saying now, not after the first F-key
        for c in kitty nautilus playerctl gnome-calculator wpctl brightnessctl; do
            command -v "$c" &>/dev/null || warn "  $c is missing — the binds that use it will do nothing"
        done

    fi
else
    step "Skipping the Hyprland config (--no-hypr)"
    say "  ${dim}the Lucid binds and window rules are not installed${r}"
fi

# ------------------------------------------------------------------ theming

if [[ $WITH_THEMING -eq 1 ]]; then
    step "Installing the theming layer"

    mkdir -p "$LUCID_DIR/themes" "$MATUGEN_DIR/templates" "$WALL_SCRIPT_DIR" "$HOME/.cache/quickshell"

    cp -r "$SRC/support/lucid/themes/." "$LUCID_DIR/themes/"
    install -m755 "$SRC/support/lucid/apply-theme.sh"      "$LUCID_DIR/apply-theme.sh"
    install -m755 "$SRC/support/lucid/gen-pywal-palette.py" "$LUCID_DIR/gen-pywal-palette.py"
    install -m755 "$SRC/support/lucid/add-theme.py"        "$LUCID_DIR/add-theme.py"
    install -m755 "$SRC/support/lucid/gen-light-palette.py" "$LUCID_DIR/gen-light-palette.py"
    install -m755 "$SRC/support/lucid/set-mode.sh"         "$LUCID_DIR/set-mode.sh"
    install -m755 "$SRC/support/lucid/sync-sddm.sh"        "$LUCID_DIR/sync-sddm.sh"
    install -m644 "$SRC/lucidprefs/install_journal.py" "$LUCID_DIR/install_journal.py"
    install -m644 "$SRC/support/lucid/lucid_palette.py"    "$LUCID_DIR/lucid_palette.py"
    install -m755 "$SRC/support/wallpaper/set-wallpaper.sh" "$WALL_SCRIPT_DIR/set-wallpaper.sh"
    # rules you wrote are yours: only ever placed when there are none
    [[ -f "$LUCID_DIR/wallpaper-outputs.conf" ]] || install -m644 "$SRC/support/lucid/wallpaper-outputs.conf" "$LUCID_DIR/wallpaper-outputs.conf"
    # the sddm theme lives outside $HOME, so it is the one thing here that
    # needs root. skipped entirely when sddm is not installed, and it never
    # switches the active theme - that stays the user's call
    SDDM_THEME_DIR=/usr/share/sddm/themes/lucid
    if [[ -d /usr/share/sddm/themes ]] \
       && ask "  Install the Lucid login-screen theme to $SDDM_THEME_DIR (needs sudo; it is not switched on)?"; then
        # the greeter runs this QML for every account on the machine, so the
        # code stays root's. sync-sddm.sh repaints on each theme change without
        # a password, so only the two files it writes - colours and the
        # pre-blurred wallpaper - are handed to you
        if track_root "$SDDM_THEME_DIR" \
           && sudo install -d -m755 "$SDDM_THEME_DIR" 2>/dev/null \
           && sudo cp -r "$SRC/support/sddm/lucid/." "$SDDM_THEME_DIR/" \
           && sudo chown -R root:root "$SDDM_THEME_DIR" \
           && sudo chmod -R u=rwX,go=rX "$SDDM_THEME_DIR" \
           && sudo chown "$USER" "$SDDM_THEME_DIR/theme.conf" \
           && { [[ -e "$SDDM_THEME_DIR/background.jpg" ]] \
                || sudo install -m644 /dev/null "$SDDM_THEME_DIR/background.jpg"; } \
           && sudo chown "$USER" "$SDDM_THEME_DIR/background.jpg"; then
            say "  sddm theme      -> $SDDM_THEME_DIR"
            # /etc/sddm.conf outranks /etc/sddm.conf.d, so point at the file
            # that actually wins rather than at the tidier-looking drop-in
            say "    enable it with: Current=lucid under [Theme] in /etc/sddm.conf"
        else
            warn "could not install the sddm theme (needs sudo); skipping"
        fi
    fi

    say "  theme palettes  -> $LUCID_DIR/themes"
    say "  theme scripts   -> $LUCID_DIR"
    say "  wallpaper hook  -> $WALL_SCRIPT_DIR/set-wallpaper.sh"

    cp -r "$SRC/support/matugen/templates/." "$MATUGEN_DIR/templates/"
    say "  matugen templates -> $MATUGEN_DIR/templates/"

    MATUGEN_CFG="$MATUGEN_DIR/config.toml"
    track "$MATUGEN_CFG"
    [[ -f "$MATUGEN_CFG" ]] || printf '[config]\n' > "$MATUGEN_CFG"

    TPL='~/.config/matugen/templates'
    MG_ADDED=(); MG_KEPT=(); MG_SKIPPED=()

    # a block is only added when the app it themes is actually present, so
    # matugen never writes colours into a config directory that isn't there.
    # an existing block is always left alone - this config is the user's.
    add_template() {
        local name=$1 input=$2 output=$3 guard=${4:-always} hook=${5:-}
        case "$guard" in
            always) ;;
            dir:*)  [[ -d "${guard#dir:}" ]] || { MG_SKIPPED+=("$name"); return 0; } ;;
            file:*) [[ -f "${guard#file:}" ]] || { MG_SKIPPED+=("$name"); return 0; } ;;
            cmd:*)  command -v "${guard#cmd:}" &>/dev/null || { MG_SKIPPED+=("$name"); return 0; } ;;
        esac
        if grep -q "^\[templates\.$name\]" "$MATUGEN_CFG"; then
            MG_KEPT+=("$name"); return 0
        fi
        # matugen writes this file on every wallpaper change from now on,
        # so it is Lucid's change to undo - whatever was there first included
        track "${output/#\~/$HOME}"
        mkdir -p "$(dirname "${output/#\~/$HOME}")"
        {
            printf '\n[templates.%s]\n' "$name"
            printf "input_path = '%s'\n" "$input"
            printf "output_path = '%s'\n" "$output"
            [[ -n "$hook" ]] && printf "post_hook = '%s'\n" "$hook" || true
        } >> "$MATUGEN_CFG"
        MG_ADDED+=("$name")
    }

    STARSHIP_HOOK='for sh in fish bash zsh; do pkill -WINCH -x "$sh" 2>/dev/null; done; true'

    add_template quickshell     "$TPL/quickshell-colors.json"  '~/.cache/quickshell/matugen.json'
    add_template vscode-raw     "$TPL/vscode-colors"           '~/.cache/matugen/vscode-colors'
    add_template vscode-json    "$TPL/vscode-colors.json"      '~/.cache/matugen/vscode-colors.json'
    add_template hyprland       "$TPL/hyprland-colors.lua"     '~/.config/hypr/colors.conf'    "dir:$HOME/.config/hypr"
    add_template kitty          "$TPL/kitty.conf"              '~/.config/kitty/matugen-colors.conf' "cmd:kitty" 'killall -SIGUSR1 kitty 2>/dev/null || true'
    add_template starship       "$TPL/starship-colors.toml"    '~/.config/starship.toml'       "cmd:starship" "$STARSHIP_HOOK"
    # no dir: guard on these two. gtk only creates ~/.config/gtk-{3,4}.0 once
    # an app writes a setting there, so on a fresh machine the guard skipped
    # both templates, matugen never wrote colors.css, and nautilus kept its
    # stock colours forever. add_template creates the directory itself.
    add_template gtk3           "$TPL/gtk-colors.css"          '~/.config/gtk-3.0/colors.css'
    add_template gtk4           "$TPL/gtk-colors.css"          '~/.config/gtk-4.0/colors.css'
    add_template rofi           "$TPL/rofi-colors.rasi"        '~/.config/rofi/colors.rasi'    "dir:$HOME/.config/rofi"
    add_template waybar         "$TPL/colors.css"              '~/.config/waybar/colors.css'   "dir:$HOME/.config/waybar"
    add_template swaync         "$TPL/colors.css"              '~/.config/swaync/colors.css'   "dir:$HOME/.config/swaync"
    add_template wlogout        "$TPL/colors.css"              '~/.config/wlogout/colors.css'  "dir:$HOME/.config/wlogout"
    add_template ags            "$TPL/ags-colors.scss"         '~/.config/ags/style/_colors.scss' "dir:$HOME/.config/ags"
    add_template vesktop        "$TPL/midnight-discord.css"    '~/.config/vesktop/themes/midnight-discord.css' "dir:$HOME/.config/vesktop"
    add_template vesktop-flatpak "$TPL/midnight-discord.css"   '~/.var/app/dev.vencord.Vesktop/config/vesktop/themes/midnight-discord.css' \
                                "dir:$HOME/.var/app/dev.vencord.Vesktop/config/vesktop"
    add_template pywalfox       "$TPL/pywalfox-colors.json"    '~/.cache/wal/colors.json'      "cmd:pywalfox" 'pywalfox update'
    add_template steam-material "$TPL/steam-material.css"      '~/.local/share/Steam/millennium/themes/Material-Theme/css/main/colors/matugen.css' \
                                "dir:$HOME/.local/share/Steam/millennium/themes/Material-Theme"

    # firefox and zen keep their chrome css inside a generated profile dir, so
    # the path has to be discovered rather than assumed
    # Ubuntu's firefox is a snap, and the Flathub zen lives under ~/.var/app,
    # so each has more than one place its profiles can be
    FF_PROFILE=$(find "$HOME/.mozilla/firefox" "$HOME/snap/firefox/common/.mozilla/firefox" \
                      -maxdepth 1 -type d -name '*.default-release' 2>/dev/null | head -1 || true)
    ZEN_PROFILE=$(find "$HOME/.config/zen" "$HOME/.zen" \
                       "$HOME/.var/app/app.zen_browser.zen/.zen" "$HOME/.var/app/app.zen_browser.zen/config/zen" \
                       -maxdepth 1 -type d -name '*.Default*' 2>/dev/null | head -1 || true)
    if [[ -n "$FF_PROFILE" ]]; then
        add_template firefox-website-colors "$TPL/firefox-colors.css" "$FF_PROFILE/chrome/colors.css"
    else
        MG_SKIPPED+=(firefox-website-colors)
    fi
    if [[ -n "$ZEN_PROFILE" ]]; then
        add_template zen "$TPL/zen-userchrome.css" "$ZEN_PROFILE/chrome/userChrome.css"
    else
        MG_SKIPPED+=(zen)
    fi

    (( ${#MG_ADDED[@]} ))   && say "  matugen added:   ${MG_ADDED[*]}"                                || true
    (( ${#MG_KEPT[@]} ))    && say "  ${dim}matugen kept:    ${MG_KEPT[*]}${r}"                       || true
    (( ${#MG_SKIPPED[@]} )) && say "  ${dim}matugen skipped: ${MG_SKIPPED[*]} (not installed)${r}"    || true

    # GTK apps - Nautilus included - only read colors.css if gtk.css imports it
    for gtkver in 3.0 4.0; do
        gtkdir="$HOME/.config/gtk-$gtkver"
        mkdir -p "$gtkdir"
        if [[ -f "$gtkdir/gtk.css" ]] && grep -q "colors.css" "$gtkdir/gtk.css"; then
            say "  ${dim}gtk-$gtkver already imports colors.css${r}"
        else
            track "$gtkdir/gtk.css"
            printf "@import url('colors.css');\n" >> "$gtkdir/gtk.css"
            say "  gtk-$gtkver now imports colors.css"
        fi
    done

    # --- the look: terminal + prompt + blur -------------------------------
    # each piece is additive and backed up first, because these are files the
    # user owns and may already have tuned
    if [[ $WITH_LOOK -eq 1 && -n "${WANT[look]:-}" ]] && ask "  Apply the Lucid look (kitty, starship prompt, VSCode theme, GTK theme + icons)?"; then

        # --- gtk theme + icons --------------------------------------------
        # gtk reads three places and they disagree happily. under hyprland
        # there is no xsettings daemon, so gtk3/gtk4 take settings.ini as the
        # source of truth while gnome apps and portals read gsettings - set
        # both or half your apps stay light. settings.ini is merged key by
        # key: it also carries the user's font, cursor and hinting choices.
        GTK_THEME_NAME=adw-gtk3-dark
        ICON_THEME_NAME=FairyWren_Dark

        # replace the key if it is there, insert it under [Settings] if not
        ini_set() {
            local f=$1 k=$2 v=$3
            mkdir -p "$(dirname "$f")"
            if [[ ! -f "$f" ]]; then
                printf '[Settings]\n%s=%s\n' "$k" "$v" > "$f"
                return 0
            fi
            grep -q '^\[Settings\]' "$f" || printf '\n[Settings]\n' >> "$f"
            if grep -q "^$k=" "$f"; then
                sed -i "s|^$k=.*|$k=$v|" "$f"
            else
                sed -i "0,/^\[Settings\]/s|^\[Settings\]|[Settings]\n$k=$v|" "$f"
            fi
        }

        # FairyWren is not in Ubuntu's archive, so take it from upstream:
        # the two directories there are exactly the theme names set below
        ICONS_DIR="$HOME/.local/share/icons"
        if [[ -d "$ICONS_DIR/$ICON_THEME_NAME" ]]; then
            say "  ${dim}keeping the FairyWren icons already in $ICONS_DIR${r}"
        elif ! command -v git &>/dev/null; then
            warn "  git is not installed — skipping the FairyWren icon theme"
            ICON_THEME_NAME=""
        elif ! software_consent FairyWren "matching GTK application icons (~140 MB)" "$FAIRYWREN_REPO at commit ${FAIRYWREN_COMMIT:0:12}" "~/.local/share/icons" "optional part of look" "GTK apps will keep their current icons; the rest of the Lucid look will still work"; then
            ICON_THEME_NAME=""
        else
            say "  fetching the FairyWren icon theme (~140MB, one-time)"
            FW_TMP=$(mktemp -d); TEMP_DIRS+=("$FW_TMP")
            # fetched by commit rather than branch, so it is exactly the tree
            # that was reviewed, whatever upstream has pushed since
            if git init -q "$FW_TMP/fw" \
               && git -C "$FW_TMP/fw" fetch -q --depth 1 "$FAIRYWREN_REPO" "$FAIRYWREN_COMMIT" &>/dev/null \
               && git -C "$FW_TMP/fw" checkout -q FETCH_HEAD &>/dev/null \
               && [[ "$(git -C "$FW_TMP/fw" rev-parse HEAD)" == "$FAIRYWREN_COMMIT" ]] \
               && [ -d "$FW_TMP/fw/FairyWren_Dark" && -d "$FW_TMP/fw/FairyWren_Light" ]]; then
                track "$ICONS_DIR/FairyWren_Dark"
                track "$ICONS_DIR/FairyWren_Light"
                mkdir -p "$ICONS_DIR"
                cp -r "$FW_TMP/fw/FairyWren_Dark" "$FW_TMP/fw/FairyWren_Light" "$ICONS_DIR/"
                say "  FairyWren icons -> $ICONS_DIR"
            else
                warn "  could not fetch the FairyWren icons — leaving the icon theme alone"
                ICON_THEME_NAME=""
            fi
            rm -rf "$FW_TMP"
        fi

        # the loader only rescans a theme once its cache is rebuilt
        if [[ -n "$ICON_THEME_NAME" ]] && command -v gtk-update-icon-cache &>/dev/null; then
            for v in Dark Light; do
                [[ -d "$ICONS_DIR/FairyWren_$v" ]] || continue
                gtk-update-icon-cache -qtf "$ICONS_DIR/FairyWren_$v" &>/dev/null || true
            done
        fi

        # adw-gtk3 is not in Ubuntu's archive; the look group fetches it into
        # ~/.local/share/themes, so check the theme directories, not a package
        if [[ ! -d /usr/share/themes/$GTK_THEME_NAME && ! -d "$HOME/.themes/$GTK_THEME_NAME" \
              && ! -d "$HOME/.local/share/themes/$GTK_THEME_NAME" ]]; then
            warn "  $GTK_THEME_NAME is not installed — re-run with --optional=look"
        fi

        for gtkver in 3.0 4.0; do
            gtkini="$HOME/.config/gtk-$gtkver/settings.ini"
            track "$gtkini"
            ini_set "$gtkini" gtk-theme-name "$GTK_THEME_NAME"
            ini_set "$gtkini" gtk-application-prefer-dark-theme 1
            [[ -n "$ICON_THEME_NAME" ]] && ini_set "$gtkini" gtk-icon-theme-name "$ICON_THEME_NAME"
        done
        say "  gtk-3.0 and gtk-4.0 settings.ini -> $GTK_THEME_NAME${ICON_THEME_NAME:+ + $ICON_THEME_NAME}"

        # gnome apps, portals and anything reading dconf take these instead
        if command -v gsettings &>/dev/null; then
            gsettings set org.gnome.desktop.interface gtk-theme "$GTK_THEME_NAME" 2>/dev/null || true
            gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
            [[ -n "$ICON_THEME_NAME" ]] && \
                gsettings set org.gnome.desktop.interface icon-theme "$ICON_THEME_NAME" 2>/dev/null || true
            say "  gsettings -> $GTK_THEME_NAME, prefer-dark${ICON_THEME_NAME:+, $ICON_THEME_NAME}"
        else
            warn "  gsettings not found — GNOME apps may ignore the theme"
        fi

        # kitty - the include is what makes matugen's colours apply at all
        KITTY_CFG="$HOME/.config/kitty/kitty.conf"
        track "$KITTY_CFG"
        track "$HOME/.config/kitty/lucid-glass.conf"
        if [[ -f "$HOME/.config/kitty/kitty.conf" ]]; then
            if grep -q "matugen-colors.conf" "$HOME/.config/kitty/kitty.conf"; then
                say "  ${dim}kitty.conf already includes matugen-colors.conf${r}"
            else
                printf '\n# added by Lucid — colours follow the active theme\ninclude ./matugen-colors.conf\n' \
                    >> "$HOME/.config/kitty/kitty.conf"
                say "  kitty.conf now includes matugen-colors.conf"
            fi
        else
            mkdir -p "$HOME/.config/kitty"
            cp "$SRC/support/look/kitty.conf" "$HOME/.config/kitty/kitty.conf"
            say "  kitty.conf -> ~/.config/kitty/kitty.conf"
        fi

        # background_opacity follows the Glass slider, out of a file the shell
        # rewrites. seed it first: kitty warns about an include it cannot find,
        # and the shell only writes once the value differs from what is there
        if [[ ! -f "$HOME/.config/kitty/lucid-glass.conf" ]]; then
            printf '# generated by lucid settings\ndynamic_background_opacity yes\nbackground_opacity 1.00\n' \
                > "$HOME/.config/kitty/lucid-glass.conf"
            say "  lucid-glass.conf -> ~/.config/kitty/lucid-glass.conf"
        fi
        if grep -q "lucid-glass.conf" "$KITTY_CFG"; then
            say "  ${dim}kitty.conf already includes lucid-glass.conf${r}"
        else
            printf '\n# added by Lucid — opacity follows the Glass slider\ninclude ./lucid-glass.conf\n' \
                >> "$KITTY_CFG"
            say "  kitty.conf now follows the Glass slider"
        fi

        # kitty opens fish rather than the login shell. only wired when fish is
        # really there: kitty fails to open a window at all on a shell it cannot
        # exec, and that reads as "the terminal keybind is broken"
        if command -v fish &>/dev/null; then
            if grep -qE '^[[:space:]]*shell[[:space:]]+' "$KITTY_CFG"; then
                say "  ${dim}kitty.conf already sets a shell${r}"
            else
                printf '\n# added by Lucid\nshell fish\n' >> "$KITTY_CFG"
                say "  kitty.conf now opens fish"
            fi
        else
            sed -i '/^# kitty opens fish rather than the login shell$/d; /^shell fish$/d' "$KITTY_CFG"
            warn "  fish is not installed — kitty will use your login shell"
        fi

        # vscode / vscodium - matugen writes the colour files, but they do
        # nothing until the Matugen theme extension is installed and selected
        # vscode_wire <label> <settings.json> <cli words...>
        vscode_wire() {
            local cli=$1 cfg=$2; shift 2
            local run=("$@")
            command -v "${run[0]}" &>/dev/null || return 0
            if "${run[@]}" --list-extensions 2>/dev/null | grep -i "matugen-theme" >/dev/null; then
                say "  ${dim}$cli already has the Matugen theme${r}"
            elif ! software_consent "Matugen extension for $cli" "matching editor colours" "editor-configured extension gallery (VS Code Marketplace or Open VSX), haikalllp.matugen-theme" "editor user extension directory" "optional part of look" "$cli will keep its current colour theme; the rest of the Lucid look will still work"; then
                return 0
            elif "${run[@]}" --install-extension haikalllp.matugen-theme &>/dev/null; then
                record_once vscode-ext haikalllp.matugen-theme "${run[@]}"
                say "  installed the Matugen theme extension for $cli"
            else
                warn "  could not install the Matugen theme for $cli — do it by hand"
                return 0
            fi

            track "$cfg"
            mkdir -p "$(dirname "$cfg")"
            if [[ ! -f "$cfg" ]]; then
                printf '{\n  "workbench.colorTheme": "Matugen"\n}\n' > "$cfg"
                say "  $cli settings.json -> Matugen theme"
            elif grep -q '"workbench.colorTheme"' "$cfg"; then
                say "  ${dim}$cli already sets workbench.colorTheme${r}"
            else
                local before; before=$(mktemp)
                cp "$cfg" "$before"
                # settings.json is jsonc - trailing commas are legal there - so
                # insert as text rather than reparsing and reformatting it
                awk 'ins != 1 && /\{/ { print; print "  \"workbench.colorTheme\": \"Matugen\","; ins = 1; next } 1' \
                    "$cfg" > "$cfg.lucid-tmp" && mv "$cfg.lucid-tmp" "$cfg"
                if grep -q '"workbench.colorTheme"' "$cfg"; then
                    say "  $cli now uses the Matugen theme"
                else
                    cp "$before" "$cfg"
                    warn "  couldn't edit $cli settings.json — set the Matugen theme by hand"
                fi
                rm -f "$before"
            fi
        }

        vscode_wire codium   "$HOME/.config/VSCodium/User/settings.json"    codium
        vscode_wire code     "$HOME/.config/Code/User/settings.json"        code
        vscode_wire code-oss "$HOME/.config/Code - OSS/User/settings.json"  code-oss
        # the Flathub build, which is what the apps group installs
        if flatpak info com.vscodium.codium &>/dev/null; then
            vscode_wire "codium (flatpak)" \
                "$HOME/.var/app/com.vscodium.codium/config/VSCodium/User/settings.json" \
                flatpak run --command=codium com.vscodium.codium
        fi

        # starship - the prompt shape ships here; matugen and apply-theme.sh
        # rewrite only its [palettes.colors] block on every theme change, so
        # this file is what makes the prompt look like Lucid's
        STARSHIP_CFG="$HOME/.config/starship.toml"
        track "$STARSHIP_CFG"
        if [[ ! -f "$STARSHIP_CFG" ]]; then
            cp "$SRC/support/look/starship.toml" "$STARSHIP_CFG"
            say "  starship.toml -> ~/.config/starship.toml"
        elif grep -q '^\[palettes.colors\]' "$STARSHIP_CFG"; then
            # already the Lucid prompt. its colours are whatever the current
            # theme painted, so re-copying would only reset them to the seed
            say "  ${dim}keeping your starship.toml (already the Lucid prompt)${r}"
        else
            cp "$SRC/support/look/starship.toml" "$STARSHIP_CFG"
            say "  starship.toml -> ~/.config/starship.toml (yours is saved for uninstall)"
        fi
        command -v starship &>/dev/null \
            || warn "  starship is not installed — the prompt config is in place but unused"

        # the config does nothing until the shell actually calls starship, and
        # the init line differs per shell. only ever appended, never rewritten.
        # a missing rc is created for your login shell only - writing a .zshrc
        # for someone who does not use zsh is just litter
        LOGIN_SH=$(basename "${SHELL:-}")
        starship_init() {
            local rc=$1 line=$2 shname=$3 always=${4:-0}
            if [[ ! -f "$rc" ]]; then
                [[ "$shname" == "$LOGIN_SH" || $always -eq 1 ]] || return 0
                track "$rc"
                mkdir -p "$(dirname "$rc")"
                printf '# added by Lucid\n%s\n' "$line" > "$rc"
                say "  created $(basename "$rc") to start starship"
                return 0
            fi
            if grep -F 'starship init' "$rc" >/dev/null; then
                say "  ${dim}$(basename "$rc") already starts starship${r}"
            else
                track "$rc"
                printf '\n# added by Lucid\n%s\n' "$line" >> "$rc"
                say "  $(basename "$rc") now starts starship"
            fi
        }
        starship_init "$HOME/.bashrc"                  'eval "$(starship init bash)"'   bash
        # zsh redraws on SIGWINCH but does not re-run precmd, so the prompt keeps
        # the old colours until you press enter. reset-prompt re-runs starship.
        # bash has no equivalent - its prompt updates on the next prompt instead
        starship_init "$HOME/.zshrc" 'eval "$(starship init zsh)"
TRAPWINCH() { zle && { zle reset-prompt; zle -R } }'    zsh
        # always for fish, whatever the login shell is - kitty opens it
        starship_init "$HOME/.config/fish/config.fish" 'starship init fish | source'    fish 1

        # the prompt and kitty.conf are drawn with nerd font glyphs; without
        # the font every segment renders as a replacement box
        fc-list 2>/dev/null | grep -i 'JetBrainsMono Nerd Font' >/dev/null \
            || warn "  JetBrainsMono Nerd Font is missing — the prompt will show boxes"

        # hyprland blur - skipped when the lua config went in above, since its
        # decorations module already carries the same blur. ~/.config/hypr was
        # saved whole at the start, so none of these edits needs its own backup
        if [[ $HYPR_LUA_INSTALLED -eq 1 ]]; then
            say "  ${dim}blur comes from modules/decorations.lua${r}"
        elif [[ -f "$HYPR_DIR/hyprland.lua" ]]; then
            mkdir -p "$HYPR_DIR/modules"
            cp "$SRC/support/look/lucid-look.lua" "$HYPR_DIR/modules/lucid-look.lua"
            # per-app glass rides along: Settings > Glass writes lucid-glass.lua
            # and this is the module that reads it
            cp "$SRC/support/hypr/modules/glass.lua" "$HYPR_DIR/modules/glass.lua"
            if grep -q 'require("modules.lucid-look")' "$HYPR_DIR/hyprland.lua"; then
                say "  ${dim}hyprland.lua already requires modules.lucid-look${r}"
            else
                printf '\nrequire("modules.lucid-look")\n' >> "$HYPR_DIR/hyprland.lua"
                say "  hyprland.lua now requires modules.lucid-look"
            fi
            if grep -q 'require("modules.glass")' "$HYPR_DIR/hyprland.lua"; then
                say "  ${dim}hyprland.lua already requires modules.glass${r}"
            else
                printf '\nrequire("modules.glass")\n' >> "$HYPR_DIR/hyprland.lua"
                say "  hyprland.lua now requires modules.glass"
            fi
        elif [[ -f "$HYPR_DIR/hyprland.conf" ]]; then
            cp "$SRC/support/look/lucid-look.conf" "$HYPR_DIR/lucid-look.conf"
            if grep -q "lucid-look.conf" "$HYPR_DIR/hyprland.conf"; then
                say "  ${dim}hyprland.conf already sources lucid-look.conf${r}"
            else
                printf '\nsource = ~/.config/hypr/lucid-look.conf\n' >> "$HYPR_DIR/hyprland.conf"
                say "  hyprland.conf now sources lucid-look.conf"
            fi
        else
            mkdir -p "$HYPR_DIR"
            cp "$SRC/support/look/lucid-look.conf" "$HYPR_DIR/lucid-look.conf"
            warn "  no hyprland config found — source lucid-look.conf yourself"
        fi
    fi

    # first-run palette, so the shell has colours before any wallpaper is set
    [[ -f "$HOME/.cache/current_theme" ]] || printf 'matugen' > "$HOME/.cache/current_theme"
    if [[ ! -s "$HOME/.cache/quickshell/matugen.json" ]]; then
        cp "$SRC/support/lucid/themes/nord/quickshell.json" "$HOME/.cache/quickshell/matugen.json"
        say "  seeded a starter palette (nord) — pick a theme in Settings to change it"
    fi
else
    step "Skipping the theming layer (--no-theming)"
    say "  the theme picker and wallpaper strip will not work until it is installed"
fi

# -------------------------------------------------------------- wallpapers

# one folder per theme, which is where the wallpaper strip looks:
# ~/Pictures/wallpapers/<theme>. yours are never overwritten or removed
PICTURES_DIR="$HOME/Pictures/wallpapers"
if [[ $WITH_WALLPAPERS -eq 1 && -d "$SRC/wallpapers" ]]; then
    step "Installing the wallpapers"

    WALL_NEW=0
    WALL_KEPT=0
    for dir in "$SRC"/wallpapers/*/; do
        [[ -d "$dir" ]] || continue
        theme="$(basename "$dir")"
        for pic in "$dir"*; do
            [[ -f "$pic" ]] || continue
            dest="$PICTURES_DIR/$theme/$(basename "$pic")"
            if [[ -e "$dest" ]]; then
                WALL_KEPT=$((WALL_KEPT + 1))
            else
                # recorded one by one: the folder is shared with your own
                # wallpapers, so uninstall takes back only these files
                track "$dest"
                mkdir -p "$PICTURES_DIR/$theme"
                cp "$pic" "$dest"
                WALL_NEW=$((WALL_NEW + 1))
            fi
        done
    done

    say "  $WALL_NEW wallpapers -> $PICTURES_DIR"
    [[ $WALL_KEPT -gt 0 ]] && say "  ${dim}$WALL_KEPT were already there, left as they are${r}"
    say "  ${dim}the strip shows the folder for the theme you are on; SUPER+B opens it${r}"
elif [[ $WITH_WALLPAPERS -eq 0 ]]; then
    step "Skipping the wallpapers (--no-wallpapers)"
    say "  ${dim}$PICTURES_DIR is left alone; the strip shows whatever is in it${r}"
fi

# ---------------------------------------------------------------------- done

step "Done"

if (( ${#SKIPPED_CAPABILITIES[@]} )); then
    say ""
    say "  ${b}${ylw}Skipped third-party capabilities${r}"
    for skipped in "${SKIPPED_CAPABILITIES[@]}"; do
        say "  - $skipped"
    done
fi

# a running instance is still on the old files, so offer the restart that
# actually puts the new version on screen
# no grep -q here: it would close the pipe, and pipefail would then read the
# producer's SIGPIPE as "not running"
if qs list 2>/dev/null | grep -F "$SHELL_DIR/shell.qml" >/dev/null; then
    if ask "  Lucid is running on the old files. Restart it now?" y; then
        qs kill -p "$SHELL_DIR" 2>/dev/null || true
        sleep 1
        (setsid qs -d 9>&- >/dev/null 2>&1 &) || true
        say "  restarted"
    fi
fi

cat <<EOF

  ${b}Lucid $VERSION${r} is installed.

  Start it:      ${b}qs${r}
  Settings:      ${b}qs ipc call -- settings open${r}
  Uninstall:     ${b}./uninstall.sh${r} restores recorded changes

EOF

if [[ $HYPR_LUA_INSTALLED -eq 1 ]]; then
    cat <<EOF
  Hyprland is configured: modules/binds.lua carries the binds, the window
  and layer rules are in place, and modules/autostart.lua starts the shell
  on login.

    SUPER            launcher        SUPER+W      workspaces
    SUPER+S          settings        SUPER+T      theme picker
    SUPER+period     emoji           SUPER+B      wallpaper
    SUPER+P          commands        SUPER+E      files
    SUPER+C          close window    SUPER+V      float
    SUPER+D / Print  screenshot      F10          lock
    SUPER+R          reload hypr     F9           terminal

  Special workspaces slide over whatever you are on; the same keys hide them:

    SUPER+SHIFT+S    scratchpad      SUPER+ALT+S  stash a window
    SUPER+SHIFT+M    music           SUPER+SHIFT+D  comms
    SUPER+SHIFT+R    to-do           CTRL+SHIFT+ESC system monitor

  ${b}The new binds are not live yet${r} — run ${b}hyprctl reload${r}, or log out
  and back in to pick up the autostart too.

EOF
else
    cat <<EOF
  Autostart:     add ${b}exec-once = qs${r} to your Hyprland config

  Suggested Hyprland binds:

    bind = SUPER, SPACE,  exec, qs ipc call -- launcher toggle
    bind = SUPER, E,      exec, qs ipc call -- moji toggle
    bind = SUPER, L,      exec, qs ipc call -- lock lock
    bind = SUPER, S,      exec, qs ipc call -- snap toggle
    bind = SUPER, comma,  exec, qs ipc call -- settings open

  Keep the double dash: it is required whenever a call takes an argument.
  Or run ${b}./install.sh --with-hypr${r} to take Lucid's config wholesale.

EOF
fi

if [[ $DEPS_OK -eq 0 ]]; then
    warn "some dependencies are missing — the shell is installed, but the"
    warn "features they back will not work until you install them."
fi
