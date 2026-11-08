// Minimal aria2 JSON-RPC client over HTTP POST.

export class RpcError extends Error {
  constructor(message, kind = "rpc") {
    super(message);
    this.name = "RpcError";
    this.kind = kind; // "network" | "http" | "auth" | "rpc" | "config"
  }
}

export async function rpcCall(settings, method, params = [], { timeoutMs = 6000 } = {}) {
  let url;
  try {
    url = new URL(settings.rpcUrl);
    if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("bad scheme");
  } catch {
    throw new RpcError(`Invalid RPC URL: ${settings.rpcUrl || "(empty)"}`, "config");
  }

  const fullParams = settings.secret ? [`token:${settings.secret}`, ...params] : params;
  const body = JSON.stringify({
    jsonrpc: "2.0",
    id: `rivulet-${Date.now()}`,
    method,
    params: fullParams,
  });

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let response;
  try {
    response = await fetch(url.href, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      cache: "no-store",
      signal: controller.signal,
    });
  } catch (err) {
    if (err && err.name === "AbortError") {
      throw new RpcError(`Timed out waiting for aria2 at ${url.href}`, "network");
    }
    throw new RpcError(
      `Cannot reach aria2 at ${url.href}. Is aria2c running with enable-rpc=true?`,
      "network"
    );
  } finally {
    clearTimeout(timer);
  }

  let payload = null;
  try {
    payload = await response.json();
  } catch {
    // Non-JSON body; handled below.
  }

  if (payload && payload.error) {
    const msg = String(payload.error.message || "Unknown aria2 error");
    if (/unauthorized/i.test(msg)) {
      throw new RpcError("aria2 rejected the RPC secret (Unauthorized).", "auth");
    }
    throw new RpcError(`aria2 error: ${msg}`, "rpc");
  }
  if (!response.ok) {
    if (response.status === 401 || response.status === 403) {
      throw new RpcError(`aria2 rejected the request (HTTP ${response.status}). Check the secret.`, "auth");
    }
    throw new RpcError(`HTTP ${response.status} from ${url.href}. Is this the /jsonrpc endpoint?`, "http");
  }
  if (!payload || !("result" in payload)) {
    throw new RpcError(`Unexpected response from ${url.href}. Is this the /jsonrpc endpoint?`, "http");
  }
  return payload.result;
}

export const TASK_KEYS = [
  "gid",
  "status",
  "totalLength",
  "completedLength",
  "downloadSpeed",
  "files",
  "bittorrent",
];

export const getVersion = (s, o) => rpcCall(s, "aria2.getVersion", [], o);
export const getGlobalStat = (s, o) => rpcCall(s, "aria2.getGlobalStat", [], o);
export const tellActive = (s, o) => rpcCall(s, "aria2.tellActive", [TASK_KEYS], o);
export const tellWaiting = (s, count = 8, o) => rpcCall(s, "aria2.tellWaiting", [0, count, TASK_KEYS], o);
export const pauseAll = (s, o) => rpcCall(s, "aria2.pauseAll", [], o);
export const unpauseAll = (s, o) => rpcCall(s, "aria2.unpauseAll", [], o);
export const addUri = (s, uris, options = {}, o) => rpcCall(s, "aria2.addUri", [uris, options], o);
export const addTorrent = (s, base64, options = {}, o) =>
  rpcCall(s, "aria2.addTorrent", [base64, [], options], o);
