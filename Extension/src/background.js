// Rivulet background script (MV3 service worker in Chrome, event page in Firefox).
// All listeners are registered synchronously at top level so the worker can be
// woken by any of these events.

import { getSettings, parseExtensions, parseSites, hostMatches } from "./settings.js";
import * as rpc from "./rpc.js";

const api = globalThis.browser ?? globalThis.chrome;

const MENU_ID = "rivulet-send";
const FALLBACK_TTL_MS = 60_000;

// Downloads we re-triggered ourselves after an RPC failure. Never intercept these.
const fallbackIds = new Set();
const fallbackUrls = new Map(); // url -> expiry timestamp

// ---------------------------------------------------------------- helpers

function schemeOf(url) {
  try {
    return new URL(url).protocol;
  } catch {
    return "";
  }
}

function isHttpUrl(url) {
  const p = schemeOf(url);
  return p === "http:" || p === "https:";
}

function hostOf(url) {
  try {
    return new URL(url).hostname;
  } catch {
    return "";
  }
}

function isPlainBasename(name) {
  return (
    typeof name === "string" &&
    name.length > 0 &&
    name !== "." &&
    name !== ".." &&
    !/[\\/\0]/.test(name)
  );
}

function isTorrentUrl(url) {
  try {
    return new URL(url).pathname.toLowerCase().endsWith(".torrent");
  } catch {
    return false;
  }
}

function extensionOf(download) {
  let name = "";
  if (download.filename) {
    name = String(download.filename).split(/[\\/]/).pop();
  }
  if (!name.includes(".")) {
    try {
      name = decodeURIComponent(new URL(download.url).pathname.split("/").pop() || "");
    } catch {
      name = "";
    }
  }
  const i = name.lastIndexOf(".");
  return i >= 0 ? name.slice(i + 1).toLowerCase() : "";
}

function cleanHeaderValue(v) {
  return String(v).replace(/[\r\n]+/g, " ").trim();
}

function rememberFallback(url) {
  const now = Date.now();
  for (const [u, exp] of fallbackUrls) if (exp < now) fallbackUrls.delete(u);
  fallbackUrls.set(url, now + FALLBACK_TTL_MS);
}

function consumeFallback(url) {
  const exp = fallbackUrls.get(url);
  if (exp === undefined) return false;
  fallbackUrls.delete(url);
  return exp >= Date.now();
}

