# Installation and restoration validation

Run from the checkout:

```sh
bash -n install.sh uninstall.sh support/install-state.sh
python3 -m unittest discover -s tests -v
./install.sh --check
```

The regression suite uses temporary homes and mocked package, privilege and
session commands. It covers fresh install/remove, repeated installation with
original configuration, missing backups, failed settings restoration and retry,
archive failure and private permissions, package-removal scope and retained
manual marks, runtime-created assets, pre-existing system payload backup,
CMake-created symlink tracking, path containment, and source consent.

On the inspected Ubuntu 26.04 host, Qt's candidate is 6.10.2. The read-only
preflight finds the required archive package candidates but reports missing
Hyprland >= 0.55, Quickshell, matugen and awww/swww executables. This is an
expected readiness failure, not a completed desktop installation.

A real privileged package installation, third-party build/download, login,
rendering, locking, audio/network session and package-manager rollback have
not been validated on a disposable Ubuntu VM. Run those acceptance checks on
a fresh Ubuntu 26.04 VM and a VM with an existing desktop configuration before
claiming end-to-end compatibility. ShellCheck was unavailable locally and its
package download failed because the sandbox could not resolve the archive host.

Quickshell v0.3.1 requires Qt >= 6.6; Ubuntu 24.04's stock Qt 6.4 is rejected
before state/config changes. Source references:

- https://github.com/quickshell-mirror/quickshell/blob/v0.3.1/CMakeLists.txt
- https://packages.ubuntu.com/noble/libqt6core6t64

Exact restoration has explicit boundaries: unrelated user data and shared
package caches are preserved; passwords/account creation/deletion cannot be
reversed. Packages now required elsewhere remain installed with the recovery
journal retained. Old unjournalled installations require manual recovery.
