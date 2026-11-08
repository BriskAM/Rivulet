// MediaFire: single file pages and public folders.
// Verified live (2026-11): file pages expose the direct URL in <a id="downloadButton" href=...>.
// Folders use the public API https://www.mediafire.com/api/1.5/folder/get_content.php.
// The CDN rejects clients without a browser-like User-Agent, so we forward one.
({
  id: "mediafire",
  name: "MediaFire",
  version: 1,
  match: [
    "^https?://(www\\.)?mediafire\\.com/(file|file_premium|view|download)/",
    "^https?://(www\\.)?mediafire\\.com/folder/",
    "^https?://(www\\.)?mediafire\\.com/\\?[a-z0-9]{8,}"
  ],

  async resolve(url, ctx) {
    const folder = url.match(/mediafire\.com\/folder\/([a-z0-9]+)/i);
    if (folder) return await this.folder(folder[1], url, ctx);
    return { links: [await this.file(url, ctx)] };
  },

  async file(url, ctx) {
    const res = await http.get(url, { headers: { "User-Agent": ctx.userAgent } });
    if (res.status === 404) throw new Error("file not found");
    const html = res.body;
    let direct = null;
    const scrambled = html.match(/data-scrambled-url="([^"]+)"/);
    if (scrambled) {
      direct = util.base64Decode(scrambled[1]);
    } else {
      const m = html.match(/<a[^>]+id="downloadButton"[^>]*>/) ||
                html.match(/<a[^>]+aria-label="Download file"[^>]*>/);
      const href = m && m[0].match(/href="([^"]+)"/);
      if (href) direct = util.decodeEntities(href[1]);
    }
    if (!direct || !/^https?:\/\//.test(direct)) {
      throw new Error("no download link found (password protected or removed?)");
    }
    const nameMatch = html.match(/<div class="filename">([^<]+)<\/div>/);
    const name = nameMatch ? util.decodeEntities(nameMatch[1].trim()) : decodeURIComponent(direct.split("/").pop());
    const sizeMatch = html.match(/File size:\s*<span>([^<]+)<\/span>/) || html.match(/Download \(([^)]+)\)/);
    return {
      url: direct,
      name: name,
      size: sizeMatch ? util.sizeFromString(sizeMatch[1]) : null,
      headers: { "User-Agent": ctx.userAgent, "Referer": "https://www.mediafire.com/" }
    };
  },

  async api(path, params) {
    const q = Object.keys(params).map(k => k + "=" + encodeURIComponent(params[k])).join("&");
    const res = await http.get("https://www.mediafire.com/api/1.5/" + path + ".php?response_format=json&" + q);
    const j = JSON.parse(res.body).response;
    if (j.result !== "Success") throw new Error("MediaFire API: " + (j.message || "error"));
    return j;
  },

  async list(key, type) {
    const out = [];
    for (let chunk = 1; chunk <= 50; chunk++) {
      const j = await this.api("folder/get_content", { folder_key: key, content_type: type, chunk: chunk, chunk_size: 1000 });
      const c = j.folder_content;
      out.push(...(c[type] || []));
      if (c.more_chunks !== "yes") break;
    }
    return out;
  },

  async folder(key, url, ctx) {
    const info = await this.api("folder/get_info", { folder_key: key });
    const files = [];
    const queue = [{ key: key, depth: 0 }];
    while (queue.length && files.length < 2000) {
      const cur = queue.shift();
      for (const f of await this.list(cur.key, "files")) files.push(f);
      if (cur.depth < 3) for (const d of await this.list(cur.key, "folders")) queue.push({ key: d.folderkey, depth: cur.depth + 1 });
    }
    // Each file needs its page fetched to get the short-lived direct URL. Work within the time budget.
    const started = Date.now();
    const links = [];
    let skipped = 0;
    for (let i = 0; i < files.length; i += 4) {
      if (Date.now() - started > 20000) { skipped = files.length - i; break; }
      const batch = files.slice(i, i + 4);
      const done = await Promise.all(batch.map(f => {
        const page = (f.links && f.links.normal_download) || ("https://www.mediafire.com/file/" + f.quickkey + "/" + encodeURIComponent(f.filename) + "/file");
        return this.file(page, ctx).catch(e => { log("skip " + f.filename + ": " + e.message); return null; });
      }));
      for (let k = 0; k < done.length; k++) {
        const l = done[k];
        if (!l) continue;
        if (!l.size && batch[k].size) l.size = Number(batch[k].size);
        links.push(l);
      }
    }
    if (skipped) log("time budget reached, " + skipped + " files not resolved; resolve the folder again");
    return { packageName: info.folder_info.name, links: links };
  }
})
