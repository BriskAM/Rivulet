import Foundation
import JavaScriptCore

struct PluginMeta {
    var id: String
    var name: String
    var version: Int
    var patterns: [String]
    var priority: Int = 0
}

struct RawLink {
    var url: String
    var name: String?
    var size: Int64?
    var headers: [String: String]
    var status: OnlineStatus
}

struct RawResult {
    var packageName: String?
    var links: [RawLink]
}

enum PluginRuntime {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static let prelude = """
    var http = (function () {
      function enc(o) {
        if (typeof o === 'string') return o;
        var p = [];
        for (var k in o) { if (Object.prototype.hasOwnProperty.call(o, k)) p.push(encodeURIComponent(k) + '=' + encodeURIComponent(o[k])); }
        return p.join('&');
      }
      function req(method, url, body, opts) {
        opts = opts || {};
        return new Promise(function (resolve, reject) {
          __request(method, String(url), body == null ? null : enc(body),
                    JSON.stringify({ headers: opts.headers || {}, timeout: opts.timeout || 0 }),
                    resolve, function (m) { reject(new Error(String(m))); });
        });
      }
      return {
        get: function (url, opts) { return req('GET', url, null, opts); },
        post: function (url, body, opts) { return req('POST', url, body, opts); },
        cookies: function (url) { return __cookies(String(url)); }
      };
    })();
    var util = {
      decodeEntities: __decodeEntities, absoluteURL: __absoluteURL, sizeFromString: __sizeFromString,
      base64Decode: __base64Decode, atob: __atob, btoa: __btoa
    };
    var atob = __atob, btoa = __btoa;
    var log = __log;
    var __run = function (plugin, url, ctx) {
      return Promise.resolve().then(function () { return plugin.resolve(url, ctx); }).then(
        function (r) { __done(JSON.stringify(r === undefined ? null : r)); },
        function (e) { __fail(String(e && e.message ? e.message : e)); });
    };
    """

    // MARK: metadata

    /// Evaluates a plugin file in a bare context (no host API) and extracts metadata.
    static func loadMeta(source: String) throws -> PluginMeta {
        final class Box: @unchecked Sendable { let lock = NSLock(); var result: Result<PluginMeta, Error>? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let t = Thread {
            let r = Result { try loadMetaSync(source: source) }
            box.lock.lock(); box.result = r; box.lock.unlock()
            sem.signal()
        }
        t.stackSize = 4 << 20
        t.start()
        if sem.wait(timeout: .now() + 5) == .timedOut { throw ResolverError("plugin took too long to load") }
        box.lock.lock(); defer { box.lock.unlock() }
        guard let r = box.result else { throw ResolverError("plugin failed to load") }
        return try r.get()
    }

    private static func loadMetaSync(source: String) throws -> PluginMeta {
        guard let ctx = JSContext() else { throw ResolverError("cannot create JS context") }
        var jsError: String?
        ctx.exceptionHandler = { _, e in
            let line = e?.objectForKeyedSubscript("line")?.toString() ?? "?"
            jsError = "\(e?.toString() ?? "error") (line \(line))"
        }
        let value = ctx.evaluateScript(source)
        if let jsError { throw ResolverError("script error: \(jsError)") }
        guard let obj = value, obj.isObject, !obj.isNull else { throw ResolverError("plugin must evaluate to an object") }
        guard let id = obj.forProperty("id")?.toString(), obj.forProperty("id")?.isString == true,
              id.range(of: "^[a-z0-9_-]{1,64}$", options: .regularExpression) != nil
        else { throw ResolverError("missing or invalid id (lowercase letters, digits, - and _)") }
        let name = (obj.forProperty("name")?.isString == true ? obj.forProperty("name")?.toString() : nil) ?? id
        let version = Int(obj.forProperty("version")?.toInt32() ?? 1)
        guard let resolve = obj.forProperty("resolve"), resolve.isObject,
              ctx.evaluateScript("(function(f){return typeof f==='function'})")?.call(withArguments: [resolve])?.toBool() == true
        else { throw ResolverError("missing resolve function") }
        var patterns: [String] = []
        if let m = obj.forProperty("match") {
            if m.isString, let s = m.toString() { patterns = [s] }
            else if m.isArray, let arr = m.toArray() { patterns = arr.compactMap { $0 as? String } }
        }
        guard !patterns.isEmpty else { throw ResolverError("missing match patterns") }
        var meta = PluginMeta(id: id, name: name, version: version, patterns: patterns)
        if let p = obj.forProperty("priority"), p.isNumber { meta.priority = Int(p.toInt32()) }
        return meta
    }

    // MARK: run

    final class Session: @unchecked Sendable {
        let queue = DispatchQueue(label: "rivulet.resolver.js")
        let fetcher: HTTPFetcher
        let accounts: @Sendable (String) -> (username: String, password: String)?
        let log: @Sendable (String) -> Void
        private let lock = NSLock()
        private var done = false
        private var continuation: CheckedContinuation<Result<RawResult, Error>, Never>?
        private var context: JSContext?

        init(accounts: @escaping @Sendable (String) -> (username: String, password: String)?,
             log: @escaping @Sendable (String) -> Void) {
            self.accounts = accounts
            self.log = log
            fetcher = HTTPFetcher()
        }

        func finish(_ r: Result<RawResult, Error>) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            let c = continuation
            continuation = nil
            lock.unlock()
            fetcher.invalidate()
            queue.async { [self] in context = nil }
            c?.resume(returning: r)
        }

        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return done }

