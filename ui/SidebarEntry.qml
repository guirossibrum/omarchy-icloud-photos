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
  property bool folderIcon: false
  signal activated()
  signal expansionRequested()

  width: parent ? parent.width - 16 : 208
  x: 8
  height: 33
  radius: 7
  color: selected ? "#414144" : area.containsMouse ? "#303034" : "transparent"

  Text {
    x: 16 + root.indent
    visible: root.expandable
    anchors.verticalCenter: parent.verticalCenter
    text: root.expanded ? "⌄" : "›"
    color: "#909095"
    font.pixelSize: 15
  }
  Text {
    x: 16 + root.indent + (root.expandable ? 17 : 0)
    visible: !root.thumbnail && !root.folderIcon
    anchors.verticalCenter: parent.verticalCenter
    width: 23
    text: root.icon
    color: "#00aaff"
    font.family: root.theme.fontFamily
    font.pixelSize: 16
  }
  Canvas {
    x: 16 + root.indent + (root.expandable ? 17 : 0)
    anchors.verticalCenter: parent.verticalCenter
    width: 21; height: 21
    visible: root.folderIcon && !root.thumbnail
    onPaint: {
      var c = getContext("2d");
      c.clearRect(0, 0, width, height);
      c.strokeStyle = "#00aaff";
      c.lineWidth = 1.55;
      c.lineJoin = "round";
      c.beginPath();
      c.moveTo(2.5, 5.5); c.lineTo(7.5, 5.5); c.lineTo(9, 3.5);
      c.lineTo(17.5, 3.5); c.lineTo(17.5, 6.5);
      c.moveTo(2.5, 8); c.lineTo(18.5, 8); c.lineTo(18.5, 17.5);
      c.lineTo(2.5, 17.5); c.closePath(); c.stroke();
    }
  }
  Rectangle {
    x: 16 + root.indent + (root.expandable ? 17 : 0)
    anchors.verticalCenter: parent.verticalCenter
    width: 23; height: 23; radius: 3
    visible: root.thumbnail !== ""
    color: "#303034"
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
    color: "#f5f5f7"
    font.family: "sans-serif"
    font.pixelSize: 14
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
