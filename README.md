<p align="center">
  <img src="assets/icon.png" width="96" height="96" alt="">
</p>

<h1 align="center">Omarchy iCloud Photos</h1>

<p align="center">Your iCloud Photos library as a native window on <a href="https://omarchy.org">Omarchy</a>.<br>Browse local thumbnails by day and download originals when needed.</p>

<p align="center">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue?style=flat-square"></a>
  <img alt="Quickshell" src="https://img.shields.io/badge/ui-Quickshell-7aa2f7?style=flat-square">
  <img alt="Omarchy 4+" src="https://img.shields.io/badge/omarchy-4.0%2B-9ece6a?style=flat-square">
  <img alt="sync by icloudpd" src="https://img.shields.io/badge/sync-icloudpd-e0af68?style=flat-square">
</p>

<p align="center">
  <img src="assets/social.gif" width="800" alt="The window scrolling through a week of photos, then opening one">
</p>

<p align="center"><sub>The clip and the screenshots come from the built-in demo mode, so those are Omarchy wallpapers, not anyone's holiday. <a href="assets/social.mp4">MP4 version</a>.</sub></p>

> **Credit where it is due.** The syncing is done by [icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader), the iCloud Photos Downloader by the icloud-photos-downloader project. I did not write it and this repository does not fork it. What you find here is the window, the index, the sign-in and delete helper on top of its pyicloud module, and the glue between them.

## Install

The quickest way is to let your coding agent do it. Paste this into Claude Code, Codex or whatever runs your terminal:

> Install Omarchy iCloud Photos from https://github.com/jankeesvw/omarchy-icloud-photos on this Omarchy machine. Install the pacman packages quickshell, imagemagick, ffmpeg, jq and wl-clipboard if they are missing. Clone the repository into ~/Documents/github.com/jankeesvw/omarchy-icloud-photos and run its install.sh; it needs no root and fetches icloudpd and a Python 3.13 itself. Then start `omarchy-icloud-photos` and tell me it is ready for me to sign in; the sign-in happens inside the window and you never need my password. Do not run icloudpd with `--auto-delete` or `--keep-omarchy-icloud-photos-days`, and do not change the config beyond what install.sh writes.

<details>
<summary>By hand</summary>

```bash
sudo pacman -S --needed quickshell imagemagick ffmpeg jq wl-clipboard
git clone https://github.com/jankeesvw/omarchy-icloud-photos.git ~/Documents/github.com/jankeesvw/omarchy-icloud-photos
~/Documents/github.com/jankeesvw/omarchy-icloud-photos/install.sh
```

The installer links the launcher and the sync script into `~/.local/bin`, adds "Omarchy iCloud Photos" to the app launcher, fetches the icloudpd binary into `~/.local/bin` when it is not installed already, creates a small Python virtualenv for the iCloud helper (a 3.13 from mise when the system Python is newer) and enables the sync timer. Nothing after the pacman line needs root.

Then start `omarchy-icloud-photos`, or pick "Omarchy iCloud Photos" in the launcher, and sign in. Apple ID and password first, then the six-digit code from your phone.
 The first sync takes a few minutes. Run `install.sh` again after a `git pull`; everything is linked, not copied.

</details>

## Why

Apple does not make an iCloud Photos client for Linux. This app keeps a local catalog and thumbnails for the accessible library, then downloads original media when you request it or an action requires it. The Quickshell window shows the library by day, newest at the bottom, in your Omarchy theme.

![The grid: a week of photos and videos grouped by day, in the Tokyo Night theme](assets/screenshot.jpg)

## What it does

