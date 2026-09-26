# Dock and top-bar visibility

Settings → Dock → Behaviour and Settings → Bar → Opening behaviour each have
an independent **Visibility** selector:

- **Always visible** reserves space for the surface.
- **Auto-hide** hides it until the pointer reaches the matching screen edge.
- **Dodge windows** hides it only when a visible application window overlaps its
  resting rectangle. The top bar checks its individual modules, not the gaps.

Touch the top edge to reveal the bar, or the bottom edge beneath the dock to
reveal the dock. Hide modes reserve no space, including while temporarily
revealed. The edge remains accessible over fullscreen windows. Hovering or
using a menu, launcher, workspace overview, or dock drag keeps the surface open.
A short hide delay allows the pointer to cross floating margins.

Existing settings retain their behavior: the old `dockAutoHide` boolean is
migrated to `dockVisibility` on load. New installations start with both surfaces
always visible. The new persisted keys are `dockVisibility` and `barVisibility`,
with values `always`, `auto`, or `dodge`.

`WindowOverlap.qml` shares Hyprland snapshots between the two surfaces. It
refreshes every 150 ms while an enabled surface uses dodge mode, including while
hidden, plus immediately after relevant compositor events. Geometry is compared
in logical desktop coordinates. Only windows on visible workspaces count;
pinned windows and open special workspaces are included. Moving a window across
outputs can obstruct either output. The overlap rectangles do not move with the
hiding animation, avoiding repeated hide/show feedback.

## Automated checks

From the repository root:

```sh
node tests/test_visibility.cjs
python3 tests/test_visibility_migration.py
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  /usr/lib/qt6/bin/qmltestrunner -input tests/tst_visibility.qml
git diff --check
```

The JavaScript cases cover overlap, inactive/special workspaces, pinning,
multi-output coordinates, fullscreen geometry, and old-setting compatibility.
The QML cases exercise real hide timers, cancellation, interaction holds,
mode changes, and independent surfaces. The Python cases load the actual
Quickshell settings adapter in a temporary HOME, checking migration and reload
without changing the installed settings.

## Desktop acceptance

On a Hyprland session, verify both surfaces independently:

1. Switch among all three modes; only Always visible reserves space. Restart
   Quickshell and confirm the choices persist.
2. In Dodge windows, move and resize a floating window into and out of the
   surface. Check that moving it away reveals the surface without needing to
   touch the edge. Repeat with tiled and fullscreen windows.
3. Reveal at the edge and cross the floating margin. Open clock/system/tray
   menus and workspace overview; use the dock launcher, context menu, window
   picker, and drag reorder. They must remain usable until dismissed.
4. Switch regular and special workspaces. Windows on hidden workspaces must not
   hide the surface; pinned windows must continue to count.
5. Place bar and dock on different monitors. Check mixed scaling, rotated and
   negatively positioned outputs, window moves across outputs, and unplug/replug.
6. Repeat with island/notch styling, changed sizes/margins, disabled surfaces,
   and reduced motion. Hidden areas must not intercept application clicks.

Automated geometry tests do not replace checking actual input routing and
animations on a compositor, especially on monitor arrangements unavailable to
the developer.

### Verification on 2026-09-25

Passed 10 geometry/policy cases, 6 QML controller cases, and 3 real-settings
migration/reload cases. The full shell compiled against the installed Wayland
runtime and hot-reloaded successfully. On one 1920×1080 output at scale 1, the
Bar selector rendered correctly; Always visible retained the existing top/bottom
reservations (57/81 px), and Auto-hide and Dodge windows released both to zero.
Screen-edge captures confirmed both surfaces hid in those modes with overlapping
application windows. The live tracker read compositor clients and stopped when
neither surface used dodge. Original visibility choices were restored afterward.

Pointer-driven menu/drag journeys and physical multi-monitor, rotation, scaling,
and hotplug combinations remain manual acceptance checks.

### Hidden-bar blur regression

The initial edge-only captures missed a rendering regression: once the bar's
modules slid above its fullscreen host window, its attached blur effect could
blur application content across the screen while input still passed through.
The bar now clears `BackgroundEffect.blurRegion` before hiding and reattaches it
only when revealed, with its modules inside the window. Normal visible-bar blur
and edge-reveal input remain enabled.

A live striped-window comparison reproduced the issue: pixel contrast standard
deviation fell from 127.50 to 2.99 for bar Dodge windows and Auto-hide. With the
fix, all five tested bar/dock mode combinations retained 127.50. The installed
shell hot-reloaded the fix, and the check restored the original settings.

To repeat this compositor check explicitly (temporarily opens a synthetic test
window and changes visibility modes, restoring preferences afterward):

```sh
python3 tests/check_visibility_blur.py --live
```

Requires Hyprland, the installed Lucid shell, Quickshell, grim, and Pillow.
This check samples only the synthetic window's stripes, not other applications.
