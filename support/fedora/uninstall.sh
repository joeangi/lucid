#!/usr/bin/env bash
# Fedora uses the same non-journaled removal steps as the upstream Arch shell.
# Keep its own command so Fedora-specific cleanup can be added here.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/uninstall.sh" "$@"