- **Grid by day.** Photos, videos and Live Photos from the full accessible library, grouped by day with the newest at the bottom. Thumbnails scale with a slider. A missing thumbnail gets a placeholder.
- **Library navigation.** The sidebar shows Library, Favorites, Recents, Downloaded, Videos, Live Photos, and Shared Library from catalog metadata. Recents uses iCloud's added date when available; unknown dates and Favorites stay unknown. The top bar provides grid controls, sync, export, download, Favorites, cloud delete, actions, and a local filename search. Hover a tile for its `…` menu. The cloud badge marks items whose original is not downloaded.
- **Preview first.** Opening an item shows its cached thumbnail or video poster without downloading full media. The viewer's bottom-right **Download original** button stores a local copy; **Save copy** exports to `~/Downloads`. Playing a cloud-only video or clicking a cloud-only Live Photo's motion control requests that component when needed.
- **Shared Library too.** Accessible Shared Library zones appear in the same grid with a person mark. Each catalog identity includes its account and zone, so duplicate filenames and record IDs stay distinct.
- **Originals on demand.** The viewer opens cached previews first. Downloading, playing, saving, or opening externally fetches the required original once. Live Photo motion is a separate download. The viewer shows progress, cancellation, failure and retry.
- **Local eviction.** `e` or the context menu's “Remove local download — keep in iCloud” action removes app-owned full media for one item or a selection while keeping its catalog entry and thumbnail. `d` remains the separate, confirmed cloud Recently Deleted action.
- **Photo actions.** The hover `…` menu and right-click offer Download Original, Save Copy, Copy, Open Externally, Start Slideshow, local eviction, and the existing confirmed cloud delete. Album editing, hiding, and shared-link creation are not exposed by the installed cloud interface, so those controls are not shown.
- **Viewer.** Full-window stills, video with a timeline, and Live Photo motion on request. `i` shows available details. Missing cloud metadata stays unknown.
- **Delete with undo.** `d` moves an item, or a selection, to iCloud's Recently Deleted, the same 30-day bin the Photos app uses. Undo brings it back, from the toast or with `u`. Nothing here can empty that bin.
- **Copy and save.** `Ctrl+C`, `y`, or right-click → Copy puts the image on the clipboard as PNG from either the grid or the viewer, including for HEIC originals, so browsers can paste it as an image. Multiple selections in the grid copy as a list of files in their original image formats; the viewer copies only the opened image. Right-clicking a selected photo keeps the selection, while right-clicking another photo selects that one. `s` and **Save copy** put a copy in `~/Downloads` as JPEG or MP4, whatever the original was. Clicking the filename copies its full path.
- **Signs in by itself.** Apple ID, password and the two-factor code go into the window on first run and whenever the session expires. The password is only used to open the session and is never stored.
- **Wallpaper.** `W` makes the current photo the Omarchy background, HEIC included.
- **Stays in sync.** A systemd user timer pulls new items every 30 minutes. An open window picks them up on its own.
- **Bounded previews.** `bin/omarchy-icloud-photos-sync --max-items 200` catalogs only the first 200 cloud records and their thumbnails. It does not mark the scan complete or remove unseen records. Set `OMARCHY_ICLOUD_PHOTOS_MAX_SYNC_ITEMS=200` for a preview window so its Sync button uses the same cap.
- **Follows your theme.** Colours come live from Omarchy's `colors.toml`; switch themes and the window switches with you.

## A look around

Every picture here is the whole window, taken from the demo library.

<table>
<tr>
<td width="50%"><img src="assets/live.jpg" alt="A Live Photo in the viewer, the ring top-left lit while the clip plays"><br><sub>A Live Photo: hover the ring top-left and the clip plays once.</sub></td>
<td width="50%"><img src="assets/details.jpg" alt="The viewer with the details panel open"><br><sub><code>i</code>: camera, lens, focal length, aperture, shutter, ISO, size and location.</sub></td>
</tr>
<tr>
<td><img src="assets/delete.jpg" alt="The delete dialog over the grid"><br><sub><code>d</code> asks first, with the picture in the dialog.</sub></td>
<td><img src="assets/undo.jpg" alt="The grid with the toast offering Undo after a delete"><br><sub>Then it is gone, with an Undo button for twelve seconds and <code>u</code> after that.</sub></td>
</tr>
<tr>
<td><img src="assets/select.jpg" alt="A range of tiles ticked in the grid"><br><sub>Shift selects a range, ctrl-click or <code>x</code> ticks one more; <code>y</code>, <code>s</code> and <code>d</code> then act on all of them.</sub></td>
<td><img src="assets/keys.jpg" alt="The keyboard overlay"><br><sub><code>?</code> lists every key.</sub></td>
</tr>
<tr>
<td><img src="assets/video.jpg" alt="A video in the viewer with the timeline underneath"><br><sub>Video with a timeline to scrub. HDR from the phone plays with the right colours.</sub></td>
<td><img src="assets/signin.jpg" alt="The sign-in card asking for the verification code"><br><sub>Sign-in lives in the window: Apple ID, password, then the six-digit code.</sub></td>
</tr>
</table>

## Built on

The window is the only new thing here; the plumbing is existing, well-worn tools by other people.

