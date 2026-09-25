// Pure geometry/policy helpers, also exercised by tests/test_visibility.cjs.
// Hyprland client positions and QScreen sizes use logical desktop coordinates.
function visibilityMode(value, legacyAutoHide) {
    if (value === "always" || value === "auto" || value === "dodge")
        return value;
    return legacyAutoHide ? "auto" : "always";
}

function intersects(a, b) {
    return a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0
        && a.x < b.x + b.width && a.x + a.width > b.x
        && a.y < b.y + b.height && a.y + a.height > b.y;
}

function visibleClient(client, monitors) {
    if (!client || client.mapped === false || client.hidden === true || !client.workspace)
        return false;
    var monitor = monitors.find(function(m) { return m.id === client.monitor; });
    if (!monitor)
        return false;
    var workspace = client.workspace.id;
    // A special workspace must actually be open, even for a pinned client.
    if (workspace < 0)
        return workspace === monitor.specialWorkspace;
    return client.pinned === true || workspace === monitor.activeWorkspace;
}

function overlaps(clients, monitors, rectangles) {
    return clients.some(function(client) {
        if (!visibleClient(client, monitors) || !client.at || !client.size)
            return false;
        var bounds = { x: client.at[0], y: client.at[1], width: client.size[0], height: client.size[1] };
        return rectangles.some(function(rect) { return intersects(bounds, rect); });
    });
}

function wantsReveal(mode, overlapping, hovered, busy) {
    return mode === "always" || hovered || busy || (mode === "dodge" && !overlapping);
}
