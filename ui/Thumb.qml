import QtQuick

// One square in the grid. Shows the cached thumbnail, a play badge with the
// duration for videos, a LIVE badge for Live Photos and a person top-right
// for items from the iCloud Shared Library.
Rectangle {
  id: root

  required property var theme
  property var item: null
  property int index: -1
  // Real, not int: the grid divides the row between its tiles and the result
  // rarely lands on a whole pixel.
  property real size: 176
  property bool selected: false
  property bool checked: false
  property bool downloading: false
  property bool syncing: false

  signal clicked(int modifiers)
  signal contextMenuRequested(real x, real y)
  signal menuRequested(real x, real y)
  signal favoriteRequested()

  width: size
  height: size
  radius: 6
  color: theme.darkBackground
  border.width: (selected || checked) ? 3 : 0
  border.color: selected ? theme.accent : Qt.darker(theme.accent, 1.4)
  HoverHandler { id: tileHover }

  Image {
    id: thumbnail
    anchors.fill: parent
    anchors.margins: (root.selected || root.checked) ? 3 : 0
    source: item && item.thumb ? "file://" + item.thumb : ""
    asynchronous: true
    fillMode: Image.PreserveAspectCrop
    sourceSize.width: 400
    sourceSize.height: 400
    smooth: true
  }

  Item {
    anchors.centerIn: parent
    visible: thumbnail.status !== Image.Ready
    width: 76; height: 62
    Rectangle {
      x: 7; y: 3; width: 54; height: 43; radius: 5
      color: "transparent"; border.color: root.theme.darkForeground; border.width: 4
    }
    Rectangle {
      x: 22; y: 16; width: 54; height: 43; radius: 5
      color: root.theme.darkBackground
      border.color: root.theme.foreground; border.width: 4
      Text {
        anchors.centerIn: parent
        text: "\uf03e"
        color: root.theme.foreground
        font.family: root.theme.fontFamily
        font.pixelSize: 25
      }
    }
  }

  Rectangle {
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: 8
    visible: !!item && item.state !== undefined && (root.downloading || item.state === "failed")
    width: stateLabel.implicitWidth + 12
    height: 20
    radius: 4
    color: Qt.rgba(0, 0, 0, 0.7)
    Text {
      id: stateLabel
      anchors.centerIn: parent
      text: item ? (root.downloading ? "Downloading" : "Failed") : ""
      color: "white"
      font.family: theme.fontFamily
      font.pixelSize: 10
    }
  }

  function fmtDuration(s) {
    s = Math.round(s || 0);
    var m = Math.floor(s / 60);
    var r = s % 60;
    return m + ":" + (r < 10 ? "0" : "") + r;
  }

  Rectangle {
    visible: !!item && item.kind === "video"
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    anchors.margins: 8
    width: durationText.visible ? durationText.implicitWidth + 22 : 22
    height: 22
    radius: 4
    color: Qt.rgba(0, 0, 0, 0.6)
    Row {
      anchors.centerIn: parent
      spacing: 5
      Text {
        text: ""
        color: "white"
        font.family: theme.fontFamily
        font.pixelSize: 9
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        id: durationText
        visible: !!item && item.duration > 0
        text: visible ? root.fmtDuration(item.duration) : ""
        color: "white"
        font.family: theme.fontFamily
        font.pixelSize: 11
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  // Live Photo mark, the same circle the phone shows top-left.
  Row {
    visible: !!item && item.kind === "live"
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.margins: 8
    spacing: 5
    Rectangle {
      width: 20; height: 20; radius: 10
      color: Qt.rgba(0, 0, 0, 0.5)
      border.color: "white"
      border.width: 2
      Rectangle {
        x: 7; y: 7
        width: 6; height: 6; radius: 3
        color: "white"
      }
    }
  }

  // Shared Library mark: a person top-right, the way the Photos app puts
  // it. Steps aside for the check mark when the item is ticked.
  Rectangle {
    visible: !!item && item.shared === true
    anchors.left: parent.left
    anchors.leftMargin: item && item.kind === "live" ? 36 : 8
    anchors.top: parent.top
    anchors.topMargin: 8
    width: 22; height: 22; radius: 11
    color: Qt.rgba(0, 0, 0, 0.5)
    border.color: "white"
    border.width: 1.5
    Text {
      anchors.centerIn: parent
      text: "\uf007"
      color: "white"
      font.family: theme.fontFamily
      font.pixelSize: 10
    }
  }

  // Check mark for items in a multi-selection.
  Rectangle {
    id: check
    visible: root.checked
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.margins: 8
    width: 22; height: 22; radius: 11
    color: theme.accent
    Text {
      anchors.centerIn: parent
      text: "\uf00c"
      color: theme.darkerBackground
      font.family: theme.fontFamily
      font.pixelSize: 11
      font.bold: true
    }
  }

  MouseArea {
    id: cardArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: mouse => {
      if (mouse.button === Qt.RightButton) root.contextMenuRequested(mouse.x, mouse.y);
      else root.clicked(mouse.modifiers);
    }
  }

  Item {
    visible: tileHover.hovered && !!item && item.state !== undefined && !root.checked
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    anchors.leftMargin: 5
    anchors.bottomMargin: item && item.kind === "video" ? 35 : 5
    width: 30; height: 30
    Text {
      anchors.centerIn: parent
      text: item && item.favorite === true ? "\uf004" : "\uf08a"
      color: "white"
      font.family: root.theme.fontFamily
      font.pixelSize: 17
      style: Text.Outline
      styleColor: root.theme.darkBackground
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.favoriteRequested()
    }
  }

  // A cloud mark means the full original is absent. Hover replaces it with
  // the same small actions control used by iCloud Photos.
  Item {
    visible: !!item && item.state !== undefined && !item.downloaded && !root.checked && !tileHover.hovered
    anchors.right: parent.right; anchors.top: parent.top
    anchors.margins: 8
    width: 24; height: 24
    Canvas {
      anchors.fill: parent
      onPaint: {
        var c = getContext("2d");
        c.clearRect(0, 0, width, height);
        c.beginPath();
        c.moveTo(5.5, 18.5);
        c.bezierCurveTo(1, 18.5, 1, 11.5, 6, 10.5);
        c.bezierCurveTo(7, 3, 17, 2, 19, 10);
        c.bezierCurveTo(25, 11, 24, 18.5, 19, 18.5);
        c.closePath();
        c.lineWidth = 2;
        c.strokeStyle = "white";
        c.stroke();
      }
    }
  }
  Rectangle {
    visible: tileHover.hovered && !root.checked
    anchors.right: parent.right; anchors.top: parent.top
    anchors.margins: 8
    width: 24; height: 24; radius: 12
    color: "white"
    Text {
      anchors.centerIn: parent
      text: "\uf141"
      color: root.theme.darkBackground
      font.family: root.theme.fontFamily
      font.pixelSize: 14
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.menuRequested(parent.x + width / 2, parent.y + height)
    }
  }
}
