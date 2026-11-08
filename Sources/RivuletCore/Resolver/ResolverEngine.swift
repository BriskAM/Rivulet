import Foundation

public final class ResolverEngine: @unchecked Sendable {
    private struct Loaded {
        var info: PluginInfo
        var source: String
        var regexes: [NSRegularExpression]
        var priority: Int
    }

    private let directories: [URL]
    private let bundledDirectories: [URL]
    private let accounts: @Sendable (String) -> (username: String, password: String)?
    private let lock = NSLock()
    private var loaded: [Loaded] = []
    private var errors: [String] = []

    /// Per-resolve time limit; overridable for tests.
    var resolveTimeout: TimeInterval = ResolverLimits.resolveTimeout

    /// Optional sink for plugin `log()` calls and load diagnostics.
    public var logHandler: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - pluginDirectories: searched in order; earlier directories win.
    ///   - bundledDirectories: directories whose plugins are reported as "bundled". If empty and more than one
    ///     directory is given, the last directory is treated as bundled; otherwise all are "user".
    public init(pluginDirectories: [URL], bundledDirectories: [URL] = [],
                accounts: @escaping @Sendable (_ host: String) -> (username: String, password: String)? = { _ in nil }) {
        self.directories = pluginDirectories
        if bundledDirectories.isEmpty, pluginDirectories.count > 1, let last = pluginDirectories.last {
            self.bundledDirectories = [last]
        } else {
            self.bundledDirectories = bundledDirectories
        }
        self.accounts = accounts
        reload()
    }

    /// Human readable problems found by the last `reload()` (parse errors, bad patterns, ...).
    public var loadErrors: [String] { lock.lock(); defer { lock.unlock() }; return errors }

    public func reload() {
        var result: [Loaded] = []
        var seen = Set<String>()
        var errs: [String] = []
        let fm = FileManager.default
        for dir in directories {
            let isBundled = bundledDirectories.contains { $0.standardizedFileURL.path == dir.standardizedFileURL.path }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            var dirLoaded: [Loaded] = []
            for f in files.filter({ $0.pathExtension.lowercased() == "js" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let data = try Data(contentsOf: f)
                    guard data.count <= 1_000_000, let src = String(data: data, encoding: .utf8) else {
                        throw ResolverError("not UTF-8 text or larger than 1 MB")
                    }
                    let meta = try PluginRuntime.loadMeta(source: src)
                    let regexes = try meta.patterns.map { try NSRegularExpression(pattern: $0) }
                    if seen.contains(meta.id) { continue }
                    seen.insert(meta.id)
                    dirLoaded.append(Loaded(info: PluginInfo(id: meta.id, name: meta.name, version: meta.version,
                                                          patterns: meta.patterns, source: isBundled ? "bundled" : "user"),
                                         source: src, regexes: regexes, priority: meta.priority))
                } catch {
                    let msg = "\(f.lastPathComponent): \(error.localizedDescription)"
                    errs.append(msg)
                    logHandler?("plugin skipped: \(msg)")
                }
            }
            // stable: higher priority first, then file name order
            result += dirLoaded.enumerated().sorted { ($0.element.priority, -$0.offset) > ($1.element.priority, -$1.offset) }.map(\.element)
        }
        lock.lock(); loaded = result; errors = errs; lock.unlock()
    }

    public var plugins: [PluginInfo] { lock.lock(); defer { lock.unlock() }; return loaded.map(\.info) }

    private func loadedPlugin(matching url: URL) -> Loaded? {
        let s = url.absoluteString
        let range = NSRange(location: 0, length: (s as NSString).length)
        lock.lock(); let list = loaded; lock.unlock()
        return list.first { p in p.regexes.contains { $0.firstMatch(in: s, range: range) != nil } }
    }

    public func plugin(matching url: URL) -> PluginInfo? { loadedPlugin(matching: url)?.info }

    // MARK: resolve

