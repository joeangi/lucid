const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const logic = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../VisibilityLogic.js'), 'utf8'), logic);

const monitors = [
    { id: 0, activeWorkspace: 1, specialWorkspace: -99 },
    { id: 1, activeWorkspace: 3, specialWorkspace: 0 },
];
const dock = [{ x: 600, y: 1000, width: 700, height: 60 }];
const client = (changes = {}) => ({
    mapped: true, hidden: false, monitor: 0, workspace: { id: 1 },
    at: [700, 900], size: [300, 150], ...changes,
});
const overlaps = (c, rectangles = dock) => logic.overlaps([c], monitors, rectangles);

test('legacy auto-hide migrates only when no valid new choice exists', () => {
    assert.equal(logic.visibilityMode('', true), 'auto');
    assert.equal(logic.visibilityMode('', false), 'always');
    for (const mode of ['always', 'auto', 'dodge'])
        assert.equal(logic.visibilityMode(mode, true), mode);
    assert.equal(logic.visibilityMode('invalid', false), 'always');
});
test('only geometric overlap hides a surface; touching an edge does not', () => {
    assert.equal(overlaps(client()), true);
    assert.equal(overlaps(client({ at: [700, 850] })), false);
    assert.equal(overlaps(client({ at: [1300, 900] })), false);
    assert.equal(overlaps(client({ at: [700, 1060] })), false);
    assert.equal(overlaps(client({ size: [0, 150] })), false);
});
test('hidden, unmapped and unknown geometry are excluded', () => {
    for (const changes of [{ hidden: true }, { mapped: false }, { at: null }, { size: null }, { workspace: null }, { monitor: 99 }])
        assert.equal(overlaps(client(changes)), false);
    assert.equal(overlaps(null), false);
});
test('inactive workspaces cannot obstruct; pinned regular windows can', () => {
    assert.equal(overlaps(client({ workspace: { id: 2 } })), false);
    assert.equal(overlaps(client({ workspace: { id: 2 }, pinned: true })), true);
});
test('special workspace windows count only while that special workspace is open', () => {
    assert.equal(overlaps(client({ workspace: { id: -99 } })), true);
    assert.equal(overlaps(client({ workspace: { id: -98 } })), false);
    assert.equal(overlaps(client({ workspace: { id: -98 }, pinned: true })), false);
});
test('a monitor uses its own visible workspace, independently of keyboard focus', () => {
    assert.equal(overlaps(client({ monitor: 1, workspace: { id: 3 } })), true);
    assert.equal(overlaps(client({ monitor: 1, workspace: { id: 1 } })), false);
});
test('negative monitor origins and logical scaled coordinates are preserved', () => {
    const rects = [{ x: -1500, y: -500, width: 500, height: 60 }];
    assert.equal(overlaps(client({ at: [-1400, -600], size: [250, 130] }), rects), true);
    assert.equal(overlaps(client({ at: [-1400, -600], size: [250, 80] }), rects), false);
});
test('a window spanning outputs can obstruct both surfaces', () => {
    const c = client({ at: [1200, 900], size: [1000, 180] });
    assert.equal(overlaps(c), true);
    assert.equal(overlaps(c, [{ x: 1920, y: 1000, width: 400, height: 60 }]), true);
});
test('bar gaps do not hide modules, but fullscreen geometry does', () => {
    const bar = [{ x: 0, y: 10, width: 300, height: 40 }, { x: 800, y: 10, width: 300, height: 40 }];
    assert.equal(overlaps(client({ at: [400, 0], size: [300, 500] }), bar), false);
    assert.equal(overlaps(client({ at: [0, 0], size: [1920, 1080], fullscreen: 2 }), bar), true);
});
test('mode policy prioritizes pointer and interaction holds', () => {
    for (const mode of ['always', 'auto', 'dodge']) {
        assert.equal(logic.wantsReveal(mode, true, true, false), true);
        assert.equal(logic.wantsReveal(mode, true, false, true), true);
    }
    assert.equal(logic.wantsReveal('always', true, false, false), true);
    assert.equal(logic.wantsReveal('auto', false, false, false), false);
    assert.equal(logic.wantsReveal('dodge', false, false, false), true);
    assert.equal(logic.wantsReveal('dodge', true, false, false), false);
});
