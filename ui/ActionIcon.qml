import QtQuick
import QtQuick.Controls.Basic

Rectangle {
  id: root
  required property var theme
  property string icon: ""
  property string hint: ""
  property bool available: true
  signal activated()

  width: 32; height: 32; radius: 6
  color: hit.containsMouse && available ? theme.lighterBackground : "transparent"
  Text {
    anchors.centerIn: parent
    text: root.icon
    color: root.available ? root.theme.accent : root.theme.darkForeground
    font.family: root.theme.fontFamily
    font.pixelSize: 16
  }
  MouseArea {
    id: hit
    anchors.fill: parent
    hoverEnabled: true
    enabled: root.available
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
  ToolTip.visible: hit.containsMouse && hint.length > 0
  ToolTip.text: hint
  ToolTip.delay: 500
}