    public func resolve(_ input: String, useYtDlpFallback: Bool = false) async -> [ResolveResult] {
        let urls = Self.extractURLs(from: input)
        var results = [ResolveResult?](repeating: nil, count: urls.count)
        await withTaskGroup(of: (Int, ResolveResult).self) { group in
            var next = 0
            func add() {
                guard next < urls.count else { return }
                let i = next, u = urls[i]
                next += 1
                group.addTask { [self] in (i, await resolveOne(u, useYtDlp: useYtDlpFallback)) }
            }
            for _ in 0..<min(4, urls.count) { add() }
            while let (i, r) = await group.next() { results[i] = r; add() }
        }
        return results.compactMap { $0 }
    }

    private func resolveOne(_ url: URL, useYtDlp: Bool) async -> ResolveResult {
        let src = url.absoluteString
        let lower = src.lowercased()
        let ext = url.pathExtension.lowercased()
        if lower.hasPrefix("magnet:") || ["torrent", "metalink", "meta4"].contains(ext) {
            return Self.direct(url, name: nil)
        }
        if let p = loadedPlugin(matching: url) {
            let session = PluginRuntime.Session(accounts: accounts, log: { [weak self] in self?.logHandler?("[\(p.info.id)] \($0)") })
            let r = await session.run(source: p.source, url: url, timeout: resolveTimeout)
            switch r {
            case .success(let raw):
                let links = raw.links.map {
                    ResolvedLink(url: $0.url, fileName: $0.name, size: $0.size, headers: $0.headers, status: $0.status, sourceURL: src)
                }
                if links.isEmpty { return Self.failure(src, plugin: p.info.id, note: "plugin returned no links") }
                return ResolveResult(packageName: raw.packageName, links: links, pluginID: p.info.id)
            case .failure(let e):
                logHandler?("[\(p.info.id)] failed: \(e.localizedDescription)")
                return Self.failure(src, plugin: p.info.id, note: e.localizedDescription)
            }
        }
        if useYtDlp, YtDlpResolver.locate() != nil, let r = try? await YtDlpResolver.resolve(url: url) {
            return r
        }
        return Self.direct(url, name: nil)
    }

    static func direct(_ url: URL, name: String?) -> ResolveResult {
        var fileName = name
        if fileName == nil, url.scheme?.lowercased().hasPrefix("http") == true {
            let last = url.lastPathComponent
            if last.contains("."), last != "/" { fileName = HostUtil.sanitizeFileName(last.removingPercentEncoding ?? last) }
        }
        let link = ResolvedLink(url: url.absoluteString, fileName: fileName, sourceURL: url.absoluteString)
        return ResolveResult(packageName: nil, links: [link], pluginID: "direct")
    }

    /// Failure placeholder: one offline link pointing at the pasted URL, with no headers or details attached.
    static func failure(_ src: String, plugin: String, note: String) -> ResolveResult {
        ResolveResult(packageName: nil,
                      links: [ResolvedLink(url: src, status: .offline, sourceURL: src)],
                      pluginID: plugin)
    }

    // MARK: URL extraction

