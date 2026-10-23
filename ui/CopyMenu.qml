import QtQuick
import QtQuick.Controls.Basic

Menu {
  id: root
  required property var theme
  property var items: []
  property bool inAlbum: false
  signal requestCopy(var items)
  signal requestEvict(var items)
  signal requestDownload(var items)
  signal requestKeepOffline(var items)
  signal requestSave(var items)
  signal requestOpen()
  signal requestSlideshow(var items)
  signal requestDelete()
  signal requestAddToAlbum(var items)
  signal requestRemoveFromAlbum(var items)

  width: 300
  padding: 5
  margins: 6
  popupType: Popup.Item
  modal: true
  dim: false
  background: Rectangle {
    radius: 9
    color: root.theme.darkBackground
    border.color: root.theme.lighterBackground
    border.width: 1
  }

  ActionMenuItem {
    theme: root.theme; glyph: "\uf019"
    text: root.items.length > 1 ? "Download " + root.items.length + " originals" : "Download Original"
    enabled: root.items.some(function (it) { return !it.downloaded; })
    onTriggered: root.requestDownload(root.items)
  }
  ActionMenuItem {
    theme: root.theme; glyph: "\uf0c7"
    text: root.items.length > 1 ? "Keep selected originals offline" : "Keep Original Offline"
    enabled: root.items.some(function (it) { return it.downloaded && !it.keptOffline; })
    onTriggered: root.requestKeepOffline(root.items)
  }
  ActionMenuItem {
    theme: root.theme; glyph: "\uf14d"
    text: root.items.length > 1 ? "Save " + root.items.length + " copies…" : "Save Copy…"
    enabled: root.items.length > 0
    onTriggered: root.requestSave(root.items)
  }
  MenuSeparator {}
  ActionMenuItem {
    id: copyItem
    theme: root.theme; glyph: "\uf0c5"
    text: root.items.length > 1 ? "Copy " + root.items.length + " files" : "Copy"
    enabled: root.items.length > 0
    onTriggered: root.requestCopy(root.items)
    Shortcut {
      sequence: "Ctrl+C"
      enabled: root.visible && copyItem.enabled
      onActivated: { root.requestCopy(root.items); root.close(); }
    }
  }
  ActionMenuItem {
    theme: root.theme; glyph: "\uf08e"; text: "Open Externally"
    enabled: root.items.length === 1
    onTriggered: root.requestOpen()
  }
  ActionMenuItem {
    theme: root.theme; glyph: "\uf144"; text: "Start Slideshow"
    enabled: root.items.length > 0
    onTriggered: root.requestSlideshow(root.items)
  }
  ActionMenuItem {
    theme: root.theme; glyph: "\uf07c"; text: "Add to Album…"
    enabled: root.items.length > 0 && root.items.length <= 100
    onTriggered: root.requestAddToAlbum(root.items)
  }
  ActionMenuItem {
    theme: root.theme; glyph: "\uf068"; text: "Remove from Album"
    visible: root.inAlbum
    enabled: root.inAlbum && root.items.length > 0 && root.items.length <= 100
    onTriggered: root.requestRemoveFromAlbum(root.items)
  }
  MenuSeparator {}
  ActionMenuItem {
    theme: root.theme; glyph: "\uf2ed"
    text: "Remove local download — keep in iCloud"
    enabled: root.items.some(function (it) { return it.evictable === true; })
    onTriggered: root.requestEvict(root.items)
  }
  MenuSeparator {}
  ActionMenuItem {
    theme: root.theme; glyph: "\uf1f8"; danger: true
    text: "Delete from iCloud…"
    enabled: root.items.length > 0
    onTriggered: root.requestDelete()
  }
}
