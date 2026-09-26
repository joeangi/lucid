import QtQuick as QtQuick

// Match editable text to the rendering used by the shell's Text primitive.
QtQuick.TextInput {
    renderType: QtQuick.Text.NativeRendering
    font.hintingPreference: QtQuick.Font.PreferVerticalHinting
}
