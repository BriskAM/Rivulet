// Example crawler plugin: expands an Apache/nginx style "Index of /" listing into one link per file.
// Not recursive (sub directories are skipped). It matches any http(s) URL ending in "/", so it has a
// low priority: other plugins in the same directory are tried first.
({
  id: "apache_index",
  name: "Directory index (Apache / nginx)",
  version: 1,
  priority: -10,
  match: ["^https?://[^?#]+/(\\?[^#]*)?(#.*)?$"],

  async resolve(url, ctx) {
    const res = await http.get(url);
    if (res.status >= 400) throw new Error("HTTP " + res.status);
    const html = res.body;
    if (!/<title>Index of|<h1>Index of|Directory listing for/i.test(html)) {
      // Not a listing: behave like a plain direct link.
      return { links: [{ url: url }] };
    }
    const base = res.url;
    const seen = {};
    const links = [];
    const re = /<a\s+[^>]*href="([^"]+)"[^>]*>/gi;
    let m;
    while ((m = re.exec(html)) !== null) {
      let href = util.decodeEntities(m[1]);
      if (href.startsWith("?") || href.startsWith("#") || href.startsWith("/") && href.length === 1) continue;
      if (href.endsWith("/")) continue;             // sub directory
      if (href.startsWith("../") || href === "..") continue;
      const abs = util.absoluteURL(base, href);
      if (!abs.startsWith(base.replace(/[?#].*$/, ""))) continue;   // parent / foreign links
      if (seen[abs]) continue;
      seen[abs] = true;
      let name = abs.split("?")[0].split("/").pop();
      try { name = decodeURIComponent(name); } catch (e) {}
      links.push({ url: abs, name: name, headers: { Referer: base } });
    }
    const dir = decodeURIComponent(base.replace(/[?#].*$/, "").replace(/\/$/, "").split("/").pop());
    return { packageName: dir || null, links: links };
  }
})
