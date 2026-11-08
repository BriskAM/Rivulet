// Bunkr albums (/a/<id>) and single files (/f/<slug>, /v/, /i/, /d/).
//
// EXPERIMENTAL. Based on the site as observed on 2026-11-08 using plain public HTTP requests only:
//   1. Album page HTML lists items (class "theItem") with an <a href="/f/<slug>">, a name and a size.
//   2. A file page contains a download link https://<dl-host>/file/<numeric id>.
//   3. POST https://<dl-host>/api/_001_v2 {"id": "<numeric id>"} returns {mediafiles, original, path}.
//   4. GET <signUrl>?path=<path> returns {token, ex}; the final URL is mediafiles + path + ?n=..&token=..&ex=..
// This plugin does not solve captchas, does not use accounts and does not try to get around rate
// limits or access controls. If the site starts requiring any of that, the plugin will simply fail.
// Albums are listed page by page (?page=N, verified on a 53 page album); each file is resolved when its
// download starts.
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

  // Large albums (hundreds of files over many pages) are listed, not resolved: every entry is returned as
  // its own file page link (name and size from the listing) and Rivulet resolves it just before it starts
  // downloading, because the final download links are signed and expire.
  async album(url, origin, hdr) {
    const albumURL = url.replace(/[?#].*$/, "");
    const items = [];
    const seen = {};
    let title = null;
    let lastPage = 1;
    const started = Date.now();
    const parse = (html, base) => {
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
          url: util.absoluteURL(base, href[1]),
          name: nm ? util.decodeEntities(nm[1].trim()) : null,
          size: sz ? util.sizeFromString(util.decodeEntities(sz[1].trim())) : null,
          status: "online"
        });
      }
      return added;
    };
    const first = await http.get(albumURL, { headers: hdr });
    if (first.status >= 400) throw new Error("album not found (HTTP " + first.status + ")");
    const t = first.body.match(/<h1[^>]*>([^<]+)<\/h1>/) || first.body.match(/og:title" content="([^"]+)"/);
    if (t) title = util.decodeEntities(t[1].trim());
    const nums = (first.body.match(/[?&]page=\d+/g) || []).map(m => parseInt(m.replace(/\D/g, ""), 10));
    if (nums.length) lastPage = Math.min(Math.max.apply(null, nums), 300);
    parse(first.body, first.url);
    // Remaining pages, four at a time, in order, within a time budget.
    for (let page = 2; page <= lastPage; page += 4) {
      if (Date.now() - started > 22000) { log("time budget reached after " + (page - 1) + " of " + lastPage + " pages"); break; }
      const nums2 = [];
      for (let k = page; k < page + 4 && k <= lastPage; k++) nums2.push(k);
      const got = await Promise.all(nums2.map(n => http.get(albumURL + "?page=" + n, { headers: hdr }).catch(() => http.get(albumURL + "?page=" + n, { headers: hdr })).catch(() => null)));
      let any = false;
      got.forEach((r, k) => { if (r && r.status < 400 && parse(r.body, r.url) > 0) any = true; else log("page " + nums2[k] + " empty or failed"); });
      if (!any) break;
    }
    if (!items.length) throw new Error("no files found in album");
    return { packageName: title, links: items };
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
