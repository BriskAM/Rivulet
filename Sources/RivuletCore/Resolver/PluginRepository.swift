import Foundation
import CryptoKit

public final class PluginRepository: @unchecked Sendable {
    public struct UpdateError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private let installDirectory: URL
    private let lock = NSLock()
    private var _failures: [String] = []

    public init(installDirectory: URL) { self.installDirectory = installDirectory }

    /// Problems from the last `update` (hash mismatch, bad entry, download failure), one line each.
    public var lastFailures: [String] { lock.lock(); defer { lock.unlock() }; return _failures }

    private func addFailure(_ m: String?) {
        lock.lock(); defer { lock.unlock() }
        if let m { _failures.append(m) } else { _failures = [] }
    }

    private struct Index: Decodable {
        struct Entry: Decodable { var id: String; var version: Int; var url: String; var sha256: String }
        var plugins: [Entry]
    }

    private static func fetch(_ url: URL, limit: Int) async throws -> Data {
        guard let s = url.scheme?.lowercased(), ["http", "https", "file"].contains(s) else { throw UpdateError(message: "unsupported URL scheme") }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.data(from: url)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { throw UpdateError(message: "HTTP \(h.statusCode)") }
        guard data.count <= limit else { throw UpdateError(message: "file too large") }
        return data
    }

    static func installedVersion(of file: URL) -> Int? {
        guard let s = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return textVersion(s)
    }

    /// Reads `version: N` from plugin text without evaluating it.
    static func textVersion(_ s: String) -> Int? {
        guard let r = s.range(of: "\\bversion\\s*:\\s*([0-9]+)", options: .regularExpression) else { return nil }
        return Int(s[r].filter(\.isNumber))
    }

    public func update(from indexURL: URL) async throws -> [String] {
        addFailure(nil)
        let indexData = try await Self.fetch(indexURL, limit: 1_000_000)
        let index: Index
        do { index = try JSONDecoder().decode(Index.self, from: indexData) }
        catch { throw UpdateError(message: "invalid index.json") }
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        var updated: [String] = []
        for e in index.plugins.prefix(500) {
            func fail(_ m: String) { addFailure("\(e.id): \(m)") }
            guard e.id.range(of: "^[a-z0-9_-]{1,64}$", options: .regularExpression) != nil else { fail("invalid id"); continue }
            let target = installDirectory.appendingPathComponent(e.id + ".js")
            if let have = Self.installedVersion(of: target), have >= e.version { continue }
            guard let src = URL(string: e.url, relativeTo: indexURL)?.absoluteURL else { fail("invalid url"); continue }
            do {
                let data = try await Self.fetch(src, limit: 1_000_000)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == e.sha256.lowercased() else { fail("sha256 mismatch, file rejected"); continue }
                guard let text = String(data: data, encoding: .utf8) else { fail("not UTF-8 text"); continue }
                if let v = Self.textVersion(text), v != e.version { fail("version in file (\(v)) differs from index (\(e.version))"); continue }
                try data.write(to: target, options: .atomic)
                updated.append(e.id)
            } catch {
                fail("download failed: \(error.localizedDescription)")
            }
        }
        return updated
    }
}
