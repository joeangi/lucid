# Ubuntu installation

## Install

Lucid installs to `~/.config/quickshell`.

Target **Ubuntu 26.04**, with
**Qt ≥ 6.6** and **Hyprland ≥ 0.55**. Stock Ubuntu 24.04 is unsupported:
[its Qt is 6.4](https://packages.ubuntu.com/noble/libqt6core6t64), while
[Quickshell v0.3.1 requires Qt 6.6](https://github.com/quickshell-mirror/quickshell/blob/v0.3.1/CMakeLists.txt).
Ubuntu derivatives are checked against their available packages; this is not a
claim that every derivative has been tested. Check without changing anything:

```sh
./support/ubuntu/install.sh --check
```

Install from a separate checkout (keep it for updates and uninstall):

```sh
git clone https://github.com/joeangi/lucid.git
cd lucid
./support/ubuntu/install.sh
```

### Installer steps

The Ubuntu installer does the following:

1. **Checks your system** — checks Qt before making changes and requires the
   runtime dependencies before deploying desktop files. A failed dependency
   installation retains its recovery record for `./support/ubuntu/uninstall.sh`.
2. **Installs dependencies**, in two tiers (see [Requirements](#requirements)):
   - **Essential** — what Lucid needs to work at all. Most of it comes from
     apt. Three things Ubuntu doesn't package are built or fetched and
     installed to `/usr/local`: **Quickshell** (built from source), **awww**
     (the wallpaper daemon, built with cargo) and **matugen** (release
     binary). If the available Hyprland is older than the 0.55 that Lucid's Lua config
     needs, the installer offers the
     [`cppiber/hyprland`](https://launchpad.net/~cppiber/+archive/ubuntu/hyprland)
     PPA, subject to its availability for your Ubuntu release.
   - **Optional** — grouped by feature: `capture`, `clipboard`, `media`,
     `system`, `phone`, `pywal`, `look` and `apps`. You're asked about each
     group. Leave one out and only its feature is missing. `--minimal` skips
     all of them, and `--optional=capture,look` picks a set up front.

   Every optional group defaults to **skip**. Each external source/download gets
   its own **THIRD-PARTY DEPENDENCY** card showing the exact feature it enables,
   required/optional status, source, destination, and what will not work if you
   skip it. The installer then gives numbered **Install** and **Skip** choices;
   choosing a feature group never silently approves its external sources. Each
   dock app has its own choice. Skipping a missing required dependency stops
   deployment; skipping an optional item leaves only the named capability
   unavailable. `--skip-deps` also prevents icon and editor
   extension downloads. `--yes` alone does not consent to third-party sources
   or select optional groups.

   APT resolves a proposed transaction before installing. Transactions that
   replace or remove existing packages are refused because their exact old
   versions may not be available to restore later. Update those dependencies
   separately if desired, then rerun the installer. Every package in the
   transaction, dependencies included, is checked against the APT origin of
   the version it would install. Ubuntu's archive (from any mirror) and, on a
   derivative, the distribution's own archive pass; anything else — including
   third-party sources already configured on the machine — needs consent, asked
   once per origin with the packages it would supply. Approving a PPA covers
   the packages it brings. An added PPA stays enabled, and `apt upgrade` keeps
   taking updates from it until `./support/ubuntu/uninstall.sh` removes it.

   Downloads are pinned: Quickshell and awww are built from a tag that must
   still match its recorded commit, and the matugen binary, the Nerd Font and
   adw-gtk3 are checked against recorded SHA-256 sums. A mismatch fails that
   item instead of installing it. Prompts that change the system default to
   **no** on a bare Enter.

   Before changing anything it **records the current state** in
   `~/.local/state/lucid`. It keeps a copy of every file it will touch, your
   GTK/icon/font gsettings and your account details, and then logs each
   package, PPA, Flatpak and build as it installs them. That record is what
   lets [`./support/ubuntu/uninstall.sh`](#uninstall) put everything back.
3. **Copies the shell** to `~/.config/quickshell`, moving any existing config to
   `~/.config/quickshell.backup-<timestamp>` first.
4. **Sets up Hyprland** — `hyprland.lua` and its modules: the keybinds, the
   window and layer rules, blur, animations, and an autostart that launches the
   shell on login. If you already have a config you are asked first, and it is
   saved so uninstalling restores it; `--no-hypr` keeps yours untouched.
5. **Sets up theming** — the palettes, the wallpaper hook, and the matugen
   template. An existing `matugen/config.toml` is appended to, never replaced.
6. **Applies the look** — kitty's colours, its opacity and its fish shell, the
   starship prompt (wired into `.bashrc`, `.zshrc` and `config.fish`), the
   VSCode/VSCodium Matugen theme, and the GTK theme: `adw-gtk3-dark` with the
   FairyWren icons, written to `gsettings` and to both `gtk-3.0` and `gtk-4.0`
   `settings.ini`.
   This requires selecting the `look` group; `--no-look` skips it.
7. **Pins the dock** — reads your installed `.desktop` files and pins the real
   apps, so the dock is never a row of blank letter tiles.
8. **Offers to restart** a running instance onto the new files.

Then reload Hyprland so the new binds and rules take effect:

```sh
hyprctl reload
```

Or log out and back in, which picks up the autostart too. To start the shell by
hand in the meantime, run `qs`.

Set a wallpaper from **Settings → General** on first run — that's what generates
your colour palette.

## Installer options

| Flag | What it does |
| --- | --- |
| `--no-theming` | Skips palette templates and theme scripts. The shell launcher and any required Quickshell build stamp still use `~/.config/lucid`. |
| `--no-hypr` | Keeps your Hyprland config. Lucid's binds, window rules, blur and autostart are not installed. |
| `--no-apps` | Drops the `apps` group: the Flatpaks the dock ships pinned (Zen, VSCodium, Spotify, Vesktop, Steam, Proton VPN). The dock then pins whatever equivalents you already have. |
| `--no-look` | Doesn't touch `kitty.conf`, `starship.toml`, your shell rc files, VSCode settings, or the GTK theme and icons. Drops the `look` group too. |
| `--no-wallpapers` | Doesn't copy the bundled wallpapers into `~/Pictures/wallpapers`. They are ~180 MB, so this is worth passing on a small disk or a slow link. |
| `--with-hypr` | Reinstalls Lucid's Hyprland config even when one is already in place. |
| `--minimal` | Installs only the essential dependencies and skips every optional group. |
| `--optional=LIST` | Picks the optional groups up front instead of asking about each one: a comma-separated list, or `all` / `none`. |
| `--list-optional` | Prints what each tier and group installs, then exits. |
| `--skip-deps` | Prevents all software downloads/installations, including look extras; fails deployment if required dependencies are missing. |
| `--check` | Read-only Ubuntu package/runtime compatibility check; does not launch or validate the graphical session. |
| `--allow-third-party` | Explicit consent to the disclosed external sources in unattended mode, only for selected features. |
| `-y`, `--yes` | Accepts configuration prompts. Optional groups default to none; choose them with `--optional=LIST`. External sources also require `--allow-third-party`. |

Re-running the installer is how you update. It moves your existing
`~/.config/quickshell` to `~/.config/quickshell.backup-<timestamp>`, installs
the new shell files, then carries your settings, pinned apps, reminders,
Shazam history and API keys forward into it. Nothing is deleted, and the
backup stays where it is until you remove it. Updating never replaces the
install record: `./support/ubuntu/uninstall.sh` always restores what was there before your
*first* install.

## Requirements

### Essential

On Ubuntu, 26.04 is the target; Qt 6.6 or newer and Hyprland 0.55 or newer are
required. Package candidates are checked at runtime. These lists explain what
is installed and allow you to provision dependencies yourself. `./support/ubuntu/install.sh --list-optional` prints the same lists.


Without these the shell doesn't start, or starts visibly broken: no
wallpaper, no palette, dead panels.

| Package | Backs |
| --- | --- |
| `hyprland` ≥ 0.55, `xdg-desktop-portal-hyprland` | The compositor. If the archive candidate is too old for `hyprland.lua`, the installer offers `ppa:cppiber/hyprland` with explicit consent |
| **quickshell** | The shell itself. Not in Ubuntu's archive — built from source (`v0.3.1`) into `/usr/local`. It uses private Qt API, so it has to be rebuilt after a Qt upgrade. Re-running the installer notices the Qt version changed and rebuilds it |
| `qt6-wayland`, `qt6-svg-plugins`, `qt6-image-formats-plugins`, `qml6-module-qtquick`, `-qtquick-shapes`, `-qtquick-effects`, `-qtquick-controls`, `-qtquick-templates`, `-qtquick-layouts`, `-qtquick-window`, `-qtqml`, `-qtqml-models`, `-qtqml-workerscript`, `-qt5compat-graphicaleffects`, `-qtmultimedia` | The Qt runtime Quickshell loads the shell against. Ubuntu splits every QML module into its own package |
| **matugen** | Wallpaper-derived colours. Not in the archive — the release binary goes to `/usr/local/bin` (built with cargo on non-x86_64) |
| **awww** | Setting the wallpaper. Not in the archive — built with cargo into `/usr/local/bin`. An existing `swww` counts |
| `jq`, `curl`, `git`, `python3` | Theme switching, weather and location, the update check, importing a theme from a repo, and the helper scripts |
| `network-manager` | Wi-Fi panel |
| `bluez` | Bluetooth panel and settings page |
| `pipewire`, `pipewire-pulse`, `wireplumber`, `pulseaudio-utils` | Volume and audio devices (`pactl`, `wpctl`) |
| `upower`, `brightnessctl` | Battery and brightness |
| `polkitd`, `pkexec` | Every administrator prompt. The shell is the session's authentication agent and drives polkit's setuid helper, so don't start another agent — only one can hold the session |
| `libnotify-bin`, `xdg-utils`, `wl-clipboard` | Notification actions, opening links and files, copying |
| `gsettings-desktop-schemas`, `fonts-noto-color-emoji` | GTK settings and emoji rendering |
| `kitty`, `nautilus`, `playerctl`, `gnome-calculator` | Only with the Hyprland config: what the terminal (`F9`), files (`SUPER`+`E`), media keys and calculator (`F12`) binds launch |

Building those three also pulls in their build tools (`build-essential`,
`cmake`, `ninja-build`, the `qt6-*-dev` and `*-private-dev` headers, `cargo`,
and so on). They're only installed when something actually needs building.

### Optional

On Ubuntu, each group is asked about separately, with skip as the default. Leave one out and only its own feature
goes missing, and the shell says so where that feature appears.

| Group | Packages | Backs |
| --- | --- | --- |
| `capture` | `grim`, `swappy`, `wf-recorder`, `ffmpeg`, `imagemagick`, `hyprpicker`, `tesseract-ocr`, `tesseract-ocr-eng`, `python3-pil`, `python3-numpy`, `python3-fonttools` | Screenshots, recording, the colour picker, and OCR in Text mode, with emoji. Add `tesseract-ocr-<lang>` and set `ocrLang` in `lucidshot/Screenshot.qml` for another language |
| `clipboard` | `cliphist`, `wtype` | Clipboard history in the launcher, and typing emoji and GIFs into the focused window |
| `media` | `cava`, `songrec` | Audio visualisers, and song identification. `songrec` comes from its author's PPA, `ppa:marin-m/songrec` |
| `system` | `hypridle`, `accountsservice`, `gir1.2-accountsservice-1.0`, `python3-gi`, `qt6ct`, `xdg-desktop-portal-gtk`, `librsvg2-bin`, `zenity` | The Idle page (dim, lock, screen off, suspend), the Users and Accounts page, the Environment page's Qt half and file portal, turning the cursor shadow off, and the file picker for avatars and wallpapers |
| `phone` | `kdeconnect`, `python3-gi` | The KDE Connect page |
| `pywal` | `pipx`, `imagemagick`, then `pywal16` (the maintained fork of pywal, pinned) via pipx | The Pywal theme. `wal` lands in `~/.local/bin`, which Ubuntu adds to your `PATH` at login |
| `look` | `fish`, `starship`, `fonts-jetbrains-mono`, `papirus-icon-theme`, plus **JetBrainsMono Nerd Font** and **adw-gtk3** from pinned, checksum-verified GitHub releases into `~/.local/share` | The look: the shell kitty opens, the prompt and its glyphs, the `adw-gtk3-dark` GTK theme, and the icons FairyWren inherits from. The FairyWren icons themselves are fetched at a pinned commit when the look is applied |
| `apps` | `flatpak`, then from Flathub (per user): Zen, VSCodium, Vesktop, Spotify, Proton VPN, Steam | The apps the dock ships pinned. Several GB. Anything you already have some other way — a deb, a snap, a vendor repo — is left alone |

Lucid uses Hyprland-specific APIs for workspaces and window management. It
will not work on other compositors. On Ubuntu, pick **Hyprland** from the
session menu on the login screen.

### Fonts

The default UI font is **Google Sans**, which is not in Ubuntu's archive. If you
don't have it, Qt falls back to your default sans and everything still works —
or pick any installed font in Settings → General.

## Uninstall

```sh
./support/ubuntu/uninstall.sh
```

Replays the install record in `~/.local/state/lucid` (or `$XDG_STATE_HOME/lucid`
inside your home). It shows a removal/restoration summary and asks before
proceeding. Keep the original checkout and this state directory until removal
finishes.

- **Files and settings:** restores saved configuration, GTK settings (including
  GTK2), gsettings values/defaults, user service enablement/activity, and recorded
  account details. Removes recorded shell files, wallpapers and runtime-imported
  wallpapers/cursor variants. Existing `/usr/local` payloads and SDDM theme files
  are backed up before replacement and restored. Quickshell's `qs` symlink is
  recorded even though CMake's install manifest omits it.
- **Packages:** removes only recorded APT additions that APT considers unused;
  it never runs a global autoremove. Packages needed by other software are
  retained and reported. Removes recorded per-user Flatpaks, newly installed
  runtime refs, pipx packages and editor extensions. Existing unrelated runtimes
  and software are preserved. PPA source/signing-key changes are restored from
  file snapshots. The installer refuses system-package upgrades/removals rather
  than promising that arbitrary version changes can be undone.
- **Recovery:** a failed restore/removal returns a nonzero status and retains
  originals and progress. Fix the reported issue and rerun `./support/ubuntu/uninstall.sh`;
  already-restored files are not overwritten again. Reinstall is blocked while
  an uninstall is pending. `--keep-packages` restores files/settings and retains
  the package record for a later full uninstall.

Before removal, a private archive is written to
`~/lucid-uninstall-<timestamp>.tar.gz`, including the state/originals and affected
system payloads. An archive failure stops deletion. `--no-archive` explicitly
skips this recovery copy. The archive itself is intentionally retained.

Dock-app data (browser profiles, logins and game saves) is preserved by default.
For removal **including that app data**, use:

```sh
./support/ubuntu/uninstall.sh --delete-app-data
```

The app data is included in the archive before deletion. To leave neither an
archive nor app data, explicitly choose both `--delete-app-data --no-archive`.
The source checkout, your own documents/screenshots, unrelated applications,
and shared package-manager caches are not deleted. Configuration paths managed
as whole directories return to their pre-install snapshots; later personal
edits in them are recoverable from the uninstall archive.

Passwords and account creation/deletion cannot be reversed from this record.
Administrative account changes are reported for manual restoration. If you
manually selected Lucid as your SDDM greeter, select your previous theme before
removing the active theme. A pre-journal install or legacy PPA record cannot
prove its original state: the uninstaller reports this rather than guessing or
silently claiming a complete restore. Symlinked config ancestors are rejected
because writes through them cannot be safely reversed from a link snapshot.

Validation commands and limitations are in
[installation-validation.md](installation-validation.md).
