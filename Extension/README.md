# Rivulet browser extension

Sends browser downloads to a running aria2 daemon over JSON-RPC and shows a small
status popup. One codebase for Chrome (Manifest V3 service worker) and Firefox 128+
(Manifest V3 event page). No dependencies and no bundler: plain ES modules, HTML and CSS.

## Build

```sh
./build.sh          # writes dist/chrome and dist/firefox
./build.sh --zip    # also writes dist/rivulet-chrome.zip and dist/rivulet-firefox.zip
```

The build copies `src/` and the matching `manifest.<browser>.json` (as `manifest.json`)
into each folder. Icons are regenerated with `swift tools/make-icons.swift src/icons`.

## Load unpacked

Chrome (and other Chromium browsers): open `chrome://extensions`, enable Developer mode,
click "Load unpacked" and choose `dist/chrome`.

Firefox 128 or newer: open `about:debugging#/runtime/this-firefox`, click "Load Temporary
Add-on" and choose `dist/firefox/manifest.json`. Temporary add-ons are removed when
Firefox quits. Accept the host permission prompt if shown, since the extension needs it
to reach the RPC endpoint (Firefox: Add-ons Manager, Rivulet, Permissions).

## Enable aria2 RPC

Add this to `~/.aria2/aria2.conf` (or pass the flags to `aria2c`):

```
enable-rpc=true
rpc-listen-port=6800
rpc-secret=choose-a-secret
```

Restart aria2, then open the extension options, enter the URL (default
`http://localhost:6800/jsonrpc`) and the secret, and press Test Connection.

The extension declares `<all_urls>` host permissions, which lets its pages and
background script call the RPC endpoint directly without CORS checks. You do not need
`rpc-allow-origin-all`, and it is better left off.

## Behavior notes

- Downloads that pass your filters are cancelled and erased in the browser, then added
  with `aria2.addUri` together with cookies, referer and user agent. Only http and https
  URLs are intercepted; blob, data, file and other schemes stay with the browser.
- If aria2 cannot be reached, the download is restarted in the browser, a notification
  is shown and the toolbar badge shows "!".
- Right-click a link, image, video or audio element and choose "Send to Rivulet (aria2)".
  Magnet links go through `aria2.addUri`; links ending in `.torrent` are fetched and sent
  with `aria2.addTorrent` so the torrent itself is downloaded rather than the file.
- The secret is kept in `storage.local` in plain text, like any other extension setting.
- The "Open Rivulet" button opens `rivulet://open`, which the macOS app must register.
