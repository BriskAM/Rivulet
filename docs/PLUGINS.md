# Writing Rivulet link resolver plugins

A plugin is one `.js` file that runs in JavaScriptCore (the engine built into macOS).
Put user plugins in the user plugin directory (they win over bundled ones with the same
match); bundled examples live in `Resources/Plugins/`.

## Format

The file must evaluate to an object. Top level `const` helpers before the object are fine.

    ({
      id: "mysite",              // required, [a-z0-9_-]{1,64}, also the file name when installed
      name: "My Site",
      version: 1,                // integer, used by the plugin updater
      priority: 0,               // optional; higher is tried first inside one directory
      match: ["^https?://(www\\.)?mysite\\.com/(file|folder)/"],   // regex sources
      async resolve(url, ctx) {
        const res = await http.get(url);
        return {
          packageName: "optional",
          links: [{ url: "https://cdn.example/f.zip", name: "f.zip", size: 1234,
                    headers: { Referer: url } }]
        };
      }
    })

`match` patterns are tested with ICU regular expressions against the full URL. Only
`http`, `https` and `magnet` link URLs are kept. `name` is stripped of path separators.
Return `size` as a number or a string such as "1.5 GB". Headers (Referer, Cookie,
User-Agent) are forwarded to aria2 for that link. Throw an Error to fail; the user sees an
offline link and no detail from your message is forwarded.

A file with a syntax error, a missing id/resolve/match, or an invalid regex is skipped and
reported in `ResolverEngine.loadErrors`; it never crashes the app.

## Host API

| Global | Description |
| --- | --- |
| `http.get(url, {headers, timeout})` | Promise of `{status, headers, body, url}`. Header keys are lowercased, `url` is the final URL after redirects. |
| `http.post(url, body, opts)` | Same. `body` is a string (sent as is) or an object (form encoded). Default Content-Type is form encoded. |
| `http.cookies(url)` | Cookie header string from the per-resolve cookie jar. |
| `log(msg)` | Debug output (`ResolverEngine.logHandler`). |
| `util.decodeEntities(s)` | HTML entity decoding. |
| `util.absoluteURL(base, rel)` | Resolve a relative URL. |
| `util.sizeFromString("1.5 GB")` | Bytes (binary units) or null. |
| `util.base64Decode(s)`, `util.atob`, `util.btoa` | Base64 helpers (`atob`/`btoa` also exist as globals). |
| `ctx.account(host)` | `{username, password}` from the user's saved accounts, or null. |
| `ctx.userAgent`, `ctx.url` | Browser-like User-Agent string; the pasted URL. |
| `JSON`, `Promise`, `async/await`, `RegExp`, ... | Standard JavaScript. |

The default User-Agent of `http` is browser-like because several hosts reset connections
from unknown clients. Cookies set by responses are replayed within one resolve only.

## Limits and sandbox

- 30 s per resolve (then the result is an offline link), 5000 links per result, 8 MB per
  response body (longer bodies are truncated).
- Each resolve gets a fresh JavaScript context. There is no filesystem, process, `require`,
  `fetch` or timer API. `http` only accepts `http://` and `https://` URLs, including for
  redirects.
- A plugin that spins in a synchronous infinite loop cannot be interrupted; the resolve
  still times out, but the loop keeps burning one thread until the app exits. Do not write
  those.
- Do not solve captchas or bypass access controls, rate limits, paywalls or logins.

## Testing a plugin

1. Drop the file into the user plugin directory and call `ResolverEngine.reload()` (or restart).
   Check `engine.loadErrors` for parse problems.
2. Run it against real URLs with the live test helper, which prints the results and runs
   `checkOnline` on the first links:

       RIVULET_LIVE_URLS="https://site/file/abc" swift test --filter liveResolve \
         --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk

   (With only the Command Line Tools installed, also pass
   `-Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing`.)
3. For unit tests, copy the pattern in `Tests/RivuletCoreTests/ResolverTests.swift`:
   a small local HTTP server serves fixture pages and the plugin runs against it.

## Distributing plugins

`PluginRepository.update(from:)` reads an `index.json`:

    {"plugins":[{"id":"bunkr","version":3,"url":"bunkr.js","sha256":"<hex>"}]}

`url` may be relative to the index. A plugin is replaced only when `version` is higher than
the installed file's `version: N`. Each download is hashed (SHA-256) before it is written
atomically; a mismatch is rejected and listed in `lastFailures`. Nothing is executed during
an update. `http`, `https` and `file` URLs are accepted.
