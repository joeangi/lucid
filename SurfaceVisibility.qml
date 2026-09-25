import QtQuick
import "VisibilityLogic.js" as Logic

// Shared hide delay lets the pointer cross a floating surface's edge gap and
// avoids flickering as windows move along its boundary. Reveals are immediate.
QtObject {
    id: root
    property string mode: "always"
    property bool overlapping: false
    property bool hovered: false
    property bool busy: false
    property bool revealed: true
    readonly property bool wanted: Logic.wantsReveal(mode, overlapping, hovered, busy)

    function sync() {
        if (wanted) {
            hideDelay.stop();
            revealed = true;
        } else {
            hideDelay.restart();
        }
    }
    onWantedChanged: sync()
    Component.onCompleted: sync()

    property Timer hideDelay: Timer {
        interval: 180
        onTriggered: root.revealed = root.wanted
    }
}
