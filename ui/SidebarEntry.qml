import QtQuick

Rectangle {
  id: root
  required property var theme
  property string label: ""
  property string icon: ""
  property bool selected: false
  property int indent: 0
  property bool expandable: false
  property bool expanded: false
  property string thumbnail: ""
  signal activated()
  signal expansionRequested()

  width: parent ? parent.width - 16 : 208
  x: 8
  height: 33
  radius: 7
  color: selected ? Qt.lighter(theme.darkBackground, 1.55) :
         area.containsMouse ? Qt.lighter(theme.darkBackground, 1.25) : "transparent"

  Text {
    x: 16 + root.indent
    visible: root.expandable
    anchors.verticalCenter: parent.verticalCenter
    text: root.expanded ? "⌄" : "›"
    color: root.theme.darkForeground
    font.pixelSize: 15
  }
  Text {
    x: 16 + root.indent + (root.expandable ? 17 : 0)
    visible: !root.thumbnail
    anchors.verticalCenter: parent.verticalCenter
    width: 23
    text: root.icon
    color: root.theme.accent
    font.family: root.theme.fontFamily
    font.pixelSize: 16
  }
  Rectangle {
    x: 16 + root.indent + (root.expandable ? 17 : 0)
    anchors.verticalCenter: parent.verticalCenter
    width: 23; height: 23; radius: 3
    visible: root.thumbnail !== ""
    color: root.theme.lighterBackground
    clip: true
    Image {
      anchors.fill: parent
      source: root.thumbnail ? "file://" + root.thumbnail : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
    }
  }
  Text {
    x: 47 + root.indent + (root.expandable ? 17 : 0)
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
  MouseArea {
    visible: root.expandable
    x: 8 + root.indent
    y: 0
    width: 25
    height: parent.height
    cursorShape: Qt.PointingHandCursor
    onClicked: root.expansionRequested()
  }
}
