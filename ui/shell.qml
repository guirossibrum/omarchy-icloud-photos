import QtQuick
import QtQuick.Controls.Basic
import Quickshell
import Quickshell.Io

// omarchy-icloud-photos: an iCloud Photos library in one window.
//
// All data comes from bin/omarchy-icloud-photos-sync, which writes index.json and
// status.json under ~/.cache/omarchy-icloud-photos. This file only renders them and
// can ask the script to run again. Nothing here writes to the library.
ShellRoot {
  id: root

  // The window runs straight out of the checkout, so every git operation on
  // it looks like an edit and Quickshell reloads and says so on screen. The
  // reload is welcome, the notification is not.
  Component.onCompleted: Quickshell.inhibitReloadPopup()

  readonly property string cacheDir:
    (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omarchy-icloud-photos"
  // Qt.resolvedUrl refuses to leave the shell directory (it returns
  // qrc:/qs-blackhole), so the scripts are found from shellDir instead.
  readonly property string binDir: Quickshell.shellDir + "/../bin"
  readonly property string syncScript: binDir + "/omarchy-icloud-photos-sync"
  readonly property string helperScript: binDir + "/omarchy-icloud-photos-helper"
  readonly property string catalogScript: binDir + "/omarchy-icloud-photos-catalog"
  readonly property string infoScript: binDir + "/omarchy-icloud-photos-info"
  readonly property string configPath:
    (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy-icloud-photos/config"

  property var items: []
  property var libraryItems: []
  property var days: []          // [{label, indices: [int]}]
  property string activeSection: "library"
  property var albumRows: []
  property var albumKeys: ({})
  property bool albumLoading: false
  property string searchText: ""
  property bool sidebarOpen: true
  property int calendarYear: new Date().getFullYear()
  property bool slideshowRunning: false
  property var slideshowIds: []
  property string prioritySignature: ""
  property int selected: -1
  onSelectedChanged: if (grid && !suppressReveal) grid.revealIndex(selected)
  // OMARCHY_ICLOUD_PHOTOS_TOUR=1: scroll the grid from top to bottom by itself and
  // open one photo at the end. Used to record the demo video.
  readonly property bool tour: Quickshell.env("OMARCHY_ICLOUD_PHOTOS_TOUR") === "1"
  property bool tourStarted: false
  // Multi-selection: ids of the checked items and the index where a shift
  // range starts. The cursor (`selected`) always counts as selected too.
  property var checked: ({})
  property int checkedCount: 0
  property int anchor: -1
  property bool viewerOpen: false
  property string previewForId: ""
  property bool helpOpen: false
  // Details panel in the viewer (`i`): rows for the item it was fetched for.
  property bool infoOpen: false
  property var infoRows: []
  property string infoForId: ""
  property var status: ({ state: "unknown", message: "", at: "" })
  property bool indexMissing: false
  // Apple ID from the config file; empty until the first sign-in.
  property string appleId: ""
  property bool configLoaded: false
  property bool skipTimer: false
  // The sign-in card shows on first run and whenever the session has expired.
  readonly property bool needLogin: configLoaded && (appleId === "" || status.state === "auth-required")
  // Keep the grid scrolled to the newest items (the bottom) until the user
  // moves away, so a fresh sync lands in view like on the phone.
  // root.tour, not tour: the animation below has id `tour`, and an id wins
  // from a property in the same scope.
  property bool pinBottom: !root.tour   // the tour starts at the top and scrolls down
  // True while the grid is being rebuilt, so a re-created selected thumb
  // does not yank the view towards itself before the layout has settled.
  property bool suppressReveal: false

  // Thumbnail size, driven by the slider in the footer and remembered.
  property int cell: settings.cell
  // Item waiting for a yes in the delete dialog, and the last one that went
  // so it can be undone with the toast button or `u`.
  property var pendingDelete: null
  property var lastDeleted: []
  property int batchTotal: 0
  property int batchDone: 0
  property bool trashBusy: false
  // Queue of {action, item} for the helper, run one at a time. Confirming a
  // delete removes the item from the grid right away and queues the work;
  // the toast at the bottom reports progress and offers Undo when done.
  property var jobs: []
  property bool undoAfterCurrent: false
  property bool reindexDirty: false
  property string downloadingId: ""
  property string downloadingComponent: "original"
  property int downloadPercent: 0
  property string downloadError: ""
  property string failedDownloadId: ""
  property bool videoPreparing: false
  property var afterDownload: null
  readonly property int gap: 8
  readonly property var current: (selected >= 0 && selected < items.length) ? items[selected] : null

  // Everything an action applies to: the checked items in grid order, or
  // just the cursor when nothing is checked.
  function targets() {
    if (checkedCount === 0) return current ? [current] : [];
    var out = [];
    for (var i = 0; i < items.length; i++) if (checked[items[i].id]) out.push(items[i]);
    return out;
  }

  function clearChecked() {
    checked = ({});
    checkedCount = 0;
    anchor = selected;
  }

  function setChecked(map) {
    var n = 0;
    for (var k in map) n++;
    checked = map;
    checkedCount = n;
  }

  // Shift: check every item between the anchor and the cursor.
  function checkRange(from, to) {
    if (from < 0) from = to;
    var map = {};
    var a = Math.min(from, to), b = Math.max(from, to);
    for (var i = a; i <= b; i++) map[items[i].id] = true;
    setChecked(map);
  }

  function toggleChecked(index) {
    var map = Object.assign({}, checked);
    var id = items[index].id;
    if (map[id]) delete map[id]; else map[id] = true;
    setChecked(map);
    anchor = index;
  }

  function checkAll() {
    var map = {};
    for (var i = 0; i < items.length; i++) map[items[i].id] = true;
    setChecked(map);
  }
  readonly property bool busy: sync.running || status.state === "syncing" || status.state === "indexing"

  Theme { id: appTheme }

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: appTheme.apply(text())
    onFileChanged: reload()
  }

  FileView {
    id: indexFile
    path: root.cacheDir + "/index.json"
    watchChanges: true
    printErrors: false
    onLoaded: { root.indexMissing = false; root.applyIndex(text()); if (root.tour && !root.tourStarted) tourKickoff.start(); }
    onLoadFailed: { root.indexMissing = true; if (!sync.running && root.appleId !== "") sync.running = true; }
    onFileChanged: reload()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      var next = root.parseAppleId(text());
      root.skipTimer = /^\s*SKIP_TIMER=1\s*$/m.test(text());
      if (root.appleId && next !== root.appleId) { root.libraryItems = []; root.rebuild([], -1); root.startSync(); }
      root.appleId = next;
      root.configLoaded = true;
      if (root.appleId && root.indexMissing && !sync.running) root.startSync();
    }
    onLoadFailed: { root.appleId = ""; root.configLoaded = true; }
    onFileChanged: reload()
  }

  // Sign-in runs the helper with the password on stdin; Apple's 2FA code
  // goes down the same pipe when the helper asks for it.
  Process {
    id: login
    running: false
    stdinEnabled: true
    property string password: ""
    onStarted: { write(password + "\n"); password = ""; }
    stdout: SplitParser {
      onRead: data => root.loginLine(data)
    }
    onExited: (code, status) => {
      if (loginCard.busy) {
        loginCard.busy = false;
        if (loginCard.error === "") loginCard.error = "The sign-in helper stopped without an answer";
      }
    }
  }

  FileView {
    id: statusFile
    path: root.cacheDir + "/status.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.status = JSON.parse(text()); } catch (e) {}
    }
    onFileChanged: reload()
  }
  FileView {
    id: albumIndexFile
    path: root.cacheDir + "/album-index.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { var rows = JSON.parse(text()); if (Array.isArray(rows)) root.albumRows = rows; } catch (e) {}
    }
    onFileChanged: reload()
  }
  FileView {
    id: albumMembersFile
    path: root.activeSection.indexOf("album:") === 0 ?
          root.cacheDir + "/albums/" + root.activeSection.slice(6) + ".json" : ""
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var data = JSON.parse(text());
        if (root.activeSection !== "album:" + data.albumId) return;
        var map = {};
        for (var i = 0; i < data.ids.length; i++) map[data.ids[i]] = true;
        root.albumKeys = map;
        root.albumLoading = !data.complete;
        root.applyIndex(JSON.stringify(root.libraryItems));
      } catch (e) {}
    }
    onFileChanged: reload()
  }
  Process {
    id: albumProc
    onExited: (code, status) => {
      albumMembersFile.reload();
      if (code !== 0) root.albumLoading = false;
      if (root.activeSection.indexOf("album:") === 0 && root.activeSection.slice(6) !== albumProc.itemId)
        albumLoadTimer.restart();
    }
    property string itemId: ""
  }
  Timer {
    id: albumLoadTimer
    interval: 150
    onTriggered: {
      if (root.activeSection.indexOf("album:") !== 0) return;
      if (albumProc.running) { albumLoadTimer.restart(); return; }
      albumProc.itemId = root.activeSection.slice(6);
      albumProc.command = [catalogScript, "album-members", albumProc.itemId];
      albumProc.running = true;
    }
  }

  Process {
    id: sync
    command: [root.syncScript]
    running: false
    onExited: { indexFile.reload(); albumIndexFile.reload(); statusFile.reload(); root.startPolicy(); }
  }

  Process {
    id: policyProc
    running: false
    onExited: indexFile.reload()
  }
  Timer {
    interval: 30000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.startPolicy()
  }
  function startPolicy() {
    if (sync.running || policyProc.running || needLogin || indexMissing) return;
    policyProc.command = [catalogScript, "policy", "--limit", "12"];
    policyProc.running = true;
  }

  Process {
    id: previewProc
    property string itemId: ""
    onExited: {
      indexFile.reload();
      if (root.viewerOpen && root.current && root.current.id !== itemId) previewTimer.restart();
    }
  }
  Timer { id: previewTimer; interval: 150; onTriggered: root.loadViewerPreview() }
  function loadViewerPreview() {
    if (!viewerOpen || !current || current.kind === "video" || current.downloaded ||
        (current.preview && current.preview !== current.thumb) || previewProc.running || needLogin) return;
    previewProc.itemId = current.id;
    previewProc.command = [catalogScript, "preview", current.id];
    previewProc.running = true;
  }

  Process {
    id: originalDownload
    property string completedPath: ""
    stdout: SplitParser { onRead: data => root.downloadLine(data) }
    stderr: StdioCollector {
      onStreamFinished: {
        if (!text.trim()) return;
        try { root.downloadError = JSON.parse(text.trim()).error || "Download failed"; }
        catch (e) { root.downloadError = "Download failed"; }
      }
    }
    onExited: (code, status) => root.downloadFinished(code)
  }
  Process {
    id: videoPrepare
    property string itemId: ""
    property bool converted: false
    stdout: SplitParser {
      onRead: data => {
        try { videoPrepare.converted = JSON.parse(data).converted === true; } catch (e) {}
      }
    }
    onExited: (code, status) => {
      root.videoPreparing = false;
      if (code !== 0) { toast.show("Could not prepare video playback", 3500); return; }
      if (!root.current || root.current.id !== itemId) return;
      if (converted) {
        var updated = root.libraryItems.map(function (it) {
          if (it.id !== videoPrepare.itemId) return it;
          return Object.assign({}, it, { video: root.cacheDir + "/videos/" + it.id + ".mp4" });
        });
        root.applyIndex(JSON.stringify(updated));
      }
      viewer.videoShown = true;
      indexFile.reload();
    }
  }
  Process {
    id: eviction
    onExited: (code, status) => {
      indexFile.reload();
      toast.show(code === 0 ? "Local download removed; copy kept in iCloud" : "Could not remove local download", 3500);
    }
  }
  Process {
    id: keepOfflineProc
    onExited: indexFile.reload()
  }
  function keepOffline(items) {
    var list = Array.isArray(items) ? items : [items];
    var ids = list.filter(function (it) { return it && it.downloaded && !it.keptOffline; }).map(function (it) { return it.id; });
    if (!ids.length || keepOfflineProc.running) return;
    keepOfflineProc.command = [catalogScript, "keep-offline"].concat(ids);
    keepOfflineProc.running = true;
  }
  Process {
    id: priorityProc
    property bool repeatNeeded: false
    onExited: (code, status) => {
      if (code !== 0) root.prioritySignature = "";
      if (repeatNeeded) { repeatNeeded = false; priorityTimer.restart(); }
    }
  }
  Timer {
    id: priorityTimer
    interval: 180
    onTriggered: root.publishViewportPriority()
  }
  Timer {
    interval: 2000
    repeat: true
    running: true
    onTriggered: root.publishViewportPriority()
  }

  function publishViewportPriority() {
    if (needLogin || items.length === 0) return;
    if (priorityProc.running) { priorityProc.repeatNeeded = true; return; }
    var ids = grid.priorityIds();
    var signature = ids.join(",");
    if (ids.length === 0 || signature === prioritySignature) return;
    prioritySignature = signature;
    priorityProc.command = [catalogScript, "prioritize"].concat(ids);
    priorityProc.running = true;
  }

  function downloadLine(data) {
    var event;
    try { event = JSON.parse(data); } catch (e) { return; }
    if (event.state === "downloading")
      downloadPercent = event.total > 0 ? Math.floor(100 * event.received / event.total) : 0;
    else if (event.state === "downloaded") originalDownload.completedPath = event.path;
  }

  function downloadFinished(code) {
    var id = downloadingId, component = downloadingComponent;
    var path = originalDownload.completedPath, callback = afterDownload;
    afterDownload = null;
    downloadingId = "";
    if (code === 0 && path) {
      failedDownloadId = "";
      var master = libraryItems.slice();
      for (var i = 0; i < master.length; i++) if (master[i].id === id) {
        var it = Object.assign({}, master[i]);
        if (component === "motion") it.video = path;
        else { it.path = path; it.preview = /\.(heic|heif|tif|tiff|dng)$/i.test(path) ? it.thumb : path;
               it.downloaded = true; it.evictable = true; it.state = "downloaded"; if (it.kind === "video") it.video = path; }
        master[i] = it;
        break;
      }
      libraryItems = master;
      var visible = filterItems(master);
      var selectedId = current ? current.id : id;
      var selectedIndex = visible.findIndex(function (x) { return x.id === selectedId; });
      rebuild(visible, selectedIndex >= 0 ? selectedIndex : visible.length - 1);
      if (infoOpen && current && current.id === id) { infoForId = ""; fetchInfo(); }
      if (callback) callback();
    } else {
      failedDownloadId = id;
      downloadError = downloadError || "Download stopped. Retry when ready.";
      toast.show(downloadError, 6000);
    }
    indexFile.reload();
  }

  function ensureOriginal(it, callback, component) {
    if (!it) return;
    component = component || "original";
    if ((component === "motion" ? it.video : it.path) && it.downloaded) {
      if (callback) callback();
      return;
    }
    if (originalDownload.running) { toast.show("A download is already running", 2500); return; }
    downloadingId = it.id;
    downloadingComponent = component;
    failedDownloadId = "";
    downloadError = "";
    downloadPercent = 0;
    afterDownload = callback || null;
    originalDownload.completedPath = "";
    originalDownload.command = [catalogScript, "download", it.id, "--component", component];
    originalDownload.running = true;
  }

  function cancelDownload() {
    afterDownload = null;
    if (originalDownload.running) originalDownload.running = false;
  }

  function playVideo(it) {
    if (!it || videoPrepare.running || originalDownload.running) return;
    if (!it.path) { ensureOriginal(it, function () { root.playVideo(root.current); }); return; }
    videoPreparing = true;
    videoPrepare.itemId = it.id;
    videoPrepare.converted = false;
    videoPrepare.command = [catalogScript, "convert", it.id];
    videoPrepare.running = true;
  }

  function ensureMany(list, callback, at) {
    at = at || 0;
    if (at >= list.length) { callback(); return; }
    ensureOriginal(list[at], function () { root.ensureMany(list, callback, at + 1); });
  }

  function evictLocal(list) {
    if (!list || list.length === 0 || eviction.running) return;
    list = list.filter(function (it) { return it.evictable === true; });
    if (list.length === 0) { toast.show("Existing backup files are preserved", 3500); return; }
    if (originalDownload.running) cancelDownload();
    eviction.command = [catalogScript, "evict"].concat(list.map(function (it) { return it.id; }));
    eviction.running = true;
  }

  Process { id: opener }
  Process {
    id: favoriteProc
    property string assetId: ""
    property bool requestedFavorite: false
    property bool cloudSynced: false
    stdout: SplitParser {
      onRead: data => {
        try { favoriteProc.cloudSynced = JSON.parse(data).cloudSynced === true; }
        catch (e) { favoriteProc.cloudSynced = false; }
      }
    }
    onExited: (code, status) => {
      if (code !== 0) {
        favoriteLocalProc.command = [catalogScript, "favorite-local", assetId,
                                     requestedFavorite ? "1" : "0"];
        favoriteLocalProc.running = true;
        return;
      }
      assetId = "";
      indexFile.reload();
      if (!cloudSynced) toast.show("Favorite saved locally; iCloud will retry on refresh", 4500);
    }
  }
  Process {
    id: favoriteLocalProc
    onExited: (code, status) => {
      favoriteProc.assetId = "";
      if (code === 0) indexFile.reload();
      toast.show(code === 0 ? "Favorite saved locally; iCloud will retry on refresh" :
                 "Could not save favorite locally", 4500);
    }
  }
  Process {
    id: infoProc
    property string forId: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var rows = [];
        try { rows = JSON.parse(text); } catch (e) {}
        if (root.current && root.current.id === infoProc.forId && root.current.shared)
          rows = [["Library", "Shared"]].concat(rows);
        root.infoRows = rows;
        root.infoForId = infoProc.forId;
      }
    }
  }
  Process {
    id: wallpaper
    stdout: StdioCollector {
      onStreamFinished: toast.show(text.trim().length > 0 ? text.trim() : "Set as wallpaper", 2500)
    }
  }
  Process {
    id: saver
    stdout: StdioCollector {
      onStreamFinished: {
        var names = text.trim().split("\n").filter(function (n) { return n.length > 0; });
        if (names.length === 1) toast.show("Saved to ~/Downloads/" + names[0], 3000);
        else if (names.length > 1) toast.show("Saved " + names.length + " files to ~/Downloads", 3000);
      }
    }
  }
  // The sync timer goes on at the first sign-in. install.sh already enables
  // it; a package cannot, since it is a per-user unit.
  Process {
    id: timerEnabler
    command: ["systemctl", "--user", "enable", "--now", "omarchy-icloud-photos-sync.timer"]
  }
  // Every copy command runs under setsid: wl-copy stays behind to serve the
  // clipboard, and without its own session it dies when the app quits, so
  // copy-then-close left nothing to paste.
  Process {
    id: copier
    property string successMessage: ""
    onExited: (code, status) => {
      if (code === 0) toast.show(successMessage);
      else toast.show("Could not copy to clipboard", 3000);
    }
  }

  // Re-index in the background after a delete or restore so index.json
  // matches what is on disk again; the FileView picks the result up.
  Process {
    id: reindex
    command: [root.syncScript, "--index-only"]
    running: false
    onExited: if (root.reindexDirty) { root.reindexDirty = false; running = true; }
  }

  Process {
    id: trash
    running: false
    property string action: ""
    property var subject: null
    stdout: StdioCollector {
      onStreamFinished: root.trashFinished(trash.action, trash.subject, text)
    }
    // If the helper could not start or died without output, stdout never
    // finishes; settle the dialog anyway shortly after the process is gone.
    onRunningChanged: if (!running) settle.restart()
    onStarted: watchdog.restart()
  }
  Timer {
    id: settle
    interval: 700
    onTriggered: if (root.trashBusy) root.trashFinished(trash.action, trash.subject, "")
  }
  Timer {
    id: watchdog
    interval: 120000
    onTriggered: if (root.trashBusy) { trash.running = false; root.trashFinished(trash.action, trash.subject, ""); }
  }

  FileView {
    id: settingsFile
    path: root.cacheDir + "/settings.json"
    printErrors: false
    JsonAdapter {
      id: settings
      property int cell: 176
      property string downloadMode: "manual"
      property int recentDays: 30
      property int previewDays: 7
    }
  }

  function updateDownloadMode(mode) {
    if (mode !== "manual" && mode !== "recent" && mode !== "all") return;
    if (policyProc.running) policyProc.running = false;
    settings.downloadMode = mode;
    settingsFile.writeAdapter();
    policyStartTimer.restart();
  }
  Timer { id: policyStartTimer; interval: 500; onTriggered: root.startPolicy() }

  function applyIndex(raw) {
    var list;
    try { list = JSON.parse(raw); } catch (e) { return; }
    if (!Array.isArray(list)) return;
    if (favoriteProc.assetId) list = list.map(function (it) {
      return it.id === favoriteProc.assetId ? Object.assign({}, it, { favorite: favoriteProc.requestedFavorite }) : it;
    });
    var keepId = current ? current.id : null;
    libraryItems = list;
    list = filterItems(list);
    // Thumbnail and download-state updates do not change tile geometry.
    // Updating the existing delegates in place prevents visible flicker.
    if (list.length === items.length && list.every(function (it, i) {
      return it.id === root.items[i].id && it.date === root.items[i].date;
    })) {
      items = list;
      priorityTimer.restart();
      return;
    }
    var idx = -1;
    if (keepId) for (var j = 0; j < list.length; j++) if (list[j].id === keepId) { idx = j; break; }
    rebuild(list, idx >= 0 ? idx : list.length - 1);
  }

  function sectionTitle() {
    var names = { library: "Library", favorites: "Favorites", recents: "Recents",
                  downloaded: "Downloaded", videos: "Videos", live: "Live Photos",
                  shared: "Shared Library" };
    if (activeSection.indexOf("album:") === 0) {
      var id = activeSection.slice(6);
      var row = albumRows.find(function (a) { return a.id === id; });
      return row ? row.title : "Album";
    }
    return names[activeSection] || "Library";
  }

  function matchesSection(it) {
    if (searchText && String(it.name || "").toLocaleLowerCase().indexOf(searchText.toLocaleLowerCase()) < 0) return false;
    if (activeSection === "favorites") return it.favorite === true;
    if (activeSection === "recents") return it.addedAt != null && it.addedAt >= Date.now() / 1000 - 30 * 86400;
    if (activeSection === "downloaded") return it.downloaded === true;
    if (activeSection === "videos") return it.kind === "video";
    if (activeSection === "live") return it.kind === "live";
    if (activeSection === "shared") return it.shared === true;
    if (activeSection.indexOf("album:") === 0) return albumKeys[it.id] === true;
    return true;
  }

  function filterItems(list) { return list.filter(function (it) { return root.matchesSection(it); }); }

  function selectSection(section) {
    if (activeSection === section) return;
    activeSection = section;
    if (section.indexOf("album:") === 0) {
      albumKeys = ({});
      albumLoading = true;
      albumMembersFile.reload();
      albumLoadTimer.restart();
    }
    viewerOpen = false;
    clearChecked();
    pinBottom = true;
    var list = filterItems(libraryItems);
    rebuild(list, list.length - 1);
  }

  function calendarYears() {
    var years = {};
    for (var i = 0; i < libraryItems.length; i++) {
      var date = libraryItems[i].date || "";
      if (/^\d{4}-\d{2}/.test(date)) years[Number(date.slice(0, 4))] = true;
    }
    return Object.keys(years).map(Number).sort(function (a, b) { return b - a; });
  }

  function monthPreview(year, month) {
    var prefix = year + "-" + (month < 10 ? "0" : "") + month;
    for (var i = libraryItems.length - 1; i >= 0; i--)
      if (libraryItems[i].date && libraryItems[i].date.indexOf(prefix) === 0 && libraryItems[i].thumb)
        return libraryItems[i].thumb;
    return "";
  }

  function monthHasItems(year, month) {
    var prefix = year + "-" + (month < 10 ? "0" : "") + month;
    return libraryItems.some(function (it) { return it.date && it.date.indexOf(prefix) === 0; });
  }

  function jumpToMonth(year, month) {
    var prefix = year + "-" + (month < 10 ? "0" : "") + month;
    if (activeSection !== "library") selectSection("library");
    calendarPopup.close();
    Qt.callLater(function () { root.scrollToMonth(prefix); });
  }

  function scrollToMonth(prefix) {
    for (var d = 0; d < days.length; d++) {
      var first = items[days[d].indices[0]];
      if (first && first.date && first.date.indexOf(prefix) === 0) {
        pinBottom = false;
        var top = grid.tileTop(d, 0);
        if (top >= 0) grid.contentY = grid.clampY(top - 40);
        return;
      }
    }
  }

  function toggleFavorite(item) {
    var target = item || current;
    if (!target || favoriteProc.assetId || target.state === undefined) return;
    favoriteProc.assetId = target.id;
    favoriteProc.requestedFavorite = target.favorite !== true;
    favoriteProc.cloudSynced = false;
    updateFavoriteInMemory(target.id, favoriteProc.requestedFavorite);
    favoriteProc.command = [helperScript, "favorite", "--key", target.id,
                            "--value", favoriteProc.requestedFavorite ? "1" : "0"];
    favoriteProc.running = true;
  }

  function updateFavoriteInMemory(id, value) {
    var list = libraryItems.map(function (it) {
      return it.id === id ? Object.assign({}, it, { favorite: value }) : it;
    });
    applyIndex(JSON.stringify(list));
  }

  onSearchTextChanged: {
    var list = filterItems(libraryItems);
    rebuild(list, list.length - 1);
  }

  function groupDays(list) {
    var groups = [];
    var byDate = {};
    for (var i = 0; i < list.length; i++) {
      var d = list[i].date;
      if (!byDate[d]) {
        byDate[d] = { label: dayLabel(list[i]), indices: [] };
        groups.push(byDate[d]);
      }
      byDate[d].indices.push(i);
    }
    return groups;
  }

  function dayLabel(it) {
    if (!it.captured && it.date === "Unknown") return "Unknown date";
    var d = new Date(it.ts * 1000);
    var today = new Date(); today.setHours(0, 0, 0, 0);
    var day = new Date(d); day.setHours(0, 0, 0, 0);
    var diff = Math.round((today - day) / 86400000);
    if (diff === 0) return "Today";
    if (diff === 1) return "Yesterday";
    var s = d.toLocaleDateString(Qt.locale("en_GB"), "dddd d MMMM");
    return s.charAt(0).toUpperCase() + s.slice(1);
  }

  function rangeLabel() {
    return sectionTitle();
  }

  function parseAppleId(raw) {
    var m = String(raw || "").match(/^\s*APPLE_ID=["']?([^"'\n]+)/m);
    return m ? m[1].trim() : "";
  }

  function startLogin(username, password) {
    login.password = password;
    login.command = [root.helperScript, "login", "--username", username, "--save-config"];
    login.running = true;
  }

  function loginLine(line) {
    var msg = null;
    try { msg = JSON.parse(String(line).trim()); } catch (e) { return; }
    if (msg.step === "2fa") {
      loginCard.busy = false;
      loginCard.step = "code";
    } else if (msg.step === "retry") {
      loginCard.error = msg.message || "Trying again…";
    } else if (msg.ok) {
      loginCard.busy = false;
      loginCard.reset();
      root.appleId = msg.username;
      root.status = { state: "ok", message: "", at: "" };
      toast.show("Signed in as " + msg.username);
      keys.forceActiveFocus();
      startSync();
      if (!root.skipTimer && Quickshell.env("OMARCHY_ICLOUD_PHOTOS_SKIP_TIMER") !== "1") timerEnabler.running = true;
    } else if (msg.error) {
      loginCard.busy = false;
      loginCard.error = msg.error;
      if (loginCard.step === "code") loginCard.step = "credentials";
    }
  }

  function syncedLabel() {
    if (status.state === "paused") return status.message || "Sync paused";
    if (busy) {
      // The sync script says what it is doing; the count grows as files land.
      var what = status.message || (status.state === "indexing" ? "Building thumbnails" : "Syncing");
      var n = status.count > 0 ? "  " + status.count : "";
      return what + "…" + n;
    }
    if (!status.at) return "";
    var d = new Date(status.at);
    if (isNaN(d.getTime())) return "";
    var today = new Date(); today.setHours(0, 0, 0, 0);
    var same = d >= today;
    return "synced " + (same ? "" : d.toLocaleDateString(Qt.locale("en_GB"), "d MMM ") + "at ")
      + d.toLocaleTimeString(Qt.locale("en_GB"), "HH:mm");
  }

  function move(delta, extend) {
    if (items.length === 0) return;
    pinBottom = false;
    var next = Math.max(0, Math.min(items.length - 1, selected + delta));
    if (extend) {
      if (anchor < 0 || checkedCount === 0) anchor = selected;
      selected = next;
      checkRange(anchor, selected);
    } else {
      selected = next;
      if (checkedCount > 0) clearChecked();
      anchor = selected;
    }
  }

  // Up and down through the grid as it is actually laid out. Each day is its
  // own block of rows, so a day that does not fill its last row shifts every
  // row after it: counting a fixed number of items back lands somewhere
  // arbitrary, and the wider the window the further off it gets. This walks
  // rows within the day and steps into the neighbouring day at the edges,
  // keeping the column so the cursor travels in a straight line.
  function moveRow(dir, extend) {
    if (items.length === 0 || selected < 0) return;
    var cols = Math.max(1, grid.columns);
    var d = -1, pos = -1;
    for (var i = 0; i < days.length && d < 0; i++) {
      var at = days[i].indices.indexOf(selected);
      if (at >= 0) { d = i; pos = at; }
    }
    if (d < 0) { move(dir * cols, extend); return; }

    var col = pos % cols;
    var row = Math.floor(pos / cols);
    var here = days[d].indices;
    var target = -1;

    if (dir < 0) {
      if (row > 0) target = here[Math.min((row - 1) * cols + col, here.length - 1)];
      else if (d > 0) {
        var prev = days[d - 1].indices;
        var lastRow = Math.floor((prev.length - 1) / cols);
        target = prev[Math.min(lastRow * cols + col, prev.length - 1)];
      }
    } else {
      var lastRowHere = Math.floor((here.length - 1) / cols);
      if (row < lastRowHere) target = here[Math.min((row + 1) * cols + col, here.length - 1)];
      else if (d < days.length - 1) {
        var next = days[d + 1].indices;
        target = next[Math.min(col, next.length - 1)];
      }
    }

    if (target === undefined || target < 0) return;
    jumpTo(target, extend);
  }

  function jumpTo(index, extend) {
    if (items.length === 0) return;
    pinBottom = false;
    if (extend) {
      if (anchor < 0 || checkedCount === 0) anchor = selected;
      selected = index;
      checkRange(anchor, selected);
    } else {
      selected = index;
      if (checkedCount > 0) clearChecked();
      anchor = selected;
    }
  }

  function openCurrent() {
    if (!current) return;
    var id = current.id;
    ensureOriginal(current, function () {
      var it = root.items.find(function (x) { return x.id === id; });
      opener.command = ["xdg-open", it.kind === "video" ? it.video : it.path];
      opener.running = true;
    });
  }

  function copyTargets() {
    return viewerOpen ? (current ? [current] : []) : targets();
  }

  function latestItems(list) {
    return list.map(function (it) {
      return root.libraryItems.find(function (candidate) { return candidate.id === it.id; }) || it;
    });
  }

  function showCopyMenu(source, x, y, index) {
    if (needLogin || helpOpen || pendingDelete) return;
    var pos = source.mapToItem(keys, x, y);
    if (index >= 0) {
      pinBottom = false;
      // Right-click keeps a checked group, or selects just the clicked photo.
      if (checked[items[index].id]) selected = index;
      else jumpTo(index, false);
    }
    // Keep the menu's target stable if a background sync rebuilds the grid.
    copyMenu.items = copyTargets();
    if (copyMenu.items.length > 0) copyMenu.popup(pos.x, pos.y);
  }

  function copyCurrent(list) {
    if (copier.running) return;
    if (!list) list = copyTargets();
    if (list.length === 0) return;
    list = latestItems(list);
    var pending = list.filter(function (it) { return it.state !== undefined && !it.downloaded; });
    if (pending.length) { ensureMany(pending, function () { root.copyCurrent(list); }); return; }
    if (list.length > 1) {
      // A list of files: file managers paste them as copies, chat apps as
      // attachments. Plain text gets the paths, one per line.
      var uris = list.map(function (it) { return "file://" + encodeURI(it.kind === "video" ? it.video : it.path); });
      copier.command = ["setsid", "bash", "-c", 'printf "%s\n" "$@" | wl-copy --type text/uri-list', "_"].concat(uris);
      copier.successMessage = "Copied " + list.length + " files";
      copier.running = true;
      return;
    }
    var it = list[0];
    // A video copies as the video. A Live Photo is a still that happens to
    // move, so that one copies as its picture, like it does everywhere else.
    var src = it.kind === "video" ? it.video : (it.state !== undefined ? it.path : it.preview);
    copier.command = ["setsid", binDir + "/omarchy-icloud-photos-copy", src];
    copier.successMessage = "Copied image to clipboard";
    toast.show("Copying image…", 30000);
    copier.running = true;
  }

  // Save to ~/Downloads in a format anything can open: HEIC becomes a
  // full-size JPEG, HDR video becomes its SDR MP4 copy, other video is
  // remuxed to MP4 without re-encoding, JPEG and PNG are copied as they are.
  // Never overwrites: a taken name gets a numbered suffix.
  function saveToDownloads(list) {
    if (!list) list = targets();
    if (list.length === 0) return;
    list = latestItems(list);
    var pending = list.filter(function (it) { return it.state !== undefined && !it.downloaded; });
    if (pending.length) { ensureMany(pending, function () { root.saveToDownloads(list); }); return; }
    var args = [];
    for (var i = 0; i < list.length; i++) {
      var it = list[i];
      if (it.kind === "video") args.push(it.video, /\.mp4$/i.test(it.video) ? "copy" : "remux");
      else if (/\.(heic|heif|tif|tiff|dng)$/i.test(it.path)) args.push(it.path, "jpeg");
      else args.push(it.path, "copy");
    }
    saver.command = ["bash", "-c", '
      mkdir -p "$HOME/Downloads"
      while [ $# -ge 2 ]; do
        src="$1"; how="$2"; shift 2
        name=$(basename "$src"); base="${name%.*}"
        case "$how" in jpeg) ext=jpg ;; remux) ext=mp4 ;; *) ext="${name##*.}" ;; esac
        n=1; dest="$HOME/Downloads/$base.$ext"
        while [ -e "$dest" ]; do dest="$HOME/Downloads/$base-$n.$ext"; n=$((n+1)); done
        case "$how" in
          jpeg)  magick "$src" -auto-orient -quality 92 "$dest" ;;
          remux) ffmpeg -v error -y -i "$src" -c copy -movflags +faststart "$dest" || ffmpeg -v error -y -i "$src" -c:v libx264 -preset veryfast -crf 20 -c:a aac "$dest" ;;
          *)     cp -p "$src" "$dest" ;;
        esac && touch -r "$src" "$dest" && basename "$dest"
      done', "_"].concat(args);
    saver.running = true;
  }

  // W: the current photo becomes the Omarchy background. HEIC first becomes
  // a full-size JPEG in the cache, since the shell cannot decode HEIC.
  function setWallpaper() {
    if (!current || current.kind === "video") return;
    if (current.state !== undefined && !current.downloaded) {
      ensureOriginal(current, function () { root.setWallpaper(); });
      return;
    }
    var it = current;
    wallpaper.command = ["bash", "-c", '
      src="$1"; cache="$2"; key="$3"
      case "${src,,}" in
        *.heic|*.heif|*.tif|*.tiff|*.dng)
          mkdir -p "$cache/wallpaper"
          out="$cache/wallpaper/$key.jpg"
          [ -s "$out" ] || magick "$src" -auto-orient -quality 92 "$out" || { echo "Could not convert $src"; exit 0; }
          src="$out" ;;
      esac
      omarchy-theme-bg-set "$src" >/dev/null 2>&1 && echo "Wallpaper set" || echo "Could not set the wallpaper"', "_", it.path, root.cacheDir, it.id];
    wallpaper.running = true;
  }

  // `i` in the viewer: camera and file details for the current item.
  function toggleInfo() {
    infoOpen = !infoOpen;
    if (infoOpen) fetchInfo();
  }

  function fetchInfo() {
    if (!current || infoProc.running) return;
    if (infoForId === current.id) return;
    if (current.state !== undefined && !current.path) {
      var rows = [];
      if (current.shared) rows.push(["Library", "Shared"]);
      if (current.camera) rows.push(["Camera", current.camera]);
      if (current.width && current.height) rows.push(["Size", current.width + " × " + current.height]);
      if (current.location) rows.push(["Location", JSON.stringify(current.location)]);
      if (current.captured) rows.push(["Captured", current.captured]);
      if (current.timezone) rows.push(["Time zone", String(current.timezone)]);
      rows.push(["File", current.name]);
      infoRows = rows;
      infoForId = current.id;
      return;
    }
    infoRows = [];
    infoProc.forId = current.id;
    infoProc.command = [root.infoScript, current.kind === "video" ? current.path : current.path];
    infoProc.running = true;
  }

  onCurrentChanged: {
    if (infoOpen && viewerOpen) fetchInfo();
    if (current && current.id !== failedDownloadId && !originalDownload.running) downloadError = "";
    if (viewerOpen) previewTimer.restart();
  }
  onViewerOpenChanged: {
    if (!viewerOpen) { infoOpen = false; slideTimer.stop(); slideshowRunning = false; slideshowIds = []; }
    else previewTimer.restart();
  }

  function copyPath() {
    if (copier.running) return;
    var list = targets();
    if (list.length === 0) return;
    var pending = list.filter(function (it) { return it.state !== undefined && !it.downloaded; });
    if (pending.length) { ensureMany(pending, function () { root.copyPath(); }); return; }
    var paths = list.map(function (it) { return it.path; });
    copier.command = ["setsid", "bash", "-c", 'printf "%s\n" "$@" | wl-copy', "_"].concat(paths);
    copier.successMessage = list.length === 1 ? "Copied " + paths[0] : "Copied " + list.length + " paths";
    copier.running = true;
  }

  function startSync() {
    if (sync.running) return;
    sync.running = true;
  }

  function setCell(v) {
    v = Math.round(v);
    if (v === settings.cell) return;
    settings.cell = v;
    settingsFile.writeAdapter();
  }

  function askDelete() {
    var list = targets();
    if (list.length === 0) return;
    pendingDelete = list;
  }

  function askDeleteItems(list) {
    if (list && list.length > 0) pendingDelete = latestItems(list);
  }

  function startSlideshow(selectedItems) {
    var list = selectedItems && selectedItems.length ? selectedItems : targets();
    if (!list.length) return;
    slideshowIds = list.length > 1 ? list.map(function (it) { return it.id; }) : [];
    if (slideshowIds.length > 1) {
      var first = items.findIndex(function (it) { return it.id === slideshowIds[0]; });
      if (first < 0) return;
      selected = first;
    }
    viewerOpen = true;
    slideshowRunning = true;
    slideTimer.start();
  }

  Timer {
    id: slideTimer
    interval: 4000
    repeat: true
    onTriggered: {
      if (!root.viewerOpen || root.items.length < 2) { stop(); root.slideshowRunning = false; return; }
      if (root.slideshowIds.length > 1) {
        var present = root.slideshowIds.filter(function (id) {
          return root.items.some(function (it) { return it.id === id; });
        });
        if (present.length < 2) { stop(); root.slideshowRunning = false; return; }
        var at = present.indexOf(root.current ? root.current.id : "");
        var nextId = present[(at + 1) % present.length];
        root.selected = root.items.findIndex(function (it) { return it.id === nextId; });
      } else root.jumpTo((root.selected + 1) % root.items.length, false);
    }
  }

  function confirmDelete() {
    var list = pendingDelete;
    if (!list) return;
    pendingDelete = null;
    if (checkedCount > 0) clearChecked();
    // Fresh batch: what Undo brings back is exactly what leaves now.
    lastDeleted = [];
    batchTotal = list.length;
    batchDone = 0;
    for (var i = 0; i < list.length; i++) removeItem(list[i].id);
    var q = jobs.slice();
    for (var j = 0; j < list.length; j++) q.push({ action: "delete", item: list[j] });
    jobs = q;
    runNext();
  }

  function undoDelete() {
    // Queued deletes that have not started are simply dropped.
    var rest = [], kept = 0;
    for (var i = 0; i < jobs.length; i++) {
      if (jobs[i].action === "delete") { insertItem(jobs[i].item); kept++; }
      else rest.push(jobs[i]);
    }
    if (kept > 0) { jobs = rest; batchTotal -= kept; }
    // One in flight gets its restore right behind it.
    if (trashBusy && trash.action === "delete") {
      undoAfterCurrent = true;
      toast.showBusy("Deleting " + trash.subject.name + "…  undo queued");
      return;
    }
    // Everything that already went comes back.
    var back = lastDeleted;
    lastDeleted = [];
    for (var j = 0; j < back.length; j++) enqueue({ action: "restore", item: back[j] });
    if (back.length === 0 && kept > 0) toast.show(kept === 1 ? "Kept " + rest.length : "Kept " + kept + " items");
  }

  function enqueue(job) {
    var q = jobs.slice(); q.push(job); jobs = q;
    runNext();
  }

  function runNext() {
    if (trash.running || jobs.length === 0) return;
    var q = jobs.slice();
    var job = q.shift();
    jobs = q;
    var it = job.item;
    trashBusy = true;
    trash.action = job.action;
    trash.subject = it;
    if (job.action === "delete") {
      var cmd = [root.helperScript, "delete", "--key", it.id];
      if (it.path) cmd.push("--file", it.path);
      if (it.ts) cmd.push("--ts", String(it.ts));
      if (it.record) cmd.push("--record", it.record, "--zone", it.zone);
      if (it.kind === "live" && it.video) cmd.push("--companion", it.video);
      if (it.shared) cmd.push("--shared");
      trash.command = cmd;
      toast.showBusy(batchTotal > 1 ? "Deleting " + (batchDone + 1) + " of " + batchTotal + "…" : "Deleting " + it.name + "…");
    } else {
      trash.command = [root.helperScript, "restore", "--key", it.id];
      toast.showBusy("Restoring " + it.name + "…");
    }
    trash.running = true;
  }

  function trashFinished(action, it, out) {
    trashBusy = false;
    var res = null;
    var lines = String(out || "").trim().split("\n");
    try { res = JSON.parse(lines[lines.length - 1]); } catch (e) {}
    var ok = res && res.ok;
    var moreDeletes = jobs.some(function (j) { return j.action === "delete"; });
    if (action === "delete") {
      batchDone++;
      if (ok) {
        var l = lastDeleted.slice(); l.push(it); lastDeleted = l;
        if (undoAfterCurrent) {
          undoAfterCurrent = false;
          undoDelete();
        } else if (!moreDeletes) {
          toast.showUndo(lastDeleted.length === 1
            ? "Moved " + it.name + " to Recently Deleted"
            : "Moved " + lastDeleted.length + " items to Recently Deleted");
        }
      } else {
        undoAfterCurrent = false;
        insertItem(it);
        toast.show("Could not delete " + it.name + ": " + ((res && res.error) || "no answer from the helper"), 8000);
      }
    } else {
      if (ok) {
        insertItem(it);
        if (!jobs.some(function (j) { return j.action === "restore"; })) toast.show("Restored");
      } else {
        var l2 = lastDeleted.slice(); l2.push(it); lastDeleted = l2;
        toast.show("Could not restore " + it.name + ": " + ((res && res.error) || "no answer from the helper"), 8000);
      }
    }
    if (reindex.running) reindexDirty = true; else reindex.running = true;
    runNext();
  }

  function removeItem(id) {
    libraryItems = libraryItems.filter(function (it) { return it.id !== id; });
    var list = items.slice();
    var idx = -1;
    for (var i = 0; i < list.length; i++) if (list[i].id === id) { idx = i; break; }
    if (idx < 0) return;
    list.splice(idx, 1);
    var keepSel = Math.min(idx, list.length - 1);
    rebuild(list, keepSel);
  }

  function insertItem(it) {
    var master = libraryItems.slice();
    var masterPos = master.length;
    for (var m = 0; m < master.length; m++) if (master[m].ts > it.ts) { masterPos = m; break; }
    master.splice(masterPos, 0, it);
    libraryItems = master;
    if (!matchesSection(it)) return;
    var list = items.slice();
    var pos = list.length;
    for (var i = 0; i < list.length; i++) if (list[i].ts > it.ts) { pos = i; break; }
    list.splice(pos, 0, it);
    rebuild(list, pos);
  }

  // Swap in a new list without the view moving: the Repeater re-creates
  // every delegate, so the scroll position is captured first and pinned
  // again while the new content height settles.
  function rebuild(list, sel) {
    var y = grid.contentY;
    grid.pendingAnchor = pinBottom ? null : grid.captureAnchor();
    suppressReveal = true;
    grid.restoreY = pinBottom ? -1 : y;
    items = list;
    days = groupDays(list);
    selected = list.length > 0 ? Math.max(0, Math.min(sel, list.length - 1)) : -1;
    if (selected < 0) viewerOpen = false;
    if (checkedCount > 0) {
      var map = {};
      for (var i = 0; i < list.length; i++) if (checked[list[i].id]) map[list[i].id] = true;
      setChecked(map);
    }
    if (pinBottom) grid.scrollToBottom(); else grid.contentY = grid.clampY(y);
    if (grid.pendingAnchor) Qt.callLater(function () { grid.restorePendingAnchor(); });
    settleTimer.restart();
  }

  // The tour, for the demo clip: scroll down with a bit of pace, open a
  // Live Photo and let it play, show the details, then back to the grid for
  // a delete and its undo. About twenty seconds.
  Timer {
    id: tourKickoff
    interval: 1500
    onTriggered: { root.tourStarted = true; tour.start(); }
  }
  SequentialAnimation {
    id: tour
    NumberAnimation {
      target: grid; property: "contentY"
      from: 0; to: Math.max(0, grid.contentHeight - grid.height)
      duration: 4500; easing.type: Easing.InOutCubic
    }
    PauseAnimation { duration: 600 }
    ScriptAction { script: {
      var last = -1;
      for (var i = root.items.length - 1; i >= 0; i--) if (root.items[i].kind === "live") { last = i; break; }
      root.jumpTo(last >= 0 ? last : root.items.length - 1, false);
    } }
    PauseAnimation { duration: 700 }
    ScriptAction { script: root.viewerOpen = true }
    PauseAnimation { duration: 1200 }
    ScriptAction { script: viewer.playLive() }
    PauseAnimation { duration: 2600 }
    ScriptAction { script: root.toggleInfo() }
    PauseAnimation { duration: 3000 }
    ScriptAction { script: root.infoOpen = false }
    PauseAnimation { duration: 500 }
    ScriptAction { script: root.viewerOpen = false }
    PauseAnimation { duration: 900 }
    ScriptAction { script: root.askDelete() }
    PauseAnimation { duration: 2000 }
    ScriptAction { script: root.confirmDelete() }
    PauseAnimation { duration: 2200 }
    ScriptAction { script: root.undoDelete() }
    PauseAnimation { duration: 2000 }
    // A range selection, then the keys overlay.
    ScriptAction { script: {
      var n = root.items.length;
      root.jumpTo(Math.max(0, n - 9), false);
      root.jumpTo(Math.max(0, n - 4), true);
    } }
    PauseAnimation { duration: 2200 }
    ScriptAction { script: { root.clearChecked(); root.helpOpen = true; } }
    PauseAnimation { duration: 2600 }
    ScriptAction { script: root.helpOpen = false }
    PauseAnimation { duration: 800 }
  }

  Timer {
    id: settleTimer
    interval: 150
    onTriggered: {
      grid.restorePendingAnchor();
      root.suppressReveal = false;
      grid.restoreY = -1;
      priorityTimer.restart();
    }
  }

  FloatingWindow {
    id: win
    visible: true
    // A suffix from the environment lets a window rule single out a capture
    // instance (see omarchy-icloud-photos --demo --tour).
    title: "Omarchy iCloud Photos" + (Quickshell.env("OMARCHY_ICLOUD_PHOTOS_TITLE_SUFFIX") || "")
    implicitWidth: 1180
    implicitHeight: 800
    color: appTheme.background

    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Component.onCompleted: forceActiveFocus()

      Shortcut {
        sequence: "Ctrl+C"
        context: Qt.WindowShortcut
        enabled: !root.needLogin && !root.helpOpen && !root.pendingDelete && !copyMenu.visible && root.current !== null
        onActivated: root.copyCurrent()
      }

      CopyMenu {
        id: copyMenu
        theme: appTheme
        onRequestCopy: items => root.copyCurrent(items)
        onRequestEvict: items => root.evictLocal(items)
        onRequestKeepOffline: items => root.keepOffline(items)
        onRequestDownload: items => root.ensureMany(items.filter(function (it) { return !it.downloaded; }), function () { toast.show("Originals downloaded", 2500); })
        onRequestSave: items => root.saveToDownloads(items)
        onRequestOpen: root.openCurrent()
        onRequestSlideshow: items => root.startSlideshow(items)
        onRequestDelete: root.askDeleteItems(items)
        onClosed: keys.forceActiveFocus()
      }

      Popup {
        id: downloadSettings
        x: Math.max(sidebar.width + 8, parent.width - width - 12)
        y: 49
        width: 350
        height: settingsColumn.implicitHeight + 28
        padding: 14
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle { color: appTheme.darkBackground; radius: 10; border.color: appTheme.lighterBackground }
        Column {
          id: settingsColumn
          width: parent.width
          spacing: 10
          Text { text: "Storage settings"; color: appTheme.brightForeground; font.family: appTheme.fontFamily; font.pixelSize: 17; font.bold: true }
          Text { width: parent.width; wrapMode: Text.Wrap; text: "Photos open from a thumbnail, then load a sharper preview. Originals are kept according to your choice below."; color: appTheme.darkForeground; font.family: appTheme.fontFamily; font.pixelSize: 12 }
          Repeater {
            model: [
              { value: "manual", label: "Manual only", detail: "Keep only originals I explicitly chose to save." },
              { value: "recent", label: "Recent originals", detail: "Keep recent originals; older automatic downloads expire." },
              { value: "all", label: "All originals", detail: "Gradually download the full catalog in the background." }
            ]
            delegate: Rectangle {
              required property var modelData
              width: settingsColumn.width; height: 47; radius: 6
              color: settings.downloadMode === modelData.value ? appTheme.lighterBackground : appTheme.background
              Row {
                anchors.fill: parent; anchors.leftMargin: 10; spacing: 9
                Text { anchors.verticalCenter: parent.verticalCenter; text: settings.downloadMode === modelData.value ? "◉" : "○"; color: appTheme.accent; font.pixelSize: 18 }
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  Text { text: modelData.label; color: appTheme.brightForeground; font.family: appTheme.fontFamily; font.pixelSize: 13 }
                  Text { text: modelData.detail; color: appTheme.darkForeground; font.family: appTheme.fontFamily; font.pixelSize: 10 }
                }
              }
              MouseArea { anchors.fill: parent; onClicked: root.updateDownloadMode(modelData.value) }
            }
          }
          Row {
            spacing: 8
            Text { anchors.verticalCenter: parent.verticalCenter; text: "Recent window (days)"; color: appTheme.brightForeground; font.family: appTheme.fontFamily; font.pixelSize: 12 }
            TextField {
              width: 66; height: 30; enabled: settings.downloadMode === "recent"
              text: String(settings.recentDays); validator: IntValidator { bottom: 1; top: 3650 }
              color: appTheme.brightForeground
              onEditingFinished: {
                var n = parseInt(text);
                if (n >= 1 && n <= 3650) { settings.recentDays = n; settingsFile.writeAdapter(); policyStartTimer.restart(); }
                else text = String(settings.recentDays);
              }
            }
          }
          Row {
            spacing: 8
            Text { anchors.verticalCenter: parent.verticalCenter; text: "Clear unused previews after (days)"; color: appTheme.brightForeground; font.family: appTheme.fontFamily; font.pixelSize: 12 }
            TextField {
              width: 58; height: 30
              text: String(settings.previewDays); validator: IntValidator { bottom: 1; top: 3650 }
              color: appTheme.brightForeground
              onEditingFinished: {
                var n = parseInt(text);
                if (n >= 1 && n <= 3650) { settings.previewDays = n; settingsFile.writeAdapter(); }
                else text = String(settings.previewDays);
              }
            }
          }
          Text { width: parent.width; wrapMode: Text.Wrap; text: "A local removal stays removed until you download it again. Manually kept originals are never cleared by the recent window."; color: appTheme.darkForeground; font.family: appTheme.fontFamily; font.pixelSize: 11 }
        }
      }

      Popup {
        id: calendarPopup
        x: sidebar.width + 8
        y: 49
        width: 410
        height: 440
        padding: 0
        modal: false
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle {
          color: appTheme.darkBackground
          radius: 10
          border.color: appTheme.lighterBackground
        }
        Row {
          anchors.fill: parent
          Flickable {
            width: 92; height: parent.height
            clip: true
            contentHeight: yearList.implicitHeight + 12
            Column {
              id: yearList
              width: parent.width
              topPadding: 8
              Repeater {
                model: root.calendarYears()
                delegate: Rectangle {
                  required property int modelData
                  width: 86; height: 32; radius: 5
                  color: root.calendarYear === modelData ? appTheme.lighterBackground : "transparent"
                  Text {
                    anchors.centerIn: parent
                    text: modelData
                    color: appTheme.brightForeground
                    font.family: appTheme.fontFamily
                    font.pixelSize: appTheme.fontSize
                  }
                  MouseArea { anchors.fill: parent; onClicked: root.calendarYear = modelData }
                }
              }
            }
          }
          Rectangle { width: 1; height: parent.height; color: appTheme.lighterBackground }
          Column {
            width: parent.width - 93
            topPadding: 14
            leftPadding: 14
            spacing: 10
            Text {
              text: root.calendarYear
              color: appTheme.brightForeground
              font.family: appTheme.fontFamily
              font.pixelSize: 19
              font.bold: true
            }
            Grid {
              columns: 3
              spacing: 8
              Repeater {
                model: 12
                delegate: Rectangle {
                  required property int index
                  readonly property int month: index + 1
                  readonly property bool available: root.monthHasItems(root.calendarYear, month)
                  readonly property string poster: root.monthPreview(root.calendarYear, month)
                  width: 88; height: 82; radius: 6
                  color: appTheme.background
                  opacity: available ? 1 : 0.35
                  Image {
                    anchors.fill: parent
                    source: poster ? "file://" + poster : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                  }
                  Rectangle {
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    height: 25; color: Qt.rgba(0, 0, 0, 0.65)
                    Text {
                      anchors.centerIn: parent
                      text: Qt.locale("en_US").monthName(month - 1, Locale.ShortFormat)
                      color: "white"
                      font.family: appTheme.fontFamily
                      font.pixelSize: 13
                    }
                  }
                  MouseArea {
                    anchors.fill: parent
                    enabled: available
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.jumpToMonth(root.calendarYear, month)
                  }
                }
              }
            }
          }
        }
      }

      Keys.onPressed: event => {
        var k = event.key;
        var t = event.text;
        if (root.needLogin) return;
        if (root.helpOpen) {
          if (t === "?" || k === Qt.Key_Escape || t === "q") root.helpOpen = false;
          event.accepted = true;
          return;
        }
        if (t === "?") { root.helpOpen = true; event.accepted = true; return; }
        if (root.pendingDelete) {
          if (k === Qt.Key_Escape || t === "n") root.pendingDelete = null
          else if (k === Qt.Key_Return || k === Qt.Key_Enter || t === "y") root.confirmDelete()
          event.accepted = true;
          return;
        }
        var shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        if (ctrl && k === Qt.Key_B) { root.sidebarOpen = !root.sidebarOpen; event.accepted = true; return; }
        if (t === "d" || k === Qt.Key_Delete) { root.askDelete(); event.accepted = true; return; }
        if (t === "u") { root.undoDelete(); event.accepted = true; return; }
        if (t === "s") { root.saveToDownloads(); event.accepted = true; return; }
        if (t === "e") { root.evictLocal(root.targets()); event.accepted = true; return; }
        if (t === "W") { root.setWallpaper(); event.accepted = true; return; }
        if (ctrl && k === Qt.Key_A) { root.checkAll(); event.accepted = true; return; }
        // x, or ctrl+space, ticks the item under the cursor like a ctrl-click.
        if ((t === "x" || (ctrl && k === Qt.Key_Space)) && !root.viewerOpen) {
          if (root.selected >= 0) { root.pinBottom = false; root.toggleChecked(root.selected); }
          event.accepted = true; return;
        }
        if (root.viewerOpen) {
          if (t === "i") root.toggleInfo()
          else if ((k === Qt.Key_Escape || t === "q") && root.infoOpen) root.infoOpen = false
          else if (k === Qt.Key_Escape || t === "q" || k === Qt.Key_Backspace) root.viewerOpen = false
          // Shift+Arrows scrub video; plain arrows navigate to previous/next photo or video
          else if (shift && k === Qt.Key_Left && viewer.videoShown) viewer.seekBy(-5000)
          else if (shift && k === Qt.Key_Right && viewer.videoShown) viewer.seekBy(5000)
          else if (k === Qt.Key_Left || t === "h" || t === "k" || k === Qt.Key_Up) root.move(-1)
          else if (k === Qt.Key_Right || t === "l" || t === "j" || k === Qt.Key_Down) root.move(1)
          else if (k === Qt.Key_Space) {
            if (root.current && root.current.kind === "live" && !root.current.video)
              root.ensureOriginal(root.current, function () { viewer.togglePlay(); }, "motion");
            else viewer.togglePlay();
          }
          else if (t === "o") root.openCurrent()
          else if (t === "y") root.copyCurrent()
          else if (t === "Y") root.copyPath()
          else return;
          event.accepted = true;
          return;
        }
        if (t === "q") Qt.quit()
        else if (k === Qt.Key_Escape) { if (root.checkedCount > 0) root.clearChecked(); else Qt.quit(); }
        else if (k === Qt.Key_Left || k === Qt.Key_H) root.move(-1, shift)
        else if (k === Qt.Key_Right || k === Qt.Key_L) root.move(1, shift)
        else if (k === Qt.Key_Down || k === Qt.Key_J) root.moveRow(1, shift)
        else if (k === Qt.Key_Up || k === Qt.Key_K) root.moveRow(-1, shift)
        else if (k === Qt.Key_PageDown) { for (var pd = 0; pd < 3; pd++) root.moveRow(1, shift); }
        else if (k === Qt.Key_PageUp) { for (var pu = 0; pu < 3; pu++) root.moveRow(-1, shift); }
        else if (k === Qt.Key_Home || t === "g") { root.jumpTo(root.items.length > 0 ? 0 : -1, false); }
        else if (k === Qt.Key_End || t === "G") { root.jumpTo(root.items.length - 1, false); root.pinBottom = true; grid.scrollToBottom(); }
        else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) { if (root.current) root.viewerOpen = true; }
        else if (t === "o") root.openCurrent()
        else if (t === "y") root.copyCurrent()
        else if (t === "Y") root.copyPath()
        else if (t === "r") root.startSync()
        else if (t === "-" || t === "_") root.setCell(root.cell - 24)
        else if (t === "+" || t === "=") root.setCell(root.cell + 24)
        else return;
        event.accepted = true;
      }

      Sidebar {
        id: sidebar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        width: root.needLogin ? 0 : (root.sidebarOpen ? 228 : 42)
        visible: !root.needLogin
        expanded: root.sidebarOpen
        theme: appTheme
        section: root.activeSection
        albumRows: root.albumRows
        onSectionSelected: section => root.selectSection(section)
        onToggleRequested: root.sidebarOpen = false
      }

      // ---- Header ---------------------------------------------------------
      Rectangle {
        id: header
        anchors.top: parent.top
        anchors.left: sidebar.right
        anchors.right: parent.right
        height: 52
        color: appTheme.darkBackground

        Row {
          anchors.left: parent.left
          anchors.leftMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          spacing: 4
          ActionIcon {
            theme: appTheme; icon: "\uf073"; hint: "Jump to month"
            onActivated: {
              var years = root.calendarYears();
              if (years.length && years.indexOf(root.calendarYear) < 0) root.calendarYear = years[0];
              calendarPopup.open();
            }
          }
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: 8
          anchors.verticalCenter: parent.verticalCenter
          spacing: 3
          ActionIcon {
            theme: appTheme; icon: "\uf0ed"; hint: "Refresh catalog from iCloud"
            onActivated: root.startSync()
          }
          ActionIcon {
            theme: appTheme; icon: "\uf013"; hint: "Storage settings"
            onActivated: downloadSettings.open()
          }
          ActionIcon {
            theme: appTheme; icon: "\uf14d"; hint: "Save copy to Downloads"
            available: root.current !== null
            onActivated: root.saveToDownloads()
          }
          ActionIcon {
            theme: appTheme; icon: root.current && root.current.favorite === true ? "\uf004" : "\uf08a"
            hint: root.current && root.current.favorite === true ? "Remove from Favorites" : "Add to Favorites"
            available: root.current !== null && root.current.state !== undefined && !favoriteProc.assetId
            onActivated: root.toggleFavorite()
          }
          ActionIcon {
            theme: appTheme; icon: "\uf019"; hint: "Download original"
            available: root.current !== null && (!root.current.downloaded || !root.current.keptOffline)
            onActivated: root.current && root.current.downloaded ? root.keepOffline(root.current) : root.ensureOriginal(root.current)
          }
          ActionIcon {
            theme: appTheme; icon: "\uf1f8"; hint: "Delete from iCloud…"
            available: root.current !== null
            onActivated: root.askDelete()
          }
          ActionIcon {
            theme: appTheme; icon: "\uf141"; hint: "More actions"
            available: root.current !== null
            onActivated: root.showCopyMenu(this, width / 2, height, -1)
          }
          TextField {
            width: 174; height: 30
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: "Search Photos"
            color: appTheme.brightForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize - 1
            text: root.searchText
            onTextEdited: root.searchText = text
            background: Rectangle {
              radius: 6
              color: appTheme.background
              border.color: appTheme.lighterBackground
            }
          }
        }
      }

      // ---- Problem banner -------------------------------------------------
      Rectangle {
        id: banner
        anchors.top: header.bottom
        anchors.left: sidebar.right
        anchors.right: parent.right
        visible: root.status.state === "error"
        height: visible ? bannerText.implicitHeight + 20 : 0
        color: Qt.rgba(appTheme.red.r, appTheme.red.g, appTheme.red.b, 0.18)
        Text {
          id: bannerText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.margins: 20
          anchors.verticalCenter: parent.verticalCenter
          text: root.status.message
          wrapMode: Text.Wrap
          color: appTheme.brightForeground
          font.family: appTheme.fontFamily
          font.pixelSize: appTheme.fontSize - 1
        }
      }

      // ---- Grid -----------------------------------------------------------
      Flickable {
        id: grid
        anchors.top: banner.bottom
        anchors.left: sidebar.right
        anchors.right: parent.right
        anchors.bottom: footer.top
        clip: true
        contentWidth: width
        contentHeight: column.implicitHeight + 32
        boundsBehavior: Flickable.StopAtBounds

        // Kinetic momentum glide timer for touchpad flick gestures
        Timer {
          id: momentumTimer
          interval: 16
          repeat: true
          property real lastFrameTime: 0

          onTriggered: {
            var now = Date.now();
            var dtSec = lastFrameTime > 0 ? Math.min(0.05, (now - lastFrameTime) / 1000) : 0.016;
            lastFrameTime = now;

            var dy = wheelHandler.velocity * dtSec;
            var newY = grid.contentY - dy;

            if (newY <= 0) {
              grid.contentY = 0;
              wheelHandler.velocity = 0;
              stop();
              return;
            }
            var maxY = Math.max(0, grid.contentHeight - grid.height);
            if (newY >= maxY) {
              grid.contentY = maxY;
              wheelHandler.velocity = 0;
              stop();
              return;
            }

            grid.contentY = newY;
            // Frame-rate independent exponential friction decay (~0.92 per 16ms)
            wheelHandler.velocity *= Math.pow(0.92, dtSec / 0.016);

            if (Math.abs(wheelHandler.velocity) < 20) {
              wheelHandler.velocity = 0;
              stop();
            }
          }

          onRunningChanged: {
            if (running) lastFrameTime = Date.now();
          }
        }

        // Finger release detector for touchpad (triggers kinetic inertia when fingers lift)
        Timer {
          id: releaseTimer
          interval: 60
          repeat: false
          onTriggered: {
            if (Math.abs(wheelHandler.velocity) > 60) {
              momentumTimer.start();
            } else {
              wheelHandler.velocity = 0;
            }
          }
        }

        // Move the content directly: 1:1 pixel deltas with kinetic flick inertia
        // for touchpads, and a fixed discrete step (140px) per mouse wheel notch.
        WheelHandler {
          id: wheelHandler
          acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
          property real velocity: 0
          property real lastEventTime: 0

          onWheel: event => {
            root.pinBottom = false;
            scrollAnim.stop();

            // Fingers off the touchpad. Wayland reports that as a ScrollEnd
            // carrying no delta at all, so it has to be caught before the
            // wheel branch below, which would read it as a notch and throw
            // the speed away: that is what kept the glide from ever starting.
            if (event.phase === Qt.ScrollEnd) {
              releaseTimer.stop();
              if (Math.abs(wheelHandler.velocity) > 60) momentumTimer.start();
              else wheelHandler.velocity = 0;
              event.accepted = true;
              return;
            }

            if (event.pixelDelta.y !== 0) {
              // Touchpad. A finger travels a few centimetres and a month of
              // photos is a good deal longer than that, so the picture moves
              // three times what the finger does, and a flick coasts on from
              // there.
              momentumTimer.stop();
              var now = Date.now();
              var dt = lastEventTime > 0 ? Math.max(1, now - lastEventTime) : 16;
              lastEventTime = now;

              var dy = event.pixelDelta.y * 3;
              grid.contentY = Math.max(0, Math.min(grid.contentHeight - grid.height, grid.contentY - dy));

              var instVel = (dy / dt) * 1000;
              wheelHandler.velocity = Math.max(-6000, Math.min(6000, wheelHandler.velocity * 0.3 + instVel * 0.7));

              // Only a fallback: a compositor that sends no ScrollEnd still
              // gets its glide, a little later.
              releaseTimer.restart();
              event.accepted = true;
              return;
            }

            // A mouse wheel stays as it was: one notch, one step, no coasting.
            momentumTimer.stop();
            releaseTimer.stop();
            wheelHandler.velocity = 0;
            var wheelDy = (event.angleDelta.y / 120) * 140;
            grid.contentY = Math.max(0, Math.min(grid.contentHeight - grid.height, grid.contentY - wheelDy));
            event.accepted = true;
          }
        }

        readonly property int columns: Math.max(1, Math.floor((width - 40 + root.gap) / (root.cell + root.gap)))
        // The slider sets the size to aim for; the row then divides the width
        // it actually has between that many tiles, so both edges stay flush
        // whatever the window does and resizing only changes the tiles a
        // little rather than leaving a ragged strip on the right.
        readonly property real cellFit: (width - 40 - (columns - 1) * root.gap) / columns

        // Scroll position to hold while a rebuild changes the content height.
        property real restoreY: -1
        property var pendingAnchor: null

        function clampY(y) { return Math.max(0, Math.min(contentHeight - height, y)); }
        function scrollToBottom() {
          contentY = Math.max(0, contentHeight - height);
        }
        function tileTop(dayIndex, position) {
          var section = daysRepeater.itemAt(dayIndex);
          if (!section) return -1;
          var point = section.mapToItem(contentItem, 0, 0);
          return point.y + section.labelHeight + 10 + Math.floor(position / columns) * (cellFit + root.gap);
        }
        function captureAnchor() {
          if (root.items.length === 0) return null;
          for (var d = 0; d < root.days.length; d++) {
            var group = root.days[d];
            var first = tileTop(d, 0);
            if (first < 0) continue;
            var rows = Math.ceil(group.indices.length / columns);
            if (first + rows * (cellFit + root.gap) < contentY) continue;
            var row = Math.max(0, Math.min(rows - 1, Math.floor((contentY - first) / (cellFit + root.gap))));
            var index = group.indices[row * columns];
            return { id: root.items[index].id, offset: contentY - tileTop(d, row * columns) };
          }
          return null;
        }
        function restorePendingAnchor() {
          if (!pendingAnchor || root.pinBottom) return;
          for (var d = 0; d < root.days.length; d++) {
            var group = root.days[d];
            for (var p = 0; p < group.indices.length; p++) {
              if (root.items[group.indices[p]].id !== pendingAnchor.id) continue;
              var top = tileTop(d, p);
              if (top < 0) return;
              contentY = clampY(top + pendingAnchor.offset);
              restoreY = -1;
              pendingAnchor = null;
              return;
            }
          }
          pendingAnchor = null;
        }
        function priorityIds() {
          var candidates = [];
          var low = Math.max(0, contentY - height);
          var high = contentY + 2 * height;
          var center = contentY + height / 2;
          for (var d = 0; d < root.days.length; d++) {
            var group = root.days[d];
            var first = tileTop(d, 0);
            if (first < 0) continue;
            var rows = Math.ceil(group.indices.length / columns);
            if (first > high) break;
            if (first + rows * (cellFit + root.gap) < low) continue;
            var firstRow = Math.max(0, Math.floor((low - first) / (cellFit + root.gap)));
            var lastRow = Math.min(rows - 1, Math.ceil((high - first) / (cellFit + root.gap)));
            for (var row = firstRow; row <= lastRow; row++) {
              var distance = Math.abs(first + row * (cellFit + root.gap) + cellFit / 2 - center);
              for (var col = 0; col < columns; col++) {
                var pos = row * columns + col;
                if (pos >= group.indices.length) break;
                var it = root.items[group.indices[pos]];
                if (it && !it.thumb) candidates.push({ id: it.id, distance: distance });
              }
            }
          }
          candidates.sort(function (a, b) { return a.distance - b.distance; });
          return candidates.slice(0, 120).map(function (candidate) { return candidate.id; });
        }
        onContentHeightChanged: {
          if (root.pinBottom) scrollToBottom();
          else if (pendingAnchor) Qt.callLater(function () { grid.restorePendingAnchor(); });
          else if (restoreY >= 0) contentY = clampY(restoreY);
        }
        onHeightChanged: { if (root.pinBottom) scrollToBottom(); priorityTimer.restart(); }
        onWidthChanged: priorityTimer.restart()
        onContentYChanged: priorityTimer.restart()
        onMovementStarted: {
          root.pinBottom = false;
          scrollAnim.stop();
          momentumTimer.stop();
          releaseTimer.stop();
          wheelHandler.velocity = 0;
        }

        NumberAnimation {
          id: scrollAnim
          target: grid
          property: "contentY"
          duration: 130
          easing.type: Easing.OutQuad
        }

        function reveal(thumb) {
          if (root.pinBottom || root.suppressReveal) return;
          momentumTimer.stop();
          releaseTimer.stop();
          wheelHandler.velocity = 0;
          var p = thumb.mapToItem(grid.contentItem, 0, 0);
          var top = p.y - 44;      // keep the day label in view when moving up
          var bottom = p.y + thumb.height + 16;
          var target = contentY;
          if (top < contentY) target = Math.max(0, top);
          else if (bottom > contentY + height) target = Math.min(contentHeight - height, bottom - height);
          if (target !== contentY) {
            scrollAnim.stop();
            scrollAnim.from = grid.contentY;
            scrollAnim.to = target;
            scrollAnim.start();
          }
        }

        // Day sections keep their calculated height, but thumbnails are only
        // instantiated near the viewport. Keyboard jumps can still reveal a
        // selected item before its section's Loader becomes active.
        function revealIndex(index) {
          if (index < 0 || root.pinBottom || root.suppressReveal) return;
          for (var d = 0; d < root.days.length; d++) {
            var pos = root.days[d].indices.indexOf(index);
            if (pos < 0) continue;
            var section = daysRepeater.itemAt(d);
            if (!section) return;
            var point = section.mapToItem(grid.contentItem, 0, 0);
            var top = point.y + section.labelHeight + 10 + Math.floor(pos / columns) * (cellFit + root.gap);
            var target = contentY;
            if (top - 44 < contentY) target = Math.max(0, top - 44);
            else if (top + cellFit + 16 > contentY + height)
              target = Math.min(contentHeight - height, top + cellFit + 16 - height);
            if (target !== contentY) {
              scrollAnim.stop(); scrollAnim.from = contentY; scrollAnim.to = target; scrollAnim.start();
            }
            return;
          }
        }

        Column {
          id: column
          x: 20
          y: 16
          width: grid.width - 40
          spacing: 22

          Row {
            spacing: 12
            Text {
              text: root.sectionTitle()
              color: appTheme.brightForeground
              font.family: appTheme.fontFamily
              font.pixelSize: 19
              font.bold: true
            }
            Text {
              anchors.baseline: parent.children[0].baseline
              text: root.items.length + (root.items.length === 1 ? " item" : " items")
              color: appTheme.darkForeground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize
            }
            Text {
              anchors.baseline: parent.children[0].baseline
              text: root.busy ? "Syncing…" : ""
              color: appTheme.accent
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize
            }
          }

          Repeater {
            id: daysRepeater
            model: root.days
            delegate: Column {
              id: dayBlock
              required property var modelData
              readonly property real labelHeight: dayTitle.implicitHeight
              width: column.width
              spacing: 10

              Text {
                id: dayTitle
                text: modelData.label + "  "
                color: appTheme.brightForeground
                font.family: appTheme.fontFamily
                font.pixelSize: appTheme.fontSize + 1
                font.bold: true
                Text {
                  anchors.left: parent.right
                  anchors.baseline: parent.baseline
                  text: modelData.indices.length
                  color: appTheme.darkForeground
                  font.family: appTheme.fontFamily
                  font.pixelSize: appTheme.fontSize
                }
              }

              Loader {
                width: parent.width
                height: Math.ceil(modelData.indices.length / grid.columns) * (grid.cellFit + root.gap) - root.gap
                active: dayBlock.y + column.y + height >= grid.contentY - grid.height &&
                        dayBlock.y + column.y <= grid.contentY + 2 * grid.height
                sourceComponent: Flow {
                  width: dayBlock.width
                  spacing: root.gap
                  Repeater {
                    model: dayBlock.modelData.indices
                    delegate: Thumb {
                      required property int modelData
                      index: modelData
                      item: root.items[modelData]
                      downloading: !!root.items[modelData] && root.downloadingId === root.items[modelData].id
                      syncing: root.busy
                      theme: appTheme
                      size: grid.cellFit
                      selected: root.selected === modelData
                      checked: !!root.items[modelData] && root.checked[root.items[modelData].id] === true
                      onSelectedChanged: if (selected) grid.reveal(this)
                      onContextMenuRequested: (x, y) => root.showCopyMenu(this, x, y, index)
                      onMenuRequested: (x, y) => root.showCopyMenu(this, x, y, index)
                      onFavoriteRequested: root.toggleFavorite(root.items[index])
                      onClicked: modifiers => {
                        root.pinBottom = false;
                        if (modifiers & Qt.ShiftModifier) root.jumpTo(index, true);
                        else if (modifiers & Qt.ControlModifier) { root.selected = index; root.toggleChecked(index); }
                        else if (root.selected === index && root.checkedCount === 0) root.viewerOpen = true;
                        else root.jumpTo(index, false);
                      }
                    }
                  }
                }
              }
            }
          }
        }

      }

      // Empty / first-run state. A sibling of the grid rather than a child:
      // children of a Flickable live in its content item, which is only as
      // tall as the content, so "centered" would sit at the top.
      Column {
        anchors.centerIn: grid
        spacing: 10
        visible: root.items.length === 0 && !root.needLogin
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.albumLoading && root.activeSection.indexOf("album:") === 0 ? "Loading album…" : root.busy ? "First sync…" : (root.indexMissing ? "Nothing synced yet" : "No items in " + root.sectionTitle())
          color: appTheme.foreground
          font.family: appTheme.fontFamily
          font.pixelSize: 16
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.busy ? "Items will appear as metadata arrives" : (root.searchText ? "Try a different search" : "Press r to sync, ? for the keys")
          color: appTheme.darkForeground
          font.family: appTheme.fontFamily
          font.pixelSize: appTheme.fontSize
        }
      }

      // ---- Footer ---------------------------------------------------------
      Rectangle {
        id: footer
        anchors.left: sidebar.right
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 34
        color: appTheme.darkBackground
        // The filename is a button: click copies the full path.
        Row {
          anchors.left: parent.left
          anchors.leftMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          spacing: 12
          Text {
            id: footerName
            anchors.verticalCenter: parent.verticalCenter
            text: root.checkedCount > 1 ? root.checkedCount + " selected" : (root.current ? root.current.name : "")
            color: root.checkedCount > 1 ? appTheme.accent : (nameArea.containsMouse ? appTheme.brightForeground : appTheme.darkForeground)
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize - 1
            font.underline: nameArea.containsMouse
            MouseArea {
              id: nameArea
              anchors.fill: parent
              anchors.margins: -4
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.copyPath()
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.checkedCount > 1 ? "esc clears" : (root.current ? root.current.time : "")
            color: appTheme.darkForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize - 1
          }
        }
        Row {
          anchors.right: parent.right
          anchors.rightMargin: 20
          anchors.verticalCenter: parent.verticalCenter
          spacing: 18
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 24; height: 24; radius: 5
            color: helpArea.containsMouse ? appTheme.lighterBackground : "transparent"
            Text {
              anchors.centerIn: parent
              text: "?"
              color: appTheme.darkForeground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize
              font.bold: true
            }
            MouseArea {
              id: helpArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.helpOpen = !root.helpOpen
            }
          }
          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf03e"
              color: appTheme.darkForeground
              font.family: appTheme.fontFamily
              font.pixelSize: 9
            }
            Slider {
              id: zoom
              anchors.verticalCenter: parent.verticalCenter
              width: 140
              from: 100
              to: 400
              stepSize: 4
              value: root.cell
              onMoved: root.setCell(value)
              background: Rectangle {
                x: zoom.leftPadding
                y: zoom.topPadding + zoom.availableHeight / 2 - height / 2
                width: zoom.availableWidth
                height: 3
                radius: 2
                color: appTheme.lighterBackground
                Rectangle {
                  width: zoom.visualPosition * parent.width
                  height: parent.height
                  radius: 2
                  color: appTheme.accent
                }
              }
              handle: Rectangle {
                x: zoom.leftPadding + zoom.visualPosition * (zoom.availableWidth - width)
                y: zoom.topPadding + zoom.availableHeight / 2 - height / 2
                width: 12; height: 12; radius: 6
                color: zoom.pressed ? appTheme.brightForeground : appTheme.foreground
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf03e"
              color: appTheme.darkForeground
              font.family: appTheme.fontFamily
              font.pixelSize: 14
            }
          }
        }
      }

      // ---- Viewer overlay -------------------------------------------------
      Viewer {
        id: viewer
        anchors.fill: parent
        theme: appTheme
        item: root.viewerOpen ? root.current : null
        downloadState: root.current && root.current.id === root.downloadingId ? "downloading" :
                       root.current && root.videoPreparing && root.current.id === videoPrepare.itemId ? "preparing" :
                       root.current && !root.current.downloaded &&
                       (root.current.id === root.failedDownloadId || root.current.state === "failed") ? "failed" : ""
        downloadMessage: root.downloadError || (root.current ? (root.current.error || "") : "")
        downloadComponent: root.downloadingComponent
        downloadPercent: root.downloadPercent
        infoOpen: root.infoOpen
        infoRows: (root.current && root.infoForId === root.current.id) ? root.infoRows : []
        onRequestInfo: root.toggleInfo()
        onRequestNext: root.move(1)
        onRequestPrev: root.move(-1)
        onRequestCopyPath: root.copyPath()
        onRequestSave: root.saveToDownloads()
        onRequestDownload: if (root.current) root.current.downloaded ? root.keepOffline(root.current) : root.ensureOriginal(root.current)
        onRequestRetry: if (root.current) {
          if (root.current.kind === "video") root.playVideo(root.current);
          else root.ensureOriginal(root.current, null, root.downloadingComponent === "motion" ? "motion" : "original");
        }
        onRequestCancel: root.cancelDownload()
        onRequestMotion: if (root.current) root.ensureOriginal(root.current, function () { viewer.playLive(); }, "motion")
        onRequestVideo: if (root.current) root.playVideo(root.current)
        onContextMenuRequested: (x, y) => root.showCopyMenu(viewer, x, y, -1)
      }

      // ---- Sign-in ----------------------------------------------------------
      Rectangle {
        anchors.top: header.bottom
        anchors.left: sidebar.right
        anchors.right: parent.right
        anchors.bottom: footer.top
        visible: root.needLogin
        color: appTheme.background
        MouseArea { anchors.fill: parent; hoverEnabled: true }
        Login {
          id: loginCard
          anchors.fill: parent
          theme: appTheme
          username: root.appleId
          onSubmitCredentials: (u, p) => root.startLogin(u, p)
          onSubmitCode: code => login.write(code + "\n")
        }
      }

      // ---- Delete dialog --------------------------------------------------
      ConfirmDelete {
        anchors.fill: parent
        theme: appTheme
        items: root.pendingDelete
        onConfirmed: root.confirmDelete()
        onCancelled: root.pendingDelete = null
      }

      // ---- Help -------------------------------------------------------------
      Help {
        anchors.fill: parent
        theme: appTheme
        visible: root.helpOpen
        onRequestClose: root.helpOpen = false
      }

      // ---- Toast, with an Undo button after a delete ----------------------
      Rectangle {
        id: toast
        property string message: ""
        property bool undo: false
        property bool busy: false
        function show(m, ms) { message = m; undo = false; busy = false; opacity = 1; hide.interval = ms || 1600; hide.restart(); }
        function showUndo(m) { message = m; undo = true; busy = false; opacity = 1; hide.interval = 12000; hide.restart(); }
        function showBusy(m) { message = m; undo = false; busy = true; opacity = 1; hide.stop(); }
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 56
        width: toastRow.implicitWidth + 32
        height: 40
        radius: 8
        color: appTheme.lighterBackground
        opacity: 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
        Row {
          id: toastRow
          anchors.centerIn: parent
          spacing: 16
          Text {
            visible: toast.busy
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf021"
            color: appTheme.accent
            font.family: appTheme.fontFamily
            font.pixelSize: 13
            RotationAnimation on rotation {
              running: toast.busy; loops: Animation.Infinite; from: 0; to: 360; duration: 1400
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: toast.message
            color: appTheme.brightForeground
            font.family: appTheme.fontFamily
            font.pixelSize: appTheme.fontSize
          }
          Rectangle {
            visible: toast.undo
            anchors.verticalCenter: parent.verticalCenter
            width: undoText.implicitWidth + 20
            height: 26
            radius: 5
            color: undoArea.containsMouse ? Qt.lighter(appTheme.accent, 1.1) : appTheme.accent
            Text {
              id: undoText
              anchors.centerIn: parent
              text: "Undo  u"
              color: appTheme.darkerBackground
              font.family: appTheme.fontFamily
              font.pixelSize: appTheme.fontSize
              font.bold: true
            }
            MouseArea {
              id: undoArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.undoDelete()
            }
          }
        }
        Timer { id: hide; interval: 1600; onTriggered: toast.opacity = 0 }
      }
    }
  }
}
