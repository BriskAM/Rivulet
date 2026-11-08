// Settings wrapper around storage.local with defaults and list parsing helpers.

const api = globalThis.browser ?? globalThis.chrome;

export const DEFAULTS = Object.freeze({
  enabled: true,
  rpcUrl: "http://localhost:6800/jsonrpc",
  secret: "",
  downloadDir: "",
  minSizeMb: 0,
  includeExtensions: "",
  excludeSites: "",
  notifyOnSend: false,
});

function normalize(input) {
  const s = { ...DEFAULTS, ...input };
  const min = Number(s.minSizeMb);
  return {
    enabled: Boolean(s.enabled),
    rpcUrl: String(s.rpcUrl || DEFAULTS.rpcUrl).trim(),
    secret: String(s.secret ?? ""),
    downloadDir: String(s.downloadDir ?? "").trim(),
    minSizeMb: Number.isFinite(min) && min > 0 ? min : 0,
    includeExtensions: String(s.includeExtensions ?? ""),
    excludeSites: String(s.excludeSites ?? ""),
    notifyOnSend: Boolean(s.notifyOnSend),
  };
}

export async function getSettings() {
  const stored = await api.storage.local.get(Object.keys(DEFAULTS));
  return normalize(stored);
}

export async function saveSettings(settings) {
  const clean = normalize(settings);
  await api.storage.local.set(clean);
  return clean;
}

function splitList(text) {
  return String(text ?? "")
    .split(/[\s,;]+/)
    .map((x) => x.trim().toLowerCase())
    .filter(Boolean);
}

// "zip, .ISO  mkv" -> ["zip", "iso", "mkv"]
export function parseExtensions(text) {
  return splitList(text).map((x) => x.replace(/^\*?\./, ""));
}

// "example.com https://Foo.org/path" -> ["example.com", "foo.org"]
export function parseSites(text) {
  return splitList(text)
    .map((x) => {
      let h = x.replace(/^[a-z][a-z0-9+.-]*:\/\//, "");
      h = h.split(/[/?#]/)[0].replace(/^\*?\./, "").replace(/:\d+$/, "");
      return h;
    })
    .filter(Boolean);
}

// True when host equals a listed site or is a subdomain of it.
export function hostMatches(host, sites) {
  const h = String(host || "").toLowerCase();
  if (!h) return false;
  return sites.some((s) => h === s || h.endsWith("." + s));
}