- **[icloudpd](https://github.com/icloud-photos-downloader/icloud_photos_downloader)** provides the pyicloud API and sign-in session. The catalog requests specific cloud versions through that installed library.
- **pyicloud**, the module that ships inside icloudpd, handles sign-in with two-factor and the per-asset delete and restore, from a small Python helper in the repository's own virtualenv.
- **SQLite** persists account- and zone-scoped cloud identities, metadata, download state and local file ownership. A JSON index feeds the QML window.
- **ImageMagick** with libheif makes the thumbnails and the JPEG previews of HEIC originals, which Qt cannot decode.
- **ffmpeg** grabs video poster frames and, when you ask for it, tone-maps an HDR video (HLG or PQ) to an SDR H.264 copy for playback, since Qt's player does no tone mapping.
- **[Quickshell](https://quickshell.org)** on Qt 6 renders the window in QML, with QtMultimedia for video.
- **systemd** user units run the sync every 30 minutes at low priority.

## Safety first

Synchronization reads metadata and thumbnail versions and never falls back to full media. Local eviction only removes regular files in the app-owned original cache and tracked derived caches. Existing icloudpd backup files can be recognized in place but are never deleted by eviction; the control is unavailable for those items. The separate `d` action flips an asset's `isDeleted` flag after the existing confirmation; Shared Library deletion affects its shared Recently Deleted folder. No operation empties Recently Deleted.

It talks to iCloud through the same unofficial web API icloudpd uses. Apple can change that at any time, and Apple shuts the sign-in door for a while after several sign-ins in a short time; when that happens the card says so, and the only cure is to leave it alone for half an hour, since every attempt extends the wait. When something breaks, the window says so.

## Keys

Press `?` in the app for this list.

| Key | Grid | Viewer |
|---|---|---|
| `h` `j` `k` `l`, arrows | move | previous / next |
| `Shift` + move, shift-click | select a range | |
| `Ctrl` + click, `x`, `Ctrl` + `Space` | add or remove one | |
| `Ctrl` + `a` | select all | |
| `Enter`, `Space` | open the viewer | pause or resume a video, play a Live Photo once |
| `←` / `→` | move | seek 5 seconds |
| `d` / `u` | delete, undo | same |
| `e` | remove local download, keep in iCloud | same |
| `Ctrl+C` / `y` | copy image or selected files | copy opened image |
| right-click → Copy | copy image or selected files | copy opened image |
| `Y` | copy path | same |
| `s` | save to `~/Downloads` as JPEG or MP4 | same |
| `o` | open in the default app | same |
| `W` | set as the Omarchy wallpaper | same |
| `r` | sync now | |
| `-` / `+` | smaller, larger thumbnails | |
| `g` / `G` | oldest, newest | |
| `i` | | camera, lens, shutter, ISO, size, location |
| `?` | show the keys | same |
| `Esc`, `q` | clear the selection, quit | back to the grid |

A click selects, a second click on the selected item opens it. Hovering does nothing.

## Configuration

`~/.config/omarchy-icloud-photos/config` is sourced by the sync script.

| Variable | Default | Meaning |
|---|---|---|
| `APPLE_ID` | set by the sign-in card | The account to sync |
| `LIBRARY` | `~/Pictures/iCloud` | Existing icloudpd originals are recognized here once, without moving them; new on-demand originals use the app cache |
| `SHARED_LIBRARY` | `auto` | `auto` syncs the Shared Library your account is in, `no` leaves it out, a `SharedSync-…` name from `icloudpd --list-libraries` picks one |
| `COOKIES` | `~/.config/icloudpd` | Where the iCloud session lives |
| `XDG_CACHE_HOME` | `~/.cache` | The app uses its `omarchy-icloud-photos` subdirectory for SQLite, thumbnails, derived previews and app-owned originals |
| `SKIP_TIMER` | unset | Set to `1` to keep a manual or isolated test session from enabling the user sync timer after sign-in |
| `LAUNCHER_NAME` | `Omarchy iCloud Photos` | What the app is called in the launcher; re-run `install.sh` after changing it |

The first sync pages through every accessible asset and can take time for a large library. It publishes the first cards after 30 records, then in growing batches or after five seconds. Cards initially show placeholders; a second pass fills in thumbnails without blocking catalog discovery. Routine syncs scan the newest records, with a complete reconciliation at least weekly or on `omarchy-icloud-photos-sync --full`. An interrupted initial scan starts again safely; completed catalog rows and thumbnails remain. Original files are fetched only by explicit item actions.

The same session also works from the command line, for a headless box or when you prefer a terminal:

```bash
icloudpd --auth-only --username you@example.com --cookie-directory ~/.config/icloudpd
```

## Demo mode

`omarchy-icloud-photos --demo` starts the window on a stand-in library built from the Omarchy theme backgrounds: photos, portrait crops, a few slow-pan videos and Live Photo pairs, some of them marked as coming from a Shared Library, spread over the last days. It lives under `~/.cache/omarchy-icloud-photos-demo`, apart from your real config and cache, and nothing in it talks to iCloud, so delete and undo can be tried freely. That is what the screenshots are made with. `omarchy-icloud-photos-demo --reset` rebuilds it, and `omarchy-icloud-photos --demo --tour` scrolls through the grid by itself and opens a photo, for recording a clip.

## How it works

`bin/omarchy-icloud-photos-sync` invokes the catalog worker. It pages through the personal and selected shared libraries using the installed pyicloud album iterator. A stable key is derived from the account, zone and cloud record name; no expiring download URL is stored in SQLite. Capture instants and explicit timezone, dimensions, location and camera fields are preserved when available. Thumbnails are fetched only from JPEG thumbnail resources. Video items without a JPEG poster show a placeholder rather than downloading a video proxy.

The catalog publishes `index.json` and `status.json` for Quickshell. Initial catalog creation is a full scan; routine refresh stops after two pages of known items and a weekly full reconciliation catches older changes. Downloads stream into `.part` files and become visible only after completion. The downloader and local eviction share a per-item lock. Existing originals in `LIBRARY` are matched once by zone, filename and capture time, then treated as unowned; ambiguous matches are left cloud-only.

An HDR video can be converted to an app-owned SDR playback copy after its original is downloaded with `omarchy-icloud-photos-sync --convert ID`, or `--convert-all` for downloaded videos. The latter waits for AC power unless passed `--force`. Conversion updates the catalog index and does not scan the backup folders.

The catalog uses the album, version and authenticated download interfaces in the installed `icloudpd` 1.32.3 pyicloud package. It does not require a new dependency. iCloud's private API can change; a video without an exposed JPEG poster intentionally remains a placeholder until its full media is downloaded for playback.

The legacy demo indexer still recognizes both `X_HEVC.MOV` beside a still and a plain `X.MOV` beside a JPEG still for Live Photos. One-time adoption of existing backup originals follows the same pairing rules.

`bin/icloud_helper.py` is the only code that talks to iCloud beyond downloading: it signs in, and it moves one asset at a time to Recently Deleted or back, in whichever library it came from. The Shared Library sits in the owner's private database next to the personal one and in the shared database of everyone who joined, so the helper looks in both. It runs on the pyicloud module that ships with icloudpd, in the repository's own virtualenv.

```
bin/omarchy-icloud-photos          launcher: quickshell -p ui/shell.qml (--demo, --tour)
bin/omarchy-icloud-photos-sync     catalog and thumbnail sync
bin/omarchy-icloud-photos-catalog  explicit original download and local eviction
bin/library_catalog.py            SQLite catalog and pyicloud version selection
bin/omarchy-icloud-photos-demo     builds the demo library from the theme backgrounds
bin/omarchy-icloud-photos-info     camera and file details for the viewer's i panel
bin/omarchy-icloud-photos-helper   wrapper that runs icloud_helper.py in .venv
bin/icloud_helper.py       login, and find / delete / restore one asset
ui/shell.qml               window, grid, key handling
ui/Thumb.qml               one grid cell
ui/Viewer.qml              full-window still / video with timeline
ui/ConfirmDelete.qml       the "move to Recently Deleted?" dialog
ui/Login.qml               sign-in card (Apple ID, password, 2FA code)
ui/Help.qml                the ? overlay
ui/Theme.qml               colours from ~/.local/state/omarchy/current/theme/colors.toml
systemd/                   user service + 30 minute timer
install.sh                 links everything into place
```

## Contributing

Issues and pull requests are welcome. Run `omarchy-icloud-photos --demo` to work on the window without an Apple account. For a larger isolated grid, run `python tests/synthetic_ui.py /tmp/icloud-ui-check` and launch Quickshell with that fixture's `XDG_CONFIG_HOME` and `XDG_CACHE_HOME`. Unit tests use mocked cloud responses and never contact iCloud.

## License

MIT. icloudpd, Quickshell and the other tools have their own licenses.