    public static func extractURLs(from text: String) -> [URL] {
        guard let startRe = try? NSRegularExpression(pattern: "(?:https?://|magnet:\\?)", options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        let starts = startRe.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range.location)
        var out: [URL] = []
        var seen = Set<String>()
        let stop = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'`|\\^{}"))
        for (i, s) in starts.enumerated() {
            var end = i + 1 < starts.count ? starts[i + 1] : ns.length
            var token = ns.substring(with: NSRange(location: s, length: end - s))
            if let r = token.rangeOfCharacter(from: stop) { token = String(token[..<r.lowerBound]) }
            end = s + (token as NSString).length
            token = trimTrailing(token)
            guard token.count > 8 else { continue }
            if token.lowercased().hasPrefix("http") {
                // a bare scheme with no host is not a URL
                guard let u = URL(string: token) ?? URL(string: token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.union(CharacterSet(charactersIn: "%#/:@!$&'()*+,;=[]"))) ?? ""),
                      let host = u.host, !host.isEmpty else { continue }
                if seen.insert(u.absoluteString).inserted { out.append(u) }
            } else if let u = URL(string: token), seen.insert(token).inserted {
                out.append(u)
            }
        }
        return out
    }

    private static func trimTrailing(_ s: String) -> String {
        var t = s
        while let c = t.last {
            if ".,;:!?'\u{201D}\u{2019}*".contains(c) { t.removeLast(); continue }
            if c == ")" , t.filter({ $0 == "(" }).count < t.filter({ $0 == ")" }).count { t.removeLast(); continue }
            if c == "]" , t.filter({ $0 == "[" }).count < t.filter({ $0 == "]" }).count { t.removeLast(); continue }
            break
        }
        return t
    }

    // MARK: online check

    public func checkOnline(_ links: [ResolvedLink]) async -> [ResolvedLink] {
        var out = links
        await withTaskGroup(of: (Int, ResolvedLink).self) { group in
            var next = 0
            func add() {
                guard next < links.count else { return }
                let i = next
                next += 1
                group.addTask { (i, await OnlineChecker.check(links[i])) }
            }
            for _ in 0..<min(6, links.count) { add() }
            while let (i, l) = await group.next() { out[i] = l; add() }
        }
        return out
    }
}

enum OnlineChecker {
    static func check(_ link: ResolvedLink) async -> ResolvedLink {
        var l = link
        // Failure placeholders (and anything a plugin already marked offline) are left alone.
        if link.status == .offline { return l }
        guard let url = URL(string: link.url), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return l }
        let fetcher = HTTPFetcher(timeout: 10, resourceTimeout: 20)
        defer { fetcher.invalidate() }
        var res = await fetcher.perform(method: "HEAD", url: url, headers: link.headers, timeout: 10, maxBody: 1024)
        var usedGet = false
        var needGet = true
        if case .success(let r) = res, (200..<300).contains(r.status) || r.status == 404 || r.status == 410 { needGet = false }
        if needGet {
            var h = link.headers
            h["Range"] = "bytes=0-0"
            res = await fetcher.perform(method: "GET", url: url, headers: h, timeout: 10, maxBody: 1024)
            usedGet = true
        }
        switch res {
        case .failure:
            l.status = .offline
        case .success(let r):
            if (200..<300).contains(r.status) {
                l.status = .online
                if usedGet, r.status == 206, let cr = r.headers["content-range"], let total = cr.split(separator: "/").last, let n = Int64(total) {
                    l.size = n
                } else if let cl = r.headers["content-length"], let n = Int64(cl), !(usedGet && r.status == 206) {
                    l.size = n
                }
                if l.fileName == nil {
                    if let cd = r.headers["content-disposition"], let n = fileName(fromDisposition: cd) {
                        l.fileName = n
                    } else {
                        let last = r.url.lastPathComponent
                        if !last.isEmpty, last != "/" { l.fileName = HostUtil.sanitizeFileName(last.removingPercentEncoding ?? last) }
                    }
                }
            } else if r.status == 404 || r.status == 410 {
                l.status = .offline
            } else {
                l.status = .unknown
            }
        }
        return l
    }

    static func fileName(fromDisposition cd: String) -> String? {
        if let r = cd.range(of: "filename\\*\\s*=\\s*[^']*'[^']*'([^;]+)", options: [.regularExpression, .caseInsensitive]) {
            let part = String(cd[r])
            if let q = part.lastIndex(of: "'") {
                let enc = String(part[part.index(after: q)...]).trimmingCharacters(in: .whitespaces)
                if let dec = enc.removingPercentEncoding, !HostUtil.sanitizeFileName(dec).isEmpty { return HostUtil.sanitizeFileName(dec) }
            }
        }
        if let r = cd.range(of: "filename\\s*=\\s*(\"[^\"]*\"|[^;]+)", options: [.regularExpression, .caseInsensitive]) {
            var v = String(cd[r])
            v = String(v[v.index(after: v.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespaces)
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let s = HostUtil.sanitizeFileName(v)
            return s.isEmpty ? nil : s
        }
        return nil
    }
}
