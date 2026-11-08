import Testing
import Foundation
import Network
import CryptoKit
@testable import RivuletCore

// MARK: - Local HTTP server (hermetic)

final class TestServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.server")
    private let lock = NSLock()
    private var held: [NWConnection] = []
    private(set) var port: UInt16 = 0
    private var seenUserAgents: [String] = []

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    var userAgents: [String] { lock.lock(); defer { lock.unlock() }; return seenUserAgents }

    func start() async -> UInt16 {
        await withCheckedContinuation { (cont: CheckedContinuation<UInt16, Never>) in
            final class Once: @unchecked Sendable { let lock = NSLock(); var done = false }
            let once = Once()
            listener.stateUpdateHandler = { [self] state in
                if case .ready = state {
                    once.lock.lock(); defer { once.lock.unlock() }
                    if !once.done { once.done = true; port = listener.port?.rawValue ?? 0; cont.resume(returning: port) }
                }
            }
            listener.newConnectionHandler = { [self] c in handle(c) }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel(); lock.lock(); held.forEach { $0.cancel() }; held = []; lock.unlock() }
    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, err in
            var buf = buffer
            if let data { buf.append(data) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for l in lines.dropFirst() { if let i = l.firstIndex(of: ":") { headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces) } }
                let need = Int(headers["content-length"] ?? "0") ?? 0
                let body = buf[r.upperBound...]
                if body.count < need && !done && err == nil { read(c, buffer: buf); return }
                route(c, request: lines[0], headers: headers, body: String(decoding: body, as: UTF8.self))
            } else if !done && err == nil {
                read(c, buffer: buf)
            } else { c.cancel() }
        }
    }

    private func send(_ c: NWConnection, status: Int, headers: [String: String] = [:], body: Data = Data(), head: Bool = false) {
        var s = "HTTP/1.1 \(status) X\r\n"
        var h = headers
        if h["Content-Length"] == nil { h["Content-Length"] = "\(body.count)" }
        h["Connection"] = "close"
        for (k, v) in h { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        var out = Data(s.utf8)
        if !head { out.append(body) }
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func route(_ c: NWConnection, request: String, headers: [String: String], body: String) {
        let parts = request.split(separator: " ")
        let method = String(parts[0]), path = String(parts.count > 1 ? parts[1] : "/")
        let isHead = method == "HEAD"
        lock.lock(); if let ua = headers["user-agent"] { seenUserAgents.append(ua) }; lock.unlock()
        switch path.split(separator: "?").first.map(String.init) ?? path {
        case "/ok.bin":
            if let range = headers["range"], range.hasPrefix("bytes=0-0") {
                send(c, status: 206, headers: ["Content-Range": "bytes 0-0/1234", "Content-Length": "1"], body: Data([0]))
            } else {
                send(c, status: 200, headers: ["Content-Length": "1234"], body: Data(repeating: 1, count: isHead ? 0 : 1234), head: isHead)
            }
        case "/nohead.bin":   // HEAD not allowed, ranged GET works
            if isHead { send(c, status: 405) }
            else { send(c, status: 206, headers: ["Content-Range": "bytes 0-0/777", "Content-Length": "1"], body: Data([0])) }
        case "/cd":
            send(c, status: 200, headers: ["Content-Disposition": "attachment; filename=\"report final.pdf\"", "Content-Length": "10"], body: Data(count: isHead ? 0 : 10), head: isHead)
        case "/cd2":
            send(c, status: 200, headers: ["Content-Disposition": "attachment; filename*=UTF-8''caf%C3%A9.txt", "Content-Length": "5"], body: Data(count: isHead ? 0 : 5), head: isHead)
        case "/gone":
            send(c, status: 404, body: Data("nope".utf8))
        case "/page":
            let html = "<html><a href=\"/ok.bin\">one</a> <a href='/files/two%20x.zip'>two</a></html>"
            send(c, status: 200, headers: ["Content-Type": "text/html"], body: Data(html.utf8))
        case "/redirect":
            send(c, status: 302, headers: ["Location": "/page"])
        case "/setcookie":
            send(c, status: 200, headers: ["Set-Cookie": "sid=abc123; Path=/"], body: Data("set".utf8))
        case "/needcookie":
            send(c, status: 200, body: Data((headers["cookie"] ?? "none").utf8))
        case "/echo":
            send(c, status: 200, body: Data("\(method)|\(headers["content-type"] ?? "")|\(body)".utf8))
        case "/big":
            send(c, status: 200, body: Data(repeating: 65, count: 9 * 1024 * 1024))
        case "/slow":
            lock.lock(); held.append(c); lock.unlock()   // never answer
        case "/index/":
            let html = "<html><head><title>Index of /index</title></head><body><h1>Index of /index</h1><a href=\"?C=N;O=D\">Name</a><a href=\"/\">Parent Directory</a><a href=\"sub/\">sub/</a><a href=\"a%20b.txt\">a b.txt</a><a href=\"c.bin\">c.bin</a></body></html>"
            send(c, status: 200, headers: ["Content-Type": "text/html"], body: Data(html.utf8))
        default:
            send(c, status: 404)
        }
    }
}

// MARK: - helpers

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("rivulet-resolver-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@discardableResult
private func writePlugin(_ dir: URL, _ file: String, _ source: String) -> URL {
    let u = dir.appendingPathComponent(file)
    try! source.write(to: u, atomically: true, encoding: .utf8)
    return u
}

private func simplePlugin(id: String, version: Int = 1, match: String, body: String = "return { links: [{ url: url }] };") -> String {
    """
    ({ id: "\(id)", name: "\(id)", version: \(version), match: ["\(match)"],
       async resolve(url, ctx) { \(body) } })
    """
}

private func sha256(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

// MARK: - tests

@Suite("Resolver")
struct ResolverTests {

    @Test func extractsURLsFromMessyText() {
        let text = """
        Check this out: https://example.com/a/b?x=1&y=2, and (http://foo.org/path_(wiki)) also.
        <a href="https://example.com/dup">link</a> https://example.com/dup
        magnet:?xt=urn:btih:ABCDEF&dn=Name.
        "http://quoted.example/file.zip". Trailing dot https://t.example/x.
        no scheme example.com/nothing  http://  httpx://bad
        https://one.example/1,https://two.example/2
        """
        let urls = ResolverEngine.extractURLs(from: text).map(\.absoluteString)
        #expect(urls.contains("https://example.com/a/b?x=1&y=2"))
        #expect(urls.contains("http://foo.org/path_(wiki)"))
        #expect(urls.filter { $0 == "https://example.com/dup" }.count == 1)
        #expect(urls.contains("magnet:?xt=urn:btih:ABCDEF&dn=Name"))
        #expect(urls.contains("http://quoted.example/file.zip"))
        #expect(urls.contains("https://t.example/x"))
        #expect(urls.contains("https://one.example/1"))
        #expect(urls.contains("https://two.example/2"))
        #expect(!urls.contains { $0.contains("nothing") || $0.contains("bad") })
        #expect(ResolverEngine.extractURLs(from: "nothing here").isEmpty)
    }

    @Test func loadsPluginsAndSkipsMalformed() {
        let dir = tempDir()
        writePlugin(dir, "good.js", simplePlugin(id: "good", match: "^https://good\\\\.test/"))
        writePlugin(dir, "syntax.js", "({ id: 'x', name: ")
        writePlugin(dir, "noid.js", "({ name: 'x', match: ['a'], async resolve() {} })")
        writePlugin(dir, "badre.js", simplePlugin(id: "badre", match: "([unclosed"))
        writePlugin(dir, "nofunc.js", "({ id: 'nofunc', match: ['x'], resolve: 5 })")
        writePlugin(dir, "notjs.txt", "ignored")
        let engine = ResolverEngine(pluginDirectories: [dir])
        #expect(engine.plugins.map(\.id) == ["good"])
        #expect(engine.loadErrors.count == 4)
        #expect(engine.plugin(matching: URL(string: "https://good.test/x")!)?.id == "good")
        #expect(engine.plugin(matching: URL(string: "https://other.test/x")!) == nil)
    }

    @Test func userPluginsTakePrecedenceOverBundled() async {
        let user = tempDir(), bundled = tempDir()
        writePlugin(user, "dup.js", simplePlugin(id: "dup", version: 2, match: "^https://dup\\\\.test/", body: "return { links: [{ url: 'https://user.test/f' }] };"))
        writePlugin(bundled, "dup.js", simplePlugin(id: "dup", version: 9, match: "^https://dup\\\\.test/", body: "return { links: [{ url: 'https://bundled.test/f' }] };"))
        writePlugin(bundled, "other.js", simplePlugin(id: "other", match: "^https://dup\\\\.test/", body: "return { links: [{ url: 'https://other.test/f' }] };"))
        let engine = ResolverEngine(pluginDirectories: [user, bundled])
        #expect(engine.plugins.map(\.id) == ["dup", "other"])
        #expect(engine.plugins.first?.source == "user")
        #expect(engine.plugins.last?.source == "bundled")
        let r = await engine.resolve("https://dup.test/x")
        #expect(r.first?.pluginID == "dup")
        #expect(r.first?.links.first?.url == "https://user.test/f")
    }

    @Test func priorityOrdersPluginsInsideADirectory() {
        let dir = tempDir()
        writePlugin(dir, "a_generic.js", """
        ({ id: "generic", name: "g", version: 1, priority: -5, match: ["^https://x\\\\.test/"], async resolve(u) { return { links: [{ url: u }] }; } })
        """)
        writePlugin(dir, "b_specific.js", simplePlugin(id: "specific", match: "^https://x\\\\.test/"))
        let engine = ResolverEngine(pluginDirectories: [dir])
        #expect(engine.plugin(matching: URL(string: "https://x.test/y")!)?.id == "specific")
    }

    @Test func shippedPluginsLoadCleanly() {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Resources/Plugins")
        let engine = ResolverEngine(pluginDirectories: [dir])
        #expect(engine.loadErrors.isEmpty, "\(engine.loadErrors)")
        let ids = Set(engine.plugins.map(\.id))
        #expect(ids.isSuperset(of: ["mediafire", "apache_index", "bunkr"]))
        #expect(engine.plugin(matching: URL(string: "https://www.mediafire.com/file/abc123/x.zip/file")!)?.id == "mediafire")
        #expect(engine.plugin(matching: URL(string: "https://www.mediafire.com/folder/abc123/name/")!)?.id == "mediafire")
        #expect(engine.plugin(matching: URL(string: "https://bunkr.si/a/PUK068QE")!)?.id == "bunkr")
        #expect(engine.plugin(matching: URL(string: "https://example.com/dir/")!)?.id == "apache_index")
        #expect(engine.plugin(matching: URL(string: "https://example.com/file.zip")!) == nil)
    }

    @Test func pluginFetchesWithHostAPI() async throws {
        let server = try TestServer(); let port = await server.start(); defer { server.stop() }
        _ = port
        let dir = tempDir()
        writePlugin(dir, "t.js", """
        ({ id: "t", name: "t", version: 1, match: ["/page$"],
           async resolve(url, ctx) {
             const res = await http.get(url);
             const links = [];
             const re = /href=['"]([^'"]+)['"]/g; let m;
             while ((m = re.exec(res.body))) links.push({ url: util.absoluteURL(res.url, m[1]), name: decodeURIComponent(m[1].split('/').pop()), headers: { Referer: url } });
             return { packageName: "pkg/../name", links: links };
           } })
        """)
        let engine = ResolverEngine(pluginDirectories: [dir])
        let r = await engine.resolve(server.url("/page"))
        #expect(r.count == 1)
        #expect(r[0].pluginID == "t")
        #expect(r[0].packageName == "pkg_.._name")
        #expect(r[0].links.map(\.url) == [server.url("/ok.bin"), server.url("/files/two%20x.zip")])
        #expect(r[0].links[1].fileName == "two x.zip")
        #expect(r[0].links[0].headers["Referer"] == server.url("/page"))
        #expect(r[0].links[0].sourceURL == server.url("/page"))
        #expect(server.userAgents.first?.hasPrefix("Mozilla/5.0") == true)
    }

    @Test func httpPostCookiesAndRedirects() async throws {
        let server = try TestServer(); _ = await server.start(); defer { server.stop() }
        let dir = tempDir()
        writePlugin(dir, "t.js", """
        ({ id: "t", name: "t", version: 1, match: ["/cookietest$"],
           async resolve(url, ctx) {
             await http.get(url.replace('cookietest', 'setcookie'));
             const c = await http.get(url.replace('cookietest', 'needcookie'));
             const p = await http.post(url.replace('cookietest', 'echo'), { a: 'x y', b: '1&2' });
             const r = await http.get(url.replace('cookietest', 'redirect'));
             const enc = util.btoa("hello") + "|" + util.atob("aGVsbG8=") + "|" + util.base64Decode("aGVsbG8") + "|" + util.decodeEntities("&lt;a&gt; &#65;&#x42; &amp;amp;") + "|" + util.sizeFromString("1.5 GB");
             return { links: [
               { url: "https://e.test/1", name: c.body },
               { url: "https://e.test/2", name: p.body },
               { url: "https://e.test/3", name: r.url.split('/').pop() + ":" + r.status + ":" + (r.headers['content-type'] || '') },
               { url: "https://e.test/4", name: enc }
             ] };
           } })
        """)
        let engine = ResolverEngine(pluginDirectories: [dir])
        let r = await engine.resolve(server.url("/cookietest"))
        let names = r.first?.links.map { $0.fileName ?? "" } ?? []
        #expect(names.count == 4)
        #expect(names[0] == "sid=abc123")
        #expect(names[1] == "POST|application_x-www-form-urlencoded|a=x%20y&b=1%262")
        #expect(names[2] == "page_200_text_html")
        #expect(names[3] == "aGVsbG8=|hello|hello|<a> AB &amp;|1610612736")
    }

    @Test func accountsAreAvailableToPlugins() async {
        let dir = tempDir()
        writePlugin(dir, "t.js", simplePlugin(id: "t", match: "^https://acct\\\\.test/", body: """
        const a = ctx.account("acct.test"); const b = ctx.account("none.test");
        return { links: [{ url: "https://x.test/f", name: (a ? a.username + "," + a.password : "null") + "," + (b === null ? "null" : "set") }] };
        """))
        let engine = ResolverEngine(pluginDirectories: [dir], accounts: { $0 == "acct.test" ? ("u", "p") : nil })
        let r = await engine.resolve("https://acct.test/x")
        #expect(r.first?.links.first?.fileName == "u,p,null")
    }

    @Test func pluginCannotUseNonHTTPSchemes() async {
        let dir = tempDir()
        writePlugin(dir, "t.js", simplePlugin(id: "t", match: "^https://fs\\\\.test/", body: """
        let msg = "ok"; try { await http.get("file:///etc/hosts"); } catch (e) { msg = "blocked"; }
        return { links: [{ url: "https://x.test/f", name: msg }] };
        """))
        let engine = ResolverEngine(pluginDirectories: [dir])
        let r = await engine.resolve("https://fs.test/x")
        #expect(r.first?.links.first?.fileName == "blocked")
    }

    @Test func resolveTimesOutAndReportsOfflineLink() async throws {
        let server = try TestServer(); _ = await server.start(); defer { server.stop() }
        let dir = tempDir()
        writePlugin(dir, "t.js", simplePlugin(id: "t", match: "/slow$", body: "await http.get(url); return { links: [{ url }] };"))
        writePlugin(dir, "u.js", simplePlugin(id: "u", match: "^https://never\\\\.test/", body: "await new Promise(() => {}); return { links: [{ url }] };"))
        let engine = ResolverEngine(pluginDirectories: [dir])
        engine.resolveTimeout = 1
        let t0 = Date()
        let r = await engine.resolve("\(server.url("/slow")) https://never.test/x")
        #expect(Date().timeIntervalSince(t0) < 5)
        #expect(r.count == 2)
        for res in r {
            #expect(res.links.count == 1)
            #expect(res.links[0].status == .offline)
            #expect(res.links[0].headers.isEmpty)
            #expect(res.links[0].fileName == nil)
        }
    }

    @Test func pluginErrorsBecomeOfflineLinks() async {
        let dir = tempDir()
        writePlugin(dir, "t.js", simplePlugin(id: "t", match: "^https://boom\\\\.test/", body: "throw new Error('secret token abc');"))
        writePlugin(dir, "e.js", simplePlugin(id: "e", match: "^https://empty\\\\.test/", body: "return { links: [] };"))
        let engine = ResolverEngine(pluginDirectories: [dir])
        let r = await engine.resolve("https://boom.test/x https://empty.test/y")
        #expect(r.count == 2)
        #expect(r.allSatisfy { $0.links.count == 1 && $0.links[0].status == .offline && $0.links[0].headers.isEmpty })
    }

    @Test func linkCountAndSchemeAreLimited() async {
        let dir = tempDir()
        writePlugin(dir, "t.js", simplePlugin(id: "t", match: "^https://many\\\\.test/", body: """
        const links = []; for (let i = 0; i < 12000; i++) links.push({ url: "https://x.test/" + i });
        links.push({ url: "javascript:alert(1)" }); links.unshift({ url: "ftp://nope" });
        return { links };
        """))
        let engine = ResolverEngine(pluginDirectories: [dir])
        let r = await engine.resolve("https://many.test/x")
        #expect(r.first?.links.count == ResolverLimits.maxLinks)
        #expect(r.first?.links.first?.url == "https://x.test/0")
    }

    @Test func responseBodyIsCapped() async throws {
        let server = try TestServer(); _ = await server.start(); defer { server.stop() }
        let dir = tempDir()
        writePlugin(dir, "t.js", simplePlugin(id: "t", match: "/big$", body: "const r = await http.get(url); return { links: [{ url: 'https://x.test/f', size: r.body.length }] };"))
        let engine = ResolverEngine(pluginDirectories: [dir])
        let r = await engine.resolve(server.url("/big"))
        let capped: Int64 = 8 * 1024 * 1024
        #expect(r.first?.links.first?.size == capped)
    }

    @Test func specialLinksAndFallbacks() async {
        let engine = ResolverEngine(pluginDirectories: [])
        let r = await engine.resolve("magnet:?xt=urn:btih:ABC https://h.test/a.torrent https://h.test/a.metalink https://h.test/dir/file%20one.zip")
        #expect(r.count == 4)
        #expect(r.allSatisfy { $0.pluginID == "direct" && $0.links.count == 1 })
        #expect(r[0].links[0].url == "magnet:?xt=urn:btih:ABC")
        #expect(r[1].links[0].url == "https://h.test/a.torrent")
        #expect(r[3].links[0].fileName == "file one.zip")
        let none = await engine.resolve("no urls here")
        #expect(none.isEmpty)
    }

    @Test func apacheIndexPluginExpandsListing() async throws {
        let server = try TestServer(); _ = await server.start(); defer { server.stop() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = ResolverEngine(pluginDirectories: [root.appendingPathComponent("Resources/Plugins")])
        let r = await engine.resolve(server.url("/index/"))
        #expect(r.first?.pluginID == "apache_index")
        #expect(r.first?.packageName == "index")
        #expect(r.first?.links.map(\.fileName) == ["a b.txt", "c.bin"])
        #expect(r.first?.links.map(\.url) == [server.url("/index/a%20b.txt"), server.url("/index/c.bin")])
    }

    // MARK: checkOnline

    @Test func checkOnlineFillsStatusSizeAndName() async throws {
        let server = try TestServer(); _ = await server.start(); defer { server.stop() }
        let engine = ResolverEngine(pluginDirectories: [])
        func link(_ p: String) -> ResolvedLink { ResolvedLink(url: server.url(p), sourceURL: server.url(p)) }
        let input = [link("/ok.bin"), link("/gone"), link("/cd"), link("/cd2"), link("/nohead.bin"),
                     ResolvedLink(url: "magnet:?xt=urn:btih:ABC", sourceURL: "magnet:?xt=urn:btih:ABC"),
                     ResolvedLink(url: "http://127.0.0.1:1/unreachable", sourceURL: "x")]
        let out = await engine.checkOnline(input)
        #expect(out.count == 7)
        #expect(out[0].status == .online && out[0].size == 1234 && out[0].fileName == "ok.bin")
        #expect(out[1].status == .offline)
        #expect(out[2].status == .online && out[2].fileName == "report final.pdf" && out[2].size == 10)
        #expect(out[3].fileName == "caf\u{00E9}.txt")
        #expect(out[4].status == .online && out[4].size == 777)
        #expect(out[5].status == .unknown)
        #expect(out[6].status == .offline)
        #expect(out.map(\.id) == input.map(\.id))
        var pre = link("/ok.bin"); pre.status = .offline
        #expect(await engine.checkOnline([pre]).first?.status == .offline)
    }

    @Test func contentDispositionParsing() {
        #expect(OnlineChecker.fileName(fromDisposition: "attachment; filename=plain.txt") == "plain.txt")
        #expect(OnlineChecker.fileName(fromDisposition: "attachment; filename=\"a;b.txt\"") == "a;b.txt")
        #expect(OnlineChecker.fileName(fromDisposition: "attachment; filename=\"../../etc/passwd\"") == "_.._etc_passwd" || OnlineChecker.fileName(fromDisposition: "attachment; filename=\"../../etc/passwd\"")?.contains("/") == false)
        #expect(OnlineChecker.fileName(fromDisposition: "inline") == nil)
    }

    // MARK: repository

    private func makeRepo(_ entries: [(id: String, version: Int, source: String, sha: String?)]) -> (index: URL, install: URL) {
        let src = tempDir()
        var items: [[String: Any]] = []
        for e in entries {
            let f = src.appendingPathComponent("\(e.id).js")
            try! e.source.write(to: f, atomically: true, encoding: .utf8)
            items.append(["id": e.id, "version": e.version, "url": f.lastPathComponent, "sha256": e.sha ?? sha256(e.source)])
        }
        let index = src.appendingPathComponent("index.json")
        try! JSONSerialization.data(withJSONObject: ["plugins": items]).write(to: index)
        return (index, tempDir().appendingPathComponent("installed"))
    }

    @Test func repositoryInstallsVerifiesAndUpgrades() async throws {
        let v1 = simplePlugin(id: "alpha", version: 1, match: "^https://alpha\\\\.test/")
        let bad = simplePlugin(id: "beta", version: 1, match: "^https://beta\\\\.test/")
        let (index, install) = makeRepo([("alpha", 1, v1, nil), ("beta", 1, bad, String(repeating: "0", count: 64)), ("../evil", 1, "x", nil)])
        let repo = PluginRepository(installDirectory: install)
        let updated = try await repo.update(from: index)
        #expect(updated == ["alpha"])
        #expect(FileManager.default.fileExists(atPath: install.appendingPathComponent("alpha.js").path))
        #expect(!FileManager.default.fileExists(atPath: install.appendingPathComponent("beta.js").path))
        #expect(repo.lastFailures.contains { $0.hasPrefix("beta:") && $0.contains("sha256") })
        #expect(repo.lastFailures.contains { $0.contains("invalid id") })

        // same version again: nothing to do
        #expect(try await repo.update(from: index).isEmpty)

        // higher version replaces, lower or equal does not
        let v2 = simplePlugin(id: "alpha", version: 2, match: "^https://alpha\\\\.test/")
        let (index2, _) = makeRepo([("alpha", 2, v2, nil)])
        #expect(try await repo.update(from: index2) == ["alpha"])
        #expect(try String(contentsOf: install.appendingPathComponent("alpha.js"), encoding: .utf8) == v2)
        #expect(try await repo.update(from: index).isEmpty)
        #expect(try String(contentsOf: install.appendingPathComponent("alpha.js"), encoding: .utf8) == v2)

        // installed plugins are loadable by the engine
        let engine = ResolverEngine(pluginDirectories: [install])
        #expect(engine.plugins.first?.version == 2)
    }

    @Test func repositoryRejectsBadIndex() async {
        let d = tempDir()
        let f = d.appendingPathComponent("index.json")
        try! "not json".write(to: f, atomically: true, encoding: .utf8)
        let repo = PluginRepository(installDirectory: d.appendingPathComponent("i"))
        await #expect(throws: (any Error).self) { _ = try await repo.update(from: f) }
        await #expect(throws: (any Error).self) { _ = try await repo.update(from: URL(string: "ftp://x.test/index.json")!) }
    }

    // MARK: yt-dlp parsing

    @Test func ytDlpParsesPlaylistAndPicksProgressiveFormat() throws {
        let json = """
        {"_type":"playlist","title":"My List","entries":[
          {"title":"A/B","id":"a","ext":"mp4","webpage_url":"https://v.test/a","formats":[
            {"url":"https://cdn.test/low.mp4","protocol":"https","vcodec":"avc1","acodec":"mp4a","height":360,"ext":"mp4","filesize":100,"http_headers":{"Referer":"https://v.test/"}},
            {"url":"https://cdn.test/hi.mp4","protocol":"https","vcodec":"avc1","acodec":"mp4a","height":720,"ext":"mp4","filesize":999,"http_headers":{"User-Agent":"UA"}},
            {"url":"https://cdn.test/v.m3u8","protocol":"m3u8_native","vcodec":"avc1","acodec":"mp4a","height":1080,"ext":"mp4"},
            {"url":"https://cdn.test/video-only.mp4","protocol":"https","vcodec":"avc1","acodec":"none","height":2160,"ext":"mp4"}]},
          null,
          {"title":"Only HLS","id":"b","formats":[{"url":"https://cdn.test/x.m3u8","protocol":"m3u8_native","vcodec":"a","acodec":"b"}]}
        ]}
        """
        let r = try YtDlpResolver.parse(json: Data(json.utf8), source: "https://v.test/list")
        #expect(r.packageName == "My List")
        #expect(r.links.count == 1)
        #expect(r.links[0].url == "https://cdn.test/hi.mp4")
        #expect(r.links[0].fileName == "A_B.mp4")
        #expect(r.links[0].size == 999)
        #expect(r.links[0].headers == ["User-Agent": "UA"])
    }
}

// MARK: - optional live checks (skipped unless RIVULET_LIVE_URLS is set)

@Suite("ResolverLive")
struct ResolverLiveTests {
    @Test func liveResolve() async {
        guard let urls = ProcessInfo.processInfo.environment["RIVULET_LIVE_URLS"], !urls.isEmpty else { return }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = ResolverEngine(pluginDirectories: [root.appendingPathComponent("Resources/Plugins")])
        engine.logHandler = { print("LOG", $0) }
        for r in await engine.resolve(urls) {
            print("RESULT plugin=\(r.pluginID) package=\(r.packageName ?? "-") links=\(r.links.count)")
            let checked = await engine.checkOnline(Array(r.links.prefix(6)))
            for l in checked { print("  \(l.status.rawValue) \(l.fileName ?? "?") size=\(l.size.map(String.init) ?? "?") headers=\(l.headers.keys.sorted()) url=\(l.url.prefix(90))") }
        }
    }
}

