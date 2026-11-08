# Rivulet

A lightweight, native macOS front end for the [aria2](https://aria2.github.io) download daemon, modelled on the
Transmission Mac app, with a JDownloader style Link Grabber and site plugins, plus a browser extension for Chrome
and Firefox that sends browser downloads to aria2.

Status: beta (0.2.0).

## What is here

| Path | What it is |
|---|---|
| `Sources/Rivulet` | The app: SwiftUI, no third-party dependencies |
| `Sources/RivuletCore` | aria2 RPC client, models, daemon manager, resolver and plugin engine, rules, feeds, accounts, schedule |
| `Resources/Plugins` | Bundled site plugins (JavaScript) |
| `Extension/` | One WebExtension codebase for Chrome (MV3) and Firefox 128+ |
| `docs/PLUGINS.md` | How to write a site plugin |
| `Scripts/` | `build_app.sh`, `bundle_aria2.sh`, `notarize.sh` |

## The app

- Transmission style main window: customizable toolbar, filter bar with counts and search, transfer rows, status bar
  with the alternate speed (tortoise) toggle and live speeds. Menu bar item with live speed and quick actions.
- Inspector panel: Info, Activity (with piece map and availability), Peers (with flags), Files and Options.
- Direct downloads, torrents, magnet links and metalinks. Handles `magnet:` links and `.torrent` files.
- Dock badge, completion and failure notifications, speed limits, queue size and seed ratio.
- Starts and manages its own `aria2c` (bundled in release builds), or connects to one that is already running.
- `rivulet://add?url=...` queues a link, which makes it easy to drive from Shortcuts or scripts.

### Link Grabber and site plugins

Open it from the toolbar, the menu bar, or File, Link Grabber (Command G). Paste a page, album or folder link and
Rivulet expands it into the files inside, checks which are online, shows sizes, and lets you pick what to download
into package folders. Optionally it opens by itself when you copy a link from a supported site.

- Site support comes from small JavaScript plugins run in the macOS JavaScript engine in a sandbox: they can make
  HTTP requests and parse text and nothing else. See `docs/PLUGINS.md`.
- Plugins live in `~/Library/Application Support/Rivulet/Plugins` (yours win) and inside the app (bundled).
- Preferences, Sources can check a plugin index for updates. Each download is verified against a checksum first.
- Optional fallback to `yt-dlp` (install it with Homebrew) for sites without a plugin.
- Accounts for sites that need a login are stored in the macOS Keychain.

### Torrents

- Choose which files to download, before a torrent starts (also after a magnet finishes fetching its metadata) and
  later from the Files tab.
- Trackers: add extra trackers to one torrent, or to all of them, optionally from a public tracker list
  (off by default, fetched from GitHub once a week when on).
- Piece map, availability, peer flags, per-torrent seed ratio, encryption requirement, peer limits, DHT, peer
  exchange and local discovery switches.
- Verify local data and move data to another folder while keeping the torrent seeding (needs the `.torrent`, which
  Rivulet keeps for torrents added while it is open).
- aria2 has no IP blocklist feature, so there is none here.

### Automation

- **Rules** run when a transfer finishes: rename, extract archives (zip, tar, 7z, rar), move, run a Shortcut,
  open, reveal, trash. Torrents count as finished once they stop seeding.
- **Feeds**: subscribe to RSS or Atom feeds, filter by regular expression and size, and new items are downloaded.
- **Schedule**: windows by day and time that apply alternate limits, custom limits, or pause everything.

### Build and run

Requires macOS 14 or later and the Command Line Tools. Xcode is not needed.

```sh
brew install aria2          # needed once to build; the app then carries its own copy
./Scripts/build_app.sh      # produces build/Rivulet.app
open build/Rivulet.app
```

The build script uses the macOS 26.x SDK from the Command Line Tools. The newest SDK needs Xcode's SwiftUI macro
plugin, which is not installed with the Command Line Tools alone. Set `RIVULET_SDK` to override, and
`BUNDLE_ARIA2=0` to skip bundling aria2c.

Unit tests (60):

```sh
swift test --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

Signing and notarization: see `Scripts/notarize.sh`. It needs a Developer ID certificate.

### Connecting

Preferences, Network:

- **Rivulet starts and manages aria2c** (default). Uses port 6800 and a random secret generated on first launch.
  The daemon is stopped when you quit.
- **Connect to an aria2 that is already running.** Enter its host, port and secret.

If another aria2 is already using port 6800 you will see an authentication error. Either switch to the second mode
and enter that daemon's secret, or stop it.

## The extension

See [Extension/README.md](Extension/README.md). In short:

```sh
cd Extension && ./build.sh      # writes dist/chrome and dist/firefox
```

Load `dist/chrome` unpacked in `chrome://extensions`, or `dist/firefox/manifest.json` as a temporary add-on in
`about:debugging`. In its options, set the RPC URL (`http://localhost:6800/jsonrpc`) and the same secret as the app
(Preferences, Network, Copy Secret).

## Known limitations of this beta

- Not signed or notarized unless you provide a Developer ID certificate.
- No Safari extension (needs an Xcode project) and no in-app auto-update (needs a hosted update feed).
- The RPC secret is stored in the app's preferences, not the Keychain. The managed daemon reads it from a
  file readable only by you.
- The extension has not been tested in real browsers, only against a real aria2 daemon at the RPC level.
- Site plugins depend on how websites behave today and will need updating when sites change.
- Some UI paths (menu bar menu, retry button) were not exercised by automated UI checks.