        func run(source: String, url: URL, timeout: TimeInterval) async -> Result<RawResult, Error> {
            await withCheckedContinuation { (cont: CheckedContinuation<Result<RawResult, Error>, Never>) in
                lock.lock(); continuation = cont; lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                    finish(.failure(ResolverError("timed out after \(Int(timeout)) s")))
                }
                queue.async { [self] in setupAndStart(source: source, url: url) }
            }
        }

        private func setupAndStart(source: String, url: URL) {
            guard let ctx = JSContext() else { return finish(.failure(ResolverError("no JS context"))) }
            context = ctx
            ctx.exceptionHandler = { [weak self] _, e in
                self?.finish(.failure(ResolverError("script error: \(e?.toString() ?? "unknown")")))
            }
            install(ctx)
            ctx.evaluateScript(prelude)
            guard let plugin = ctx.evaluateScript(source), plugin.isObject else {
                return finish(.failure(ResolverError("plugin did not evaluate to an object")))
            }
            let account: @convention(block) (String) -> Any? = { [accounts] host in
                guard let a = accounts(host) else { return NSNull() }
                return ["username": a.username, "password": a.password]
            }
            guard let jsctx = JSValue(newObjectIn: ctx) else { return finish(.failure(ResolverError("no JS context"))) }
            jsctx.setObject(unsafeBitCast(account, to: AnyObject.self), forKeyedSubscript: "account" as NSString)
            jsctx.setObject(url.absoluteString, forKeyedSubscript: "url" as NSString)
            jsctx.setObject(PluginRuntime.userAgent, forKeyedSubscript: "userAgent" as NSString)
            let run = ctx.objectForKeyedSubscript("__run")
            _ = run?.call(withArguments: [plugin, url.absoluteString, jsctx])
        }

        private func install(_ ctx: JSContext) {
            func set<T>(_ name: String, _ b: T) { ctx.setObject(unsafeBitCast(b, to: AnyObject.self), forKeyedSubscript: name as NSString) }

            let request: @convention(block) (String, String, JSValue, String, JSValue, JSValue) -> Void = { [weak self] method, urlStr, bodyValue, optsJSON, resolve, reject in
                let body: String? = bodyValue.isString ? bodyValue.toString() : nil
                guard let self else { return }
                func fail(_ m: String) { self.queue.async { if !self.isDone { _ = reject.call(withArguments: [m]) } } }
                guard let url = URL(string: urlStr) else { return fail("invalid URL") }
                var headers: [String: String] = [:]
                var timeout: TimeInterval = 0
                if let d = optsJSON.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    if let h = o["headers"] as? [String: Any] { for (k, v) in h { headers[k] = "\(v)" } }
                    timeout = (o["timeout"] as? Double) ?? 0
                    if timeout > 0 { timeout = min(timeout, ResolverLimits.resolveTimeout) }
                }
                if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) { headers["User-Agent"] = PluginRuntime.userAgent }
                var bodyData: Data?
                if let body {
                    bodyData = Data(body.utf8)
                    if !headers.keys.contains(where: { $0.lowercased() == "content-type" }) {
                        headers["Content-Type"] = "application/x-www-form-urlencoded"
                    }
                }
                self.fetcher.perform(method: method, url: url, headers: headers, body: bodyData, timeout: timeout > 0 ? timeout : nil) { result in
                    self.queue.async {
                        if self.isDone { return }
                        switch result {
                        case .failure(let e):
                            _ = reject.call(withArguments: [e.localizedDescription])
                        case .success(let r):
                            let text = String(data: r.body, encoding: .utf8) ?? String(data: r.body, encoding: .isoLatin1) ?? ""
                            let obj: [String: Any] = ["status": r.status, "headers": r.headers, "body": text, "url": r.url.absoluteString]
                            _ = resolve.call(withArguments: [obj])
                        }
                    }
                }
            }
            set("__request", request)
            let cookies: @convention(block) (String) -> String = { [weak self] u in
                guard let self, let url = URL(string: u) else { return "" }
                return self.fetcher.cookieHeader(for: url)
            }
            set("__cookies", cookies)
            let done: @convention(block) (String) -> Void = { [weak self] json in
                self?.finish(Self.parseResult(json))
            }
            set("__done", done)
            let fail: @convention(block) (String) -> Void = { [weak self] m in
                self?.finish(.failure(ResolverError("plugin error: \(m)")))
            }
            set("__fail", fail)
            let log: @convention(block) (String) -> Void = { [weak self] m in self?.log(String(m.prefix(2000))) }
            set("__log", log)
            let decode: @convention(block) (String) -> String = { HostUtil.decodeEntities($0) }
            set("__decodeEntities", decode)
            let abs: @convention(block) (String, String) -> String = { HostUtil.absoluteURL(base: $0, rel: $1) }
            set("__absoluteURL", abs)
            let size: @convention(block) (String) -> Any = { s in
                if let v = HostUtil.sizeFromString(s) { return NSNumber(value: v) }
                return NSNull()
            }
            set("__sizeFromString", size)
            let b64d: @convention(block) (String) -> String = { HostUtil.base64Decode($0, binary: false) }
            set("__base64Decode", b64d)
            let atobB: @convention(block) (String) -> String = { HostUtil.base64Decode($0, binary: true) }
            set("__atob", atobB)
            let btoaB: @convention(block) (String) -> String = { HostUtil.btoa($0) }
            set("__btoa", btoaB)
        }

        static func parseResult(_ json: String) -> Result<RawResult, Error> {
            guard let d = json.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else {
                return .failure(ResolverError("plugin returned unserializable result"))
            }
            var pkg: String?
            var items: [Any] = []
            if let dict = any as? [String: Any] {
                pkg = dict["packageName"] as? String
                items = dict["links"] as? [Any] ?? []
            } else if let arr = any as? [Any] {
                items = arr
            } else {
                return .failure(ResolverError("plugin returned no links"))
            }
            var links: [RawLink] = []
            for item in items {
                if links.count >= ResolverLimits.maxLinks { break }
                var dict: [String: Any]
                if let s = item as? String { dict = ["url": s] }
                else if let d = item as? [String: Any] { dict = d }
                else { continue }
                guard let u = (dict["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                let lower = u.lowercased()
                guard lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("magnet:") else { continue }
                var size: Int64?
                if let n = dict["size"] as? NSNumber, n.doubleValue >= 0 { size = n.int64Value }
                else if let s = dict["size"] as? String { size = HostUtil.sizeFromString(s) ?? Int64(s) }
                var headers: [String: String] = [:]
                if let h = dict["headers"] as? [String: Any] {
                    for (k, v) in h where !(v is NSNull) { headers[k] = "\(v)" }
                }
                let name = ((dict["name"] ?? dict["fileName"]) as? String).map(HostUtil.sanitizeFileName).flatMap { $0.isEmpty ? nil : $0 }
                let status = OnlineStatus(rawValue: (dict["status"] as? String) ?? "") ?? .unknown
                links.append(RawLink(url: u, name: name, size: size, headers: headers, status: status))
            }
            return .success(RawResult(packageName: pkg.map(HostUtil.sanitizeFileName).flatMap { $0.isEmpty ? nil : $0 }, links: links))
        }
    }
}

