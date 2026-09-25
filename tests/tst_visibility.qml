import QtQuick
import QtTest
import ".." as Lucid

TestCase {
    name: "SurfaceVisibility"

    Component {
        id: factory
        Lucid.SurfaceVisibility {}
    }

    function make(properties) {
        const controller = createTemporaryObject(factory, this, properties || {});
        verify(controller !== null);
        return controller;
    }

    function test_dodgeClearsWhileHidden() {
        const c = make({mode: "dodge", overlapping: true});
        tryCompare(c, "revealed", false);
        c.overlapping = false;
        compare(c.revealed, true);
    }

    function test_edgeRevealAndLeave() {
        const c = make({mode: "auto"});
        tryCompare(c, "revealed", false);
        c.hovered = true;
        compare(c.revealed, true);
        c.hovered = false;
        compare(c.revealed, true); // grace period crossing the edge gap
        tryCompare(c, "revealed", false);
    }

    function test_popupAndDragHold() {
        const c = make({mode: "dodge", overlapping: true, busy: true});
        wait(230);
        compare(c.revealed, true);
        c.busy = false;
        tryCompare(c, "revealed", false);
    }

    function test_cancelPendingHide() {
        const c = make({mode: "dodge"});
        c.overlapping = true;
        wait(60);
        c.overlapping = false;
        wait(230);
        compare(c.revealed, true);
    }

    function test_switchModeWhileHidden() {
        const c = make({mode: "auto"});
        tryCompare(c, "revealed", false);
        c.mode = "always";
        compare(c.revealed, true);
        c.mode = "dodge";
        compare(c.revealed, true);
        c.overlapping = true;
        tryCompare(c, "revealed", false);
    }

    function test_independentSurfaces() {
        const dock = make({mode: "auto"});
        const bar = make({mode: "dodge"});
        tryCompare(dock, "revealed", false);
        compare(bar.revealed, true);
        dock.hovered = true;
        bar.overlapping = true;
        tryCompare(bar, "revealed", false);
        compare(dock.revealed, true);
    }
}
