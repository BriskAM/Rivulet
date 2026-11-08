import { getSettings, saveSettings } from "./settings.js";
import * as rpc from "./rpc.js";

const $ = (id) => document.getElementById(id);
const fields = {
  enabled: $("enabled"),
  notifyOnSend: $("notifyOnSend"),
  rpcUrl: $("rpcUrl"),
  secret: $("secret"),
  downloadDir: $("downloadDir"),
  minSizeMb: $("minSizeMb"),
  includeExtensions: $("includeExtensions"),
  excludeSites: $("excludeSites"),
};
const testResult = $("test-result");
const saveResult = $("save-result");

function readForm() {
  return {
    enabled: fields.enabled.checked,
    notifyOnSend: fields.notifyOnSend.checked,
    rpcUrl: fields.rpcUrl.value.trim(),
    secret: fields.secret.value,
    downloadDir: fields.downloadDir.value.trim(),
    minSizeMb: fields.minSizeMb.value === "" ? 0 : Number(fields.minSizeMb.value),
    includeExtensions: fields.includeExtensions.value,
    excludeSites: fields.excludeSites.value,
  };
}

function writeForm(s) {
  fields.enabled.checked = s.enabled;
  fields.notifyOnSend.checked = s.notifyOnSend;
  fields.rpcUrl.value = s.rpcUrl;
  fields.secret.value = s.secret;
  fields.downloadDir.value = s.downloadDir;
  fields.minSizeMb.value = s.minSizeMb || "";
  fields.includeExtensions.value = s.includeExtensions;
  fields.excludeSites.value = s.excludeSites;
}

function validate(s) {
  try {
    const u = new URL(s.rpcUrl);
    if (u.protocol !== "http:" && u.protocol !== "https:") throw new Error();
  } catch {
    return "The RPC URL must be a full http:// or https:// address.";
  }
  if (!Number.isFinite(s.minSizeMb) || s.minSizeMb < 0) {
    return "Minimum size must be zero or a positive number.";
  }
  return "";
}

function show(el, text, kind) {
  el.textContent = text;
  el.className = `result ${kind || ""}`.trim();
}

$("test").addEventListener("click", async () => {
  const s = readForm();
  const problem = validate(s);
  if (problem) {
    show(testResult, problem, "bad");
    return;
  }
  show(testResult, "Testing...", "");
  try {
    const v = await rpc.getVersion(s, { timeoutMs: 5000 });
    show(testResult, `Connected. aria2 ${v.version}`, "good");
  } catch (err) {
    show(testResult, err.message, "bad");
  }
});

$("form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const s = readForm();
  const problem = validate(s);
  if (problem) {
    show(saveResult, problem, "bad");
    return;
  }
  try {
    await saveSettings(s);
    show(saveResult, "Saved.", "good");
    setTimeout(() => show(saveResult, "", ""), 2500);
  } catch (err) {
    show(saveResult, `Could not save: ${err.message}`, "bad");
  }
});

getSettings().then(writeForm);
