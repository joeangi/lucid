pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs
import "VisibilityLogic.js" as Logic

Singleton {
    id: root

    readonly property bool enabled: Prefs.loaded && Monitors.surfacesUp
        && ((Prefs.barEnabled && Prefs.barVisibilityMode === "dodge")
            || (Prefs.dockEnabled && Prefs.dockVisibilityMode === "dodge"))
    readonly property var clients: Hyprland.toplevels.values.map(t => t.lastIpcObject)
    readonly property var monitors: Hyprland.monitors.values.map(m => ({
        id: m.id,
        activeWorkspace: m.activeWorkspace ? m.activeWorkspace.id : 0,
        specialWorkspace: m.lastIpcObject && m.lastIpcObject.specialWorkspace ? m.lastIpcObject.specialWorkspace.id : 0
    }))

    function overlaps(screen, rectangles) {
        if (!root.enabled || !screen)
            return false;
        const monitor = Hyprland.monitorFor(screen);
        if (!monitor)
            return false;
        const globalRects = rectangles.map(r => ({
            x: monitor.x + r.x, y: monitor.y + r.y, width: r.width, height: r.height
        }));
        return Logic.overlaps(root.clients, root.monitors, globalRects);
    }

    function refresh() {
        if (!root.enabled)
            return;
        Hyprland.refreshToplevels();
        Hyprland.refreshMonitors();
    }

    onEnabledChanged: if (enabled) refresh()
    Component.onCompleted: refresh()

    // Client geometry has no continuous move/resize event. Keep refreshing even
    // when both surfaces are hidden, so they reappear when the obstruction moves.
    Timer {
        interval: 150
        running: root.enabled
        repeat: true
        onTriggered: root.refresh()
    }

    Timer {
        id: eventRefresh
        interval: 16
        onTriggered: root.refresh()
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (root.enabled && /^(openwindow|closewindow|movewindow|workspace|focusedmon|activespecial|fullscreen|changefloatingmode|monitoradded|monitorremoved|configreloaded)/.test(event.name))
                eventRefresh.restart();
        }
    }
}
