#!/usr/bin/env bash
# Shared install/uninstall journal operations. No actions on source.

# the scripts keep umask 077 so their state, backups and archives stay private.
# sudo keeps the stricter of that and its own, so anything written as root -
# /usr/local, the sddm theme, apt sources and keyrings - would come out 700/600
# and unreadable to users, the greeter and apt's _apt sandbox
sudo() { (umask 022 && command sudo "$@"); }

record() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    local IFS=$'\t'
    printf '%s\n' "$*" >> "$MANIFEST"
}
# true when an earlier run already recorded this path, under any kind
path_known() {
    [[ -f "$MANIFEST" ]] && awk -F'\t' -v p="$1" '$2 == p { f = 1 } END { exit !f }' "$MANIFEST"
}
record_once() {
    [[ -f "$MANIFEST" ]] && grep -qxF -- "$(IFS=$'\t'; printf '%s' "$*")" "$MANIFEST" && return 0
    record "$@"
}


dpkg_list() { dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk 'length($1) >= 2 && substr($1,2,1) != "n" { print $2 }' | sort; }

# System payloads are backed up before replacement, including symlinks.
track_root() {
    local p=$1 copy="$ORIG_DIR/root$1" ancestor
    ancestor=$(dirname "$p")
    while [[ "$ancestor" != / ]]; do
        [[ ! -L "$ancestor" ]] || { warn "refusing symlinked system destination $ancestor"; return 1; }
        ancestor=$(dirname "$ancestor")
    done
    path_known "$p" && return 0
    if [[ -e "$p" || -L "$p" ]]; then
        mkdir -p "$(dirname "$copy")"
        sudo cp -a -- "$p" "$copy" || return 1
        record root-saved "$p" "$copy"
    else
        local dirs=() d
        d=$(dirname "$p")
        while [[ ! -e "$d" && "$d" != / ]]; do dirs=("$d" "${dirs[@]}"); d=$(dirname "$d"); done
        for d in "${dirs[@]}"; do path_known "$d" || record root-mkdir "$d"; done
        record root-created "$p"
    fi
}
# Capture source/key files before add-apt-repository, including partial failures.
# Only files changed by that invocation enter the permanent restore manifest.
snapshot_apt_sources() {
    local d="$STATE_DIR/apt-source-snapshot"
    [[ ! -e "$d" ]] || die "unfinished APT source snapshot at $d; run uninstall.sh first"
    mkdir -p "$d"
    mkdir -p "$d/apt"
    local path
    for path in sources.list sources.list.d trusted.gpg trusted.gpg.d keyrings; do
        [[ ! -e "/etc/apt/$path" ]] || sudo cp -a "/etc/apt/$path" "$d/apt/"
    done
    touch "$d/ready"
}
finish_apt_sources() {
    local d="$STATE_DIR/apt-source-snapshot" f rel original copy
    [[ -f "$d/ready" ]] || return 0
    while IFS= read -r -d '' rel; do
        f="/etc/apt/$rel"; original="$d/apt/$rel"
        if [[ -f "$f" && -f "$original" ]] && cmp -s "$f" "$original"; then continue; fi
        if [[ -L "$f" && -L "$original" && "$(readlink "$f")" == "$(readlink "$original")" ]]; then continue; fi
        path_known "$f" && continue
        if [[ -e "$original" || -L "$original" ]]; then
            copy="$ORIG_DIR/root$f"
            mkdir -p "$(dirname "$copy")"
            sudo cp -a "$original" "$copy" || return 1
            record root-saved "$f" "$copy"
        else
            record root-created "$f"
        fi
    done < <({ find /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/trusted.gpg /etc/apt/trusted.gpg.d /etc/apt/keyrings -type f -o -type l 2>/dev/null | sed 's|^/etc/apt/||'; find "$d/apt" -type f -o -type l | sed "s|^$d/apt/||"; } | sort -u | tr '\n' '\0')
    sudo rm -rf "$d"
}

install_root_file() {
    track_root "$2" || return 1
    sudo install -d -m755 "$(dirname "$2")" || return 1
    sudo rm -f -- "$2" || return 1
    sudo install -m755 -- "$1" "$2"
}
install_staged() {
    local stage=$1 f dest
    while IFS= read -r -d '' f; do
        dest=${f#"$stage"}
        track_root "$dest" || return 1
        sudo install -d -m755 "$(dirname "$dest")" || return 1
        sudo cp -a --remove-destination -- "$f" "$dest" || return 1
    done < <(find "$stage/usr/local" \( -type f -o -type l \) -print0)
}


journal_packages() {
    [[ -f "$STATE_DIR/apt-before" ]] || return 0
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && record_once apt "$p"
    done < <(comm -13 "$STATE_DIR/apt-before" <(dpkg_list))
    rm -f "$STATE_DIR/apt-before"
}

# Recover partial Flatpak transactions without claiming unrelated existing refs.
journal_flatpaks() {
    [[ -f "$STATE_DIR/flatpak-before" ]] || return 0
    local ref after
    after=$(flatpak list --user --columns=ref | sort) || return 1
    while IFS= read -r ref; do
        [[ -z "$ref" ]] || record_once flatpak-ref "$ref"
    done < <(comm -13 "$STATE_DIR/flatpak-before" <(printf '%s\n' "$after"))
    rm -f "$STATE_DIR/flatpak-before"
}