enum HostUtil {
    static func sanitizeFileName(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        out = out.filter { !$0.isNewline && $0.asciiValue != 0 }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        return String(out.prefix(240))
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "(c)",
        "ndash": "-", "mdash": "-", "hellip": "...", "lsquo": "'", "rsquo": "'", "ldquo": "\"", "rdquo": "\"",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        guard let re = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);") else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let ent = ns.substring(with: m.range(at: 1))
            var rep: String?
            if ent.hasPrefix("#x") || ent.hasPrefix("#X") {
                if let v = UInt32(ent.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
            } else if ent.hasPrefix("#") {
                if let v = UInt32(ent.dropFirst()), let u = Unicode.Scalar(v) { rep = String(Character(u)) }
            } else {
                rep = named[ent]
            }
            out += rep ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    static func absoluteURL(base: String, rel: String) -> String {
        if let b = URL(string: base), let u = URL(string: rel, relativeTo: b) { return u.absoluteURL.absoluteString }
        return rel
    }

    static func sizeFromString(_ s: String) -> Int64? {
        let cleaned = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let re = try? NSRegularExpression(pattern: "^([0-9]*\\.?[0-9]+)\\s*([kmgtp]?)i?b?(ytes?)?$", options: .caseInsensitive),
              let m = re.firstMatch(in: cleaned, range: NSRange(location: 0, length: (cleaned as NSString).length))
        else { return nil }
        let ns = cleaned as NSString
        guard let num = Double(ns.substring(with: m.range(at: 1))) else { return nil }
        let unit = ns.substring(with: m.range(at: 2)).lowercased()
        let pow: Double = ["": 0, "k": 1, "m": 2, "g": 3, "t": 4, "p": 5][unit] ?? 0
        return Int64(num * Foundation.pow(1024, pow))
    }

    static func base64Decode(_ s: String, binary: Bool) -> String {
        var t = s.filter { !$0.isWhitespace }.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { return "" }
        if binary { return String(d.map { Character(Unicode.Scalar($0)) }) }
        return String(data: d, encoding: .utf8) ?? String(d.map { Character(Unicode.Scalar($0)) })
    }

    static func btoa(_ s: String) -> String {
        var bytes: [UInt8] = []
        for u in s.unicodeScalars { bytes.append(u.value <= 255 ? UInt8(u.value) : 63) }
        return Data(bytes).base64EncodedString()
    }
}
