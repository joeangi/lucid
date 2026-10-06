# Fedora installation

Use a conventional DNF-based Fedora installation with Hyprland 0.55 or newer.
Fedora Atomic desktops need manual setup. Lucid uses Hyprland-specific APIs;
log into a Hyprland session before launching it.

Clone this fork into a separate directory and keep the checkout for updates:

```sh
git clone https://github.com/joeangi/lucid.git
cd lucid
./support/fedora/install.sh
```

Check installed dependencies without changing the system first:

```sh
./support/fedora/install.sh --check
```

The check exits unsuccessfully if a required package is missing. It also lists
missing feature packages and dock apps. It does not test the graphical session
or whether missing packages are available in enabled repositories.

The Fedora installer uses only your enabled DNF repositories. It checks for
Quickshell and the Fedora Qt packages (`qt6-qt5compat`, `qt6-qtdeclarative`,
`qt6-qtmultimedia`), then lists unavailable optional packages and dock apps
without enabling another repository. `--no-apps` skips the dock apps;
`--skip-deps` avoids package installation, but still installs Lucid and changes
configuration. Run
`./support/fedora/install.sh --help` for all supported options.

## Uninstall

```sh
./support/fedora/uninstall.sh
```

The Fedora uninstaller uses the existing non-journaled cleanup flow. It offers
to move the installed shell aside and remove Lucid's theming directory. It
leaves installed packages, Hyprland configuration, wallpapers, and other
settings for manual review. This differs from Ubuntu's journaled restoration.