async function cookieHeader(url) {
  try {
    const cookies = await api.cookies.getAll({ url });
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch {
    return "";
  }
}

async function activeTabUrl() {
  try {
    const [tab] = await api.tabs.query({ active: true, lastFocusedWindow: true });
    return tab && isHttpUrl(tab.url) ? tab.url : "";
  } catch {
    return "";
  }
}

let badgeTimer = null;
async function flashBadge(text, color) {
  try {
    await api.action.setBadgeBackgroundColor({ color });
    await api.action.setBadgeText({ text });
    clearTimeout(badgeTimer);
    badgeTimer = setTimeout(() => {
      api.action.setBadgeText({ text: "" }).catch?.(() => {});
    }, 10_000);
  } catch {
    // Badge is best effort.
  }
}

async function notify(title, message) {
  try {
    await api.notifications.create({
      type: "basic",
      iconUrl: api.runtime.getURL("icons/icon-128.png"),
      title,
      message,
    });
  } catch {
    // Notifications are best effort.
  }
}

async function reportUnreachable(err, what) {
  const detail = err && err.message ? err.message : String(err);
  await flashBadge("!", "#d70015");
  await notify("aria2 is unreachable", `${what}\n${detail}`);
}

// ------------------------------------------------------------ aria2 calls

async function buildOptions(settings, url, { referrer = "", filename = "" } = {}) {
  const options = {};
  if (settings.downloadDir) options.dir = settings.downloadDir;
  if (isPlainBasename(filename)) options.out = filename;

  if (isHttpUrl(url)) {
    const header = [];
    const cookies = await cookieHeader(url);
    if (cookies) header.push(`Cookie: ${cleanHeaderValue(cookies)}`);
    const ref = referrer || (await activeTabUrl());
    if (ref) header.push(`Referer: ${cleanHeaderValue(ref)}`);
    header.push(`User-Agent: ${cleanHeaderValue(navigator.userAgent)}`);
    options.header = header;
  }
  return options;
}

async function fetchTorrentBase64(url) {
  const res = await fetch(url, { credentials: "include", cache: "no-store" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const bytes = new Uint8Array(await res.arrayBuffer());
  if (bytes.length === 0 || bytes.length > 8 * 1024 * 1024) throw new Error("unexpected torrent size");
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

// Sends one URL (http, https or magnet) to aria2. Returns the gid.
async function sendToAria2(settings, url, ctx = {}) {
  const options = await buildOptions(settings, url, ctx);

  if (isTorrentUrl(url) && isHttpUrl(url)) {
    // addUri would only download the .torrent file itself; addTorrent starts the transfer.
    let data = null;
    try {
      data = await fetchTorrentBase64(url);
    } catch {
      data = null;
    }
    if (data) {
      const torrentOptions = settings.downloadDir ? { dir: settings.downloadDir } : {};
      return rpc.addTorrent(settings, data, torrentOptions);
    }
  }
  return rpc.addUri(settings, [url], options);
}

// ------------------------------------------------------- download intercept

function passesFilters(download, settings) {
  if (!settings.enabled) return false;
  if (!isHttpUrl(download.url)) return false;

  const size = download.fileSize > 0 ? download.fileSize : download.totalBytes > 0 ? download.totalBytes : 0;
  const minBytes = settings.minSizeMb * 1024 * 1024;
  if (minBytes > 0 && size > 0 && size < minBytes) return false;

  const exts = parseExtensions(settings.includeExtensions);
  if (exts.length > 0 && !exts.includes(extensionOf(download))) return false;

  const sites = parseSites(settings.excludeSites);
  if (sites.length > 0) {
    if (hostMatches(hostOf(download.url), sites)) return false;
    if (download.referrer && hostMatches(hostOf(download.referrer), sites)) return false;
  }
  return true;
}

async function fallbackToBrowser(download, err) {
  rememberFallback(download.url);
  try {
    const opts = { url: download.url };
    const name = download.filename ? String(download.filename).split(/[\\/]/).pop() : "";
    if (isPlainBasename(name)) opts.filename = name;
    const id = await api.downloads.download(opts);
    if (typeof id === "number") fallbackIds.add(id);
  } catch (e2) {
    fallbackUrls.delete(download.url);
    await notify("Download could not be restarted", `${download.url}\n${e2 && e2.message ? e2.message : e2}`);
  }
  await reportUnreachable(err, "The download was handed back to the browser.");
}

async function handleCreated(download) {
  if (fallbackIds.has(download.id)) return;
  if (consumeFallback(download.url)) {
    fallbackIds.add(download.id);
    return;
  }

  const settings = await getSettings();
  if (!passesFilters(download, settings)) return;

  // Take the download away from the browser first so no save dialog or transfer starts.
  try {
    await api.downloads.cancel(download.id);
  } catch {
    return; // Could not cancel (already finished?); leave it with the browser.
  }
  try {
    await api.downloads.erase({ id: download.id });
  } catch {
    // Entry may already be gone.
  }

  try {
    await sendToAria2(settings, download.url, {
      referrer: download.referrer || "",
      filename: download.filename ? String(download.filename) : "",
    });
    if (settings.notifyOnSend) {
      await notify("Sent to Rivulet", download.url);
    }
  } catch (err) {
    await fallbackToBrowser(download, err);
  }
}

api.downloads.onCreated.addListener((download) => {
  handleCreated(download).catch((e) => console.error("Rivulet: intercept failed", e));
});

// ------------------------------------------------------------ context menu

// Promise style only: Firefox's `browser.*` namespace rejects callback arguments.
async function ensureMenu() {
  try {
    await api.contextMenus.removeAll();
    api.contextMenus.create({
      id: MENU_ID,
      title: "Send to Rivulet (aria2)",
      contexts: ["link", "image", "video", "audio"],
    });
    void api.runtime.lastError;
  } catch (e) {
    console.error("Rivulet: could not create menu", e);
  }
}

api.runtime.onInstalled.addListener(ensureMenu);
api.runtime.onStartup.addListener(ensureMenu);

async function handleMenuClick(info, tab) {
  if (info.menuItemId !== MENU_ID) return;

  let target = "";
  if (info.mediaType && info.srcUrl) target = info.srcUrl;
  else target = info.linkUrl || info.srcUrl || "";

  const scheme = schemeOf(target);
  if (!target || !(scheme === "http:" || scheme === "https:" || scheme === "magnet:")) {
    await notify("Cannot send to Rivulet", "Only http, https and magnet links are supported.");
    return;
  }

  const settings = await getSettings();
  const referrer = info.pageUrl || (tab && isHttpUrl(tab.url) ? tab.url : "");
  try {
    await sendToAria2(settings, target, { referrer });
    await flashBadge("OK", "#248a3d");
    if (settings.notifyOnSend) await notify("Sent to Rivulet", target);
  } catch (err) {
    await reportUnreachable(err, "The link was not sent.");
  }
}

api.contextMenus.onClicked.addListener((info, tab) => {
  handleMenuClick(info, tab).catch((e) => console.error("Rivulet: menu action failed", e));
});
