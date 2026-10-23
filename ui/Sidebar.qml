import QtQuick

Rectangle {
  id: root
  required property var theme
  property string section: "library"
  property bool expanded: true
  property bool mediaExpanded: true
  property bool albumsExpanded: true
  property var albumRows: []
  property var expandedFolders: ({})
  signal sectionSelected(string section)
  signal toggleRequested()
  function visibleAlbums() {
    var rows = [];
    for (var i = 0; i < albumRows.length; i++) {
      var row = albumRows[i], parent = row.parent, visible = true, hops = 0;
      while (parent && hops++ < albumRows.length) {
        if (expandedFolders[parent] !== true) { visible = false; break; }
        var ancestor = albumRows.find(function (entry) { return entry.id === parent; });
        parent = ancestor ? ancestor.parent : null;
      }
      if (visible) rows.push(row);
    }
    return rows;
  }
  function toggleFolder(id) {
    var next = Object.assign({}, expandedFolders);
    next[id] = next[id] !== true;
    expandedFolders = next;
  }
  function revealSelection(section) {
    var split = section.indexOf(":");
    if (split < 0) return;
    var id = section.slice(split + 1);
    var next = Object.assign({}, expandedFolders);
    var row = albumRows.find(function (entry) { return entry.id === id; });
    if (!row) return;
    if (row.isFolder) next[row.id] = true;
    var parent = row.parent, hops = 0;
    while (parent && hops++ < albumRows.length) {
      next[parent] = true;
      var ancestor = albumRows.find(function (entry) { return entry.id === parent; });
      parent = ancestor ? ancestor.parent : null;
    }
    expandedFolders = next;
  }
  onSectionChanged: revealSelection(section)
  onAlbumRowsChanged: revealSelection(section)

  color: theme.darkBackground
  readonly property var photoRows: [
    { key: "library", label: "Library", icon: "\uf03e" },
    { key: "favorites", label: "Favorites", icon: "\uf004" },
    { key: "recents", label: "Recents", icon: "\uf017" },
    { key: "downloaded", label: "Downloaded", icon: "\uf019" }
  ]
  readonly property var mediaRows: [
    { key: "videos", label: "Videos", icon: "\uf03d" },
    { key: "live", label: "Live Photos", icon: "\uf1ce" }
  ]

  Rectangle {
    anchors.right: parent.right
    width: 1
    height: parent.height
    color: theme.lighterBackground
  }

  Rectangle {
    id: toggle
    x: 11; y: 8; width: 30; height: 28; radius: 5
    color: toggleArea.containsMouse ? theme.lighterBackground : "transparent"
    Text {
      anchors.centerIn: parent
      text: "\uf0db"
      color: theme.accent
      font.family: theme.fontFamily
      font.pixelSize: 16
    }
    MouseArea {
      id: toggleArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleRequested()
    }
  }

  Flickable {
    visible: root.expanded
    anchors.top: toggle.bottom
    anchors.topMargin: 13
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    clip: true
    contentWidth: width
    contentHeight: body.implicitHeight + 24
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: body
      width: parent.width
      spacing: 3

      Text {
        x: 17
        height: 25
        text: "Photos"
        color: theme.foreground
        font.family: theme.fontFamily
        font.pixelSize: theme.fontSize - 1
      }
      Repeater {
        model: root.photoRows
        delegate: SidebarEntry {
          required property var modelData
          theme: root.theme
          label: modelData.label
          icon: modelData.icon
          selected: root.section === modelData.key
          onActivated: root.sectionSelected(modelData.key)
        }
      }

      Item { width: 1; height: 16 }
      Text {
        x: 17
        height: 25
        text: "Collections"
        color: theme.foreground
        font.family: theme.fontFamily
        font.pixelSize: theme.fontSize - 1
      }
      Rectangle {
        x: 8; width: parent.width - 16; height: 33; radius: 7
        color: root.section === "albums" ? Qt.lighter(theme.darkBackground, 1.55) :
               albumsArea.containsMouse ? Qt.lighter(theme.darkBackground, 1.25) : "transparent"
        Text { x: 8; anchors.verticalCenter: parent.verticalCenter; text: root.albumsExpanded ? "⌄" : "›"; color: theme.darkForeground; font.pixelSize: 16 }
        Text { x: 39; anchors.verticalCenter: parent.verticalCenter; text: "\uf07b"; color: theme.accent; font.family: theme.fontFamily; font.pixelSize: 16 }
        Text { x: 70; anchors.verticalCenter: parent.verticalCenter; text: "Albums"; color: theme.brightForeground; font.family: theme.fontFamily; font.pixelSize: theme.fontSize }
        MouseArea { id: albumsArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.sectionSelected("albums") }
        MouseArea { x: 0; width: 31; height: parent.height; cursorShape: Qt.PointingHandCursor; onClicked: root.albumsExpanded = !root.albumsExpanded }
      }
      Repeater {
        model: root.albumsExpanded ? root.visibleAlbums() : []
        delegate: SidebarEntry {
          required property var modelData
          theme: root.theme
          label: modelData.title
          icon: modelData.isFolder ? "\uf07b" : "\uf03e"
          thumbnail: modelData.isFolder ? "" : (modelData.cover || "")
          indent: 16 + Math.min(modelData.depth || 0, 7) * 13
          expandable: modelData.isFolder
          expanded: root.expandedFolders[modelData.id] === true
          selected: root.section === (modelData.isFolder ? "folder:" : "album:") + modelData.id
          onExpansionRequested: root.toggleFolder(modelData.id)
          onActivated: {
            var section = (modelData.isFolder ? "folder:" : "album:") + modelData.id;
            root.revealSelection(section);
            root.sectionSelected(section);
          }
        }
      }
      Rectangle {
        x: 8; width: parent.width - 16; height: 33; radius: 7
        color: mediaArea.containsMouse ? Qt.lighter(theme.darkBackground, 1.25) : "transparent"
        Text {
          x: 8
          anchors.verticalCenter: parent.verticalCenter
          text: root.mediaExpanded ? "⌄" : "›"
          color: theme.darkForeground
          font.family: theme.fontFamily
          font.pixelSize: 16
        }
        Text {
          x: 39
          anchors.verticalCenter: parent.verticalCenter
          text: "\uf07b"
          color: theme.accent
          font.family: theme.fontFamily
          font.pixelSize: 16
        }
        Text {
          x: 70
          anchors.verticalCenter: parent.verticalCenter
          text: "Media Types"
          color: theme.brightForeground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize
        }
        MouseArea {
          id: mediaArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.mediaExpanded = !root.mediaExpanded
        }
      }
      Repeater {
        model: root.mediaExpanded ? root.mediaRows : []
        delegate: SidebarEntry {
          required property var modelData
          theme: root.theme
          label: modelData.label
          icon: modelData.icon
          indent: 16
          selected: root.section === modelData.key
          onActivated: root.sectionSelected(modelData.key)
        }
      }

      Item { width: 1; height: 16 }
      Text {
        x: 17
        height: 25
        text: "Sharing"
        color: theme.foreground
        font.family: theme.fontFamily
        font.pixelSize: theme.fontSize - 1
      }
      SidebarEntry {
        theme: root.theme
        label: "Shared Library"
        icon: "\uf0c0"
        selected: root.section === "shared"
        onActivated: root.sectionSelected("shared")
      }
    }
  }
}
