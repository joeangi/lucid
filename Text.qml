import QtQuick as QtQuick

// Small desktop type is noticeably softer with Qt Quick's default
// distance-field renderer, especially after a fractional output scale.  Keep
// one rendering policy for every surface that imports `qs`; native rendering
// rasterises glyphs for the screen's real pixel density instead.
QtQuick.Text {
    renderType: QtQuick.Text.NativeRendering
    font.hintingPreference: QtQuick.Font.PreferVerticalHinting
}
