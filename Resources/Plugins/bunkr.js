// Bunkr albums (/a/<id>) and single files (/f/<slug>, /v/, /i/, /d/).
//
// EXPERIMENTAL. Based on the site as observed on 2026-11-08 using plain public HTTP requests only:
//   1. Album page HTML lists items (class "theItem") with an <a href="/f/<slug>">, a name and a size.
//   2. A file page contains a download link https://<dl-host>/file/<numeric id>.
//   3. POST https://<dl-host>/api/_001_v2 {"id": "<numeric id>"} returns {mediafiles, original, path}.
//   4. GET <signUrl>?path=<path> returns {token, ex}; the final URL is mediafiles + path + ?n=..&token=..&ex=..
// This plugin does not solve captchas, does not use accounts and does not try to get around rate
// limits or access controls. If the site starts requiring any of that, the plugin will simply fail.
// Pagination of very large albums (?page=N) is implemented from the link structure but was NOT
// verified against a live multi page album.
//
// Bunkr domains change often: edit HOSTS below (the `match` list is generated from it).
const HOSTS = ["bunkr.si", "bunkr.la", "bunkr.cr", "bunkr.ph", "bunkr.ru", "bunkr.is", "bunkr.fi",
               "bunkr.ac", "bunkr.black", "bunkr.pk", "bunkr.sk", "bunkr.ws", "bunkr.ci", "bunkr.se",
               "bunkrr.su", "bunkr.su", "bunkr.site", "bunkr.media"];
const DEFAULT_SIGN_URL = "https://glb-apisign.cdn.cr/sign";

({
  id: "bunkr",
  name: "Bunkr (experimental)",
  version: 1,
  match: ["^https?://(?:www\\.)?(?:" + HOSTS.map(h => h.replace(/\./g, "\\.")).join("|") + ")/(?:a|f|v|i|d)/[^/?#]+"],

  async resolve(url, ctx) {
    const origin = url.match(/^https?:\/\/[^\/]+/)[0];
    const hdr = { "User-Agent": ctx.userAgent, "Referer": origin + "/" };
    if (/\/a\/[^\/?#]+/.test(url)) return await this.album(url, origin, hdr);
    return { links: [await this.file(url, origin, hdr)] };
  },

  async album(url, origin, hdr) {
    const albumURL = url.replace(/[?#].*$/, "");
    const items = [];
    const seen = {};
    let title = null;
    for (let page = 1; page <= 50; page++) {
      const res = await http.get(page === 1 ? albumURL : albumURL + "?page=" + page, { headers: hdr });
      if (res.status >= 400) { if (page === 1) throw new Error("album not found (HTTP " + res.status + ")"); break; }
      const html = res.body;
      if (page === 1) {
        const t = html.match(/<h1[^>]*>([^<]+)<\/h1>/) || html.match(/og:title" content="([^"]+)"/);
        if (t) title = util.decodeEntities(t[1].trim());
      }
      let added = 0;
      const parts = html.split(/class="[^"]*\btheItem\b[^"]*"/).slice(1);
      for (const part of parts) {
        const href = part.match(/href="(\/[fvid]\/[^"]+)"/);
        if (!href || seen[href[1]]) continue;
        seen[href[1]] = true;
        added++;
        const nm = part.match(/class="[^"]*theName[^"]*"[^>]*>([^<]+)</);
        const sz = part.match(/class="[^"]*theSize[^"]*"[^>]*>([^<]+)</);
        items.push({
          page: util.absoluteURL(res.url, href[1]),
          name: nm ? util.decodeEntities(nm[1].trim()) : null,
          size: sz ? util.sizeFromString(util.decodeEntities(sz[1].trim())) : null
        });
      }
      const hasNext = new RegExp('href="[^"]*[?&]page=' + (page + 1) + '[^0-9]').test(html);
      if (!added || !hasNext) break;
    }
    if (!items.length) throw new Error("no files found in album");

    // Resolve each file (3 requests per file) within the time budget; 3 at a time.
    const started = Date.now();
    const links = [];
    let skipped = 0;
    for (let i = 0; i < items.length; i += 3) {
      if (Date.now() - started > 22000) { skipped = items.length - i; break; }
      const batch = items.slice(i, i + 3);
      const done = await Promise.all(batch.map(it =>
        this.file(it.page, origin, hdr).catch(e => { log("skip " + (it.name || it.page) + ": " + e.message); return null; })));
      done.forEach((l, k) => {
        if (!l) return;
        if (batch[k].name) l.name = batch[k].name;
        if (batch[k].size) l.size = batch[k].size;
        links.push(l);
      });
    }
    if (skipped) log("time budget reached, " + skipped + " files not resolved; resolve the album again");
    return { packageName: title, links: links };
  },

  async file(pageURL, origin, hdr) {
    const res = await http.get(pageURL, { headers: hdr });
    if (res.status >= 400) throw new Error("file page HTTP " + res.status);
    const dl = res.body.match(/href="(https?:\/\/[^"\/]+)\/file\/(\d+)"/);
    if (!dl) throw new Error("no download id on file page");
    const dlHost = dl[1], id = dl[2];
    const signMatch = res.body.match(/signUrl\s*=\s*"([^"]+)"/);
    const meta = await http.post(dlHost + "/api/_001_v2", JSON.stringify({ id: id }),
      { headers: { "Content-Type": "application/json", "User-Agent": hdr["User-Agent"], "Referer": dlHost + "/file/" + id, "Origin": dlHost } });
    if (meta.status !== 200) throw new Error("api HTTP " + meta.status);
    const m = JSON.parse(meta.body);
    if (!m.mediafiles || !m.path) throw new Error("unexpected api response");
    const signURL = (signMatch ? signMatch[1] : DEFAULT_SIGN_URL).replace(/\\\//g, "/");
    // The file page already names the sign service in the dl page; fall back to the default.
    const sres = await http.get(signURL + "?path=" + encodeURIComponent(decodeURIComponent(m.path)), { headers: { "User-Agent": hdr["User-Agent"] } });
    if (sres.status !== 200) throw new Error("sign HTTP " + sres.status);
    const s = JSON.parse(sres.body);
    if (!s.token || !s.ex) throw new Error("unexpected sign response");
    const name = m.original || decodeURIComponent(m.path.split("/").pop());
    const direct = m.mediafiles + m.path + "?n=" + encodeURIComponent(name) + "&token=" + s.token + "&ex=" + s.ex;
    return { url: direct, name: name, headers: { "User-Agent": hdr["User-Agent"], "Referer": origin + "/" } };
  }
})
