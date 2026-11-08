import Foundation

/// Locates and launches an aria2c process owned by the app.
public final class DaemonManager: @unchecked Sendable {
    public static let shared = DaemonManager()

    private var process: Process?
    private let lock = NSLock()

    public init() {}

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Rivulet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Looks inside the app bundle first, then common Homebrew and system locations.
    public static func locateBinary(custom: String? = nil) -> String? {
        var candidates: [String] = []
        if let custom, !custom.isEmpty { candidates.append(custom) }
        if let bundled = Bundle.main.url(forResource: "aria2c", withExtension: nil)?.path {
            candidates.append(bundled)
        }
        candidates += ["/opt/homebrew/bin/aria2c", "/usr/local/bin/aria2c", "/opt/local/bin/aria2c", "/usr/bin/aria2c"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    @discardableResult
    public func start(binary: String, endpoint: Aria2Endpoint, downloadDir: String, extraOptions: [String] = []) throws -> Process {
        lock.lock(); defer { lock.unlock() }
        if let p = process, p.isRunning { return p }

        let support = Self.supportDirectory
        let session = support.appendingPathComponent("aria2.session")
        if !FileManager.default.fileExists(atPath: session.path) {
            FileManager.default.createFile(atPath: session.path, contents: nil)
        }

        // Options go in a private config file so the RPC secret never shows up in `ps`.
        var lines = [
            "enable-rpc=true",
            "rpc-listen-port=\(endpoint.port)",
            "rpc-listen-all=false",
            "rpc-allow-origin-all=false",
            "dir=\(downloadDir)",
            "continue=true",
            "max-connection-per-server=4",
            "split=4",
            "min-split-size=10M",
            "file-allocation=none",
            "input-file=\(session.path)",
            "save-session=\(session.path)",
            "save-session-interval=30",
            "enable-dht6=false",
            "bt-save-metadata=true",
            "follow-torrent=true",
            "seed-ratio=1.0",
            "console-log-level=warn",
            "summary-interval=0",
            "quiet=true",
        ]
        lines.append(contentsOf: extraOptions)
        if !endpoint.secret.isEmpty { lines.append("rpc-secret=\(endpoint.secret)") }
        let conf = support.appendingPathComponent("aria2.conf")
        try (lines.joined(separator: "\n") + "\n").write(to: conf, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: conf.path)
        let args = ["--conf-path=\(conf.path)"]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        // The bundled aria2c finds OpenSSL's legacy provider through this folder instead of Homebrew's.
        let modules = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/ossl-modules").path
        if binary.hasPrefix(Bundle.main.bundlePath), FileManager.default.fileExists(atPath: modules) {
            var env = ProcessInfo.processInfo.environment
            env["OPENSSL_MODULES"] = modules
            p.environment = env
        }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        return p
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        guard let p = process, p.isRunning else { return }
        p.terminate()
        process = nil
    }
}
