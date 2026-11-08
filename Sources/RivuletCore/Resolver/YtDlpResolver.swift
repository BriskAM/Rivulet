import Foundation

public struct YtDlpResolver {
    public enum Failure: LocalizedError {
        case notInstalled, timedOut, failed(String), noDownloadableFormat
        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "yt-dlp is not installed"
            case .timedOut: return "yt-dlp timed out"
            case .failed(let m): return "yt-dlp failed: \(m)"
            case .noDownloadableFormat: return "no progressive http(s) format found"
            }
        }
    }

    public static func locate() -> String? {
        let fm = FileManager.default
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for d in dirs where !d.isEmpty {
            let p = (d as NSString).appendingPathComponent("yt-dlp")
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    public static func resolve(url: URL) async throws -> ResolveResult {
        guard let exe = locate() else { throw Failure.notInstalled }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw Failure.failed("unsupported URL")
        }
        let json = try await run(exe, ["-J", "--no-warnings", "--ignore-config", "--playlist-end", "200", "--", url.absoluteString], timeout: 60)
        return try parse(json: json, source: url.absoluteString)
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            let q = DispatchQueue(label: "rivulet.ytdlp")
            final class State: @unchecked Sendable { let lock = NSLock(); var out = Data(); var err = Data(); var timedOut = false }
            let st = State()
            let group = DispatchGroup()
            group.enter(); q.async { let d = out.fileHandleForReading.readDataToEndOfFile(); st.lock.lock(); st.out = d; st.lock.unlock(); group.leave() }
            group.enter(); q.async { let d = err.fileHandleForReading.readDataToEndOfFile(); st.lock.lock(); st.err = d; st.lock.unlock(); group.leave() }
            p.terminationHandler = { proc in
                group.notify(queue: .global()) {
                    st.lock.lock(); let o = st.out, e = st.err, to = st.timedOut; st.lock.unlock()
                    if to { cont.resume(throwing: Failure.timedOut) }
                    else if proc.terminationStatus != 0 {
                        let line = String(data: e, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? "exit \(proc.terminationStatus)"
                        cont.resume(throwing: Failure.failed(String(line.prefix(300))))
                    } else { cont.resume(returning: o) }
                }
            }
            do { try p.run() } catch { cont.resume(throwing: Failure.failed(error.localizedDescription)); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { st.lock.lock(); st.timedOut = true; st.lock.unlock(); p.terminate() }
            }
        }
    }

    static func parse(json: Data, source: String) throws -> ResolveResult {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw Failure.failed("unreadable output") }
        var entries: [[String: Any]] = []
        var package: String?
        func collect(_ d: [String: Any]) {
            if (d["_type"] as? String) == "playlist" {
                if package == nil { package = d["title"] as? String }
                for case let e as [String: Any] in (d["entries"] as? [Any] ?? []) { collect(e) }
            } else { entries.append(d) }
        }
        collect(root)
        let links = entries.compactMap { link(for: $0, source: source) }
        if links.isEmpty { throw Failure.noDownloadableFormat }
        return ResolveResult(packageName: package.map(HostUtil.sanitizeFileName), links: links, pluginID: "yt-dlp")
    }

    private static func isHTTP(_ f: [String: Any]) -> Bool {
        guard let u = f["url"] as? String, u.lowercased().hasPrefix("http") else { return false }
        let proto = (f["protocol"] as? String) ?? "https"
        return proto == "https" || proto == "http"
    }

    private static func link(for e: [String: Any], source: String) -> ResolvedLink? {
        let formats = (e["formats"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        func num(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        let progressive = formats.filter { isHTTP($0) && ($0["vcodec"] as? String ?? "none") != "none" && ($0["acodec"] as? String ?? "none") != "none" }
        let audioOnly = formats.filter { isHTTP($0) && ($0["vcodec"] as? String ?? "none") == "none" }
        let pick = progressive.max { (num($0, "height"), num($0, "tbr")) < (num($1, "height"), num($1, "tbr")) }
            ?? (e["requested_formats"] == nil && isHTTP(e) ? e : nil)
            ?? audioOnly.max { num($0, "abr") < num($1, "abr") }
        guard let f = pick, let url = f["url"] as? String else { return nil }
        let ext = (f["ext"] as? String) ?? (e["ext"] as? String) ?? "mp4"
        let title = (e["title"] as? String) ?? (e["id"] as? String) ?? "video"
        var headers: [String: String] = [:]
        for (k, v) in (f["http_headers"] as? [String: Any]) ?? (e["http_headers"] as? [String: Any]) ?? [:] { headers[k] = "\(v)" }
        let size = (f["filesize"] as? NSNumber) ?? (f["filesize_approx"] as? NSNumber)
        return ResolvedLink(url: url, fileName: HostUtil.sanitizeFileName(title + "." + ext), size: size?.int64Value,
                            headers: headers, status: .online, sourceURL: (e["webpage_url"] as? String) ?? source)
    }
}
