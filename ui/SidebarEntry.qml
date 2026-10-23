import QtQuick

Rectangle {
  id: root
  required property var theme
  property string label: ""
  property string icon: ""
  property bool selected: false
  property int indent: 0
  signal activated()

  width: parent ? parent.width - 16 : 208
  x: 8
  height: 33
  radius: 7
  color: selected ? Qt.lighter(theme.darkBackground, 1.55) :
         area.containsMouse ? Qt.lighter(theme.darkBackground, 1.25) : "transparent"

  Text {
    x: 16 + root.indent
    anchors.verticalCenter: parent.verticalCenter
    width: 23
    text: root.icon
    color: root.theme.accent
    font.family: root.theme.fontFamily
    font.pixelSize: 16
  }
  Text {
    x: 47 + root.indent
    anchors.verticalCenter: parent.verticalCenter
    width: root.width - x - 10
    elide: Text.ElideRight
    text: root.label
    color: root.theme.brightForeground
    font.family: root.theme.fontFamily
    font.pixelSize: root.theme.fontSize
  }
  MouseArea {
    id: area
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }
}
