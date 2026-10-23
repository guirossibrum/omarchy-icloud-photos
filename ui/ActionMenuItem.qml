import QtQuick
import QtQuick.Controls.Basic

MenuItem {
  id: root
  required property var theme
  property string glyph: ""
  property bool danger: false
  implicitHeight: 36
  background: Rectangle {
    radius: 5
    color: root.highlighted ? root.theme.selection : "transparent"
  }
  contentItem: Row {
    spacing: 12
    Text {
      width: 20
      anchors.verticalCenter: parent.verticalCenter
      text: root.glyph
      color: root.enabled ? (root.danger ? root.theme.red : root.theme.accent) : root.theme.darkForeground
      font.family: root.theme.fontFamily
      font.pixelSize: 15
      horizontalAlignment: Text.AlignHCenter
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: root.text
      color: root.enabled ? (root.danger ? root.theme.red : root.theme.brightForeground) : root.theme.darkForeground
      font.family: root.theme.fontFamily
      font.pixelSize: root.theme.fontSize
    }
  }
}
