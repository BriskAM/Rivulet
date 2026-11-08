import { getSettings, saveSettings } from "./settings.js";
import * as rpc from "./rpc.js";

const api = globalThis.browser ?? globalThis.chrome;

const $ = (id) => document.getElementById(id);
const els = {
  dot: $("dot"),
  statusText: $("status-text"),
  speeds: $("speeds"),
  down: $("down"),
  up: $("up"),
  counts: $("counts"),
  message: $("message"),
  list: $("list"),
  empty: $("empty"),
  toggleAll: $("toggle-all"),
  enabled: $("enabled"),
  settings: $("settings"),
  open: $("open"),
};

const POLL_MS = 1000;
const RPC_TIMEOUT = { timeoutMs: 3000 };

let settings = null;
let anyActive = false;
let busy = false;

function formatBytes(n) {
  n = Number(n) || 0;
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i++;
  }
  return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)} ${units[i]}`;
}

const formatSpeed = (n) => `${formatBytes(n)}/s`;

function taskName(task) {
  const bt = task.bittorrent && task.bittorrent.info && task.bittorrent.info.name;
  if (bt) return bt;
  const file = task.files && task.files[0];
  if (file) {
    if (file.path) return file.path.split(/[\\/]/).pop();
    const uri = file.uris && file.uris[0] && file.uris[0].uri;
    if (uri) {
      try {
        return decodeURIComponent(new URL(uri).pathname.split("/").pop()) || uri;
      } catch {
        return uri;
      }
    }
  }
  return task.gid;
}

function renderTask(task) {
  const total = Number(task.totalLength) || 0;
  const done = Number(task.completedLength) || 0;
  const pct = total > 0 ? Math.min(100, (done / total) * 100) : 0;
  const speed = Number(task.downloadSpeed) || 0;

  const li = document.createElement("li");
  li.className = "task";

  const name = document.createElement("div");
  name.className = "task-name";
  name.textContent = taskName(task);
  name.title = name.textContent;

  const meta = document.createElement("div");
  meta.className = "task-meta";
  const left = document.createElement("span");
  const right = document.createElement("span");
  if (task.status === "active") {
    left.textContent = total > 0 ? `${pct.toFixed(1)}%` : formatBytes(done);
    right.textContent = formatSpeed(speed);
  } else {
    left.textContent = total > 0 ? `${pct.toFixed(1)}%` : "";
    right.textContent = task.status === "paused" ? "Paused" : "Waiting";
  }
  meta.append(left, right);

  const bar = document.createElement("div");
  bar.className = "bar";
  const fill = document.createElement("div");
  fill.className = "bar-fill";
  if (task.status !== "active") fill.classList.add("idle");
  fill.style.width = `${pct}%`;
  bar.append(fill);

  li.append(name, meta, bar);
  return li;
}

function setMessage(text) {
  els.message.hidden = !text;
  els.message.textContent = text || "";
}

function showOffline(err) {
  els.dot.className = "dot bad";
  els.statusText.textContent = "Not connected";
  els.speeds.hidden = true;
  els.list.replaceChildren();
  els.empty.hidden = true;
  els.toggleAll.disabled = true;
  setMessage(err && err.message ? err.message : String(err));
}

async function refresh() {
  if (busy) return;
  busy = true;
  try {
    settings = await getSettings();
    els.enabled.checked = settings.enabled;
    const [version, stat, active, waiting] = await Promise.all([
      rpc.getVersion(settings, RPC_TIMEOUT),
      rpc.getGlobalStat(settings, RPC_TIMEOUT),
      rpc.tellActive(settings, RPC_TIMEOUT),
      rpc.tellWaiting(settings, 8, RPC_TIMEOUT),
    ]);

    els.dot.className = "dot good";
    els.statusText.textContent = `aria2 ${version.version}`;
    els.speeds.hidden = false;
    els.down.textContent = formatSpeed(stat.downloadSpeed);
    els.up.textContent = formatSpeed(stat.uploadSpeed);
    els.counts.textContent = `${stat.numActive} + ${stat.numWaiting} queued`;
    setMessage("");

    const tasks = [...active, ...waiting].slice(0, 8);
    els.list.replaceChildren(...tasks.map(renderTask));
    els.empty.hidden = tasks.length > 0;

    anyActive = active.length > 0;
    els.toggleAll.disabled = false;
    els.toggleAll.textContent = anyActive ? "Pause All" : "Resume All";
  } catch (err) {
    showOffline(err);
  } finally {
    busy = false;
  }
}

function schedule() {
  setTimeout(async () => {
    await refresh();
    schedule();
  }, POLL_MS);
}

els.toggleAll.addEventListener("click", async () => {
  els.toggleAll.disabled = true;
  try {
    if (anyActive) await rpc.pauseAll(settings, RPC_TIMEOUT);
    else await rpc.unpauseAll(settings, RPC_TIMEOUT);
    setMessage("");
  } catch (err) {
    setMessage(err.message);
  }
  await refresh();
});

els.enabled.addEventListener("change", async () => {
  const current = await getSettings();
  await saveSettings({ ...current, enabled: els.enabled.checked });
});

els.settings.addEventListener("click", () => {
  api.runtime.openOptionsPage();
  window.close();
});

els.open.addEventListener("click", () => {
  // The browser hands rivulet:// to the operating system. Close the popup afterwards.
  setTimeout(() => window.close(), 200);
});

refresh().then(schedule);
