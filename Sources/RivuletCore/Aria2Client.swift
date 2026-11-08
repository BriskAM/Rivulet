import Foundation

public struct Aria2Endpoint: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var secret: String

    public init(host: String = "localhost", port: Int = 6800, secret: String = "") {
        self.host = host
        self.port = port
        self.secret = secret
    }

    public var webSocketURL: URL { URL(string: "ws://\(host):\(port)/jsonrpc")! }
}

public enum Aria2Error: LocalizedError, Sendable {
    case notConnected
    case timeout
    case rpc(code: Int, message: String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to aria2."
        case .timeout: return "aria2 did not respond in time."
        case .rpc(_, let message): return message
        case .badResponse: return "aria2 returned an unexpected response."
        }
    }

    public var isUnauthorized: Bool {
        if case .rpc(_, let m) = self { return m.lowercased().contains("unauthorized") }
        return false
    }
}

/// JSON-RPC client for aria2 over a WebSocket. Notifications are delivered through `onEvent`.
public actor Aria2Client {
    public let endpoint: Aria2Endpoint

    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private var connected = false

    private var eventHandler: (@Sendable (_ method: String, _ gid: String) -> Void)?
    private var disconnectHandler: (@Sendable () -> Void)?

    public init(endpoint: Aria2Endpoint) {
        self.endpoint = endpoint
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: cfg)
    }

    public func setHandlers(
        onEvent: (@Sendable (String, String) -> Void)?,
        onDisconnect: (@Sendable () -> Void)?
    ) {
        eventHandler = onEvent
        disconnectHandler = onDisconnect
    }

    public var isConnected: Bool { connected }

    // MARK: Connection

    /// Opens the socket and verifies the secret by asking for the version.
    @discardableResult
    public func connect() async throws -> String {
        close()
        let task = session.webSocketTask(with: endpoint.webSocketURL)
        socket = task
        task.resume()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    await self?.handle(message)
                } catch {
                    await self?.socketClosed(task)
                    return
                }
            }
        }
        do {
            let version = try await getVersion()
            connected = true
            return version
        } catch {
            close()
            throw error
        }
    }

    public func close() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
        failAll(Aria2Error.notConnected)
    }

    private func socketClosed(_ task: URLSessionWebSocketTask) {
        guard socket === task else { return }
        socket = nil
        let wasConnected = connected
        connected = false
        failAll(Aria2Error.notConnected)
        if wasConnected { disconnectHandler?() }
    }

    private func failAll(_ error: Error) {
        let all = pending
        pending.removeAll()
        for (_, c) in all { c.resume(throwing: error) }
    }

    // MARK: Transport

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) {
            if let err = obj["error"] as? [String: Any] {
                cont.resume(throwing: Aria2Error.rpc(
                    code: err["code"] as? Int ?? 0,
                    message: err["message"] as? String ?? "Unknown error"))
            } else if let result = obj["result"] {
                cont.resume(returning: result)
            } else {
                cont.resume(throwing: Aria2Error.badResponse)
            }
            return
        }
        if let method = obj["method"] as? String, method.hasPrefix("aria2.on"),
           let params = obj["params"] as? [[String: Any]], let gid = params.first?["gid"] as? String {
            eventHandler?(method, gid)
        }
    }

    private func tokenized(_ params: [Any]) -> [Any] {
        endpoint.secret.isEmpty ? params : ["token:\(endpoint.secret)"] + params
    }

    public func call(_ method: String, _ params: [Any] = [], secured: Bool = true) async throws -> Any {
        guard let socket else { throw Aria2Error.notConnected }
        let id = nextID
        nextID += 1
        let payload: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method,
            "params": secured ? tokenized(params) : params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any, Error>) in
            pending[id] = cont
            Task { [weak self] in
                do {
                    try await socket.send(.string(text))
                } catch {
                    await self?.fail(id: id, error: Aria2Error.notConnected)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                await self?.fail(id: id, error: Aria2Error.timeout)
            }
        }
    }

    private func fail(id: Int, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: High level API

    public func getVersion() async throws -> String {
        let r = try await call("aria2.getVersion")
        return (r as? [String: Any])?["version"] as? String ?? "unknown"
    }

    public func globalStat() async throws -> GlobalStat {
        let r = try await call("aria2.getGlobalStat")
        return Aria2Parser.parseGlobalStat(r as? [String: Any] ?? [:])
    }

    /// Fetches active, waiting and recently stopped downloads in one round trip.
    public func snapshot(stoppedLimit: Int = 200) async throws -> (downloads: [Download], stat: GlobalStat) {
        let keys = Aria2Parser.statusKeys
        func entry(_ method: String, _ extra: [Any]) -> [String: Any] {
            ["methodName": method, "params": tokenized(extra)]
        }
        let calls: [[String: Any]] = [
            entry("aria2.getGlobalStat", []),
            entry("aria2.tellActive", [keys]),
            entry("aria2.tellWaiting", [0, 1000, keys]),
            entry("aria2.tellStopped", [0, stoppedLimit, keys]),
        ]
        let r = try await call("system.multicall", [calls], secured: false)
        guard let results = r as? [Any], results.count == 4 else { throw Aria2Error.badResponse }

        func unwrap(_ any: Any) throws -> Any {
            if let dict = any as? [String: Any], let code = dict["code"] as? Int, let msg = dict["message"] as? String {
                throw Aria2Error.rpc(code: code, message: msg)
            }
            if let arr = any as? [Any], let first = arr.first { return first }
            throw Aria2Error.badResponse
        }

        let stat = Aria2Parser.parseGlobalStat(try unwrap(results[0]) as? [String: Any] ?? [:])
        var list: [Download] = []
        for i in 1...3 {
            let arr = try unwrap(results[i]) as? [[String: Any]] ?? []
            list.append(contentsOf: arr.compactMap(Aria2Parser.parseDownload))
        }
        return (list, stat)
    }

    public func status(_ gid: String, detail: Bool = false) async throws -> Download? {
        let r = try await call("aria2.tellStatus", [gid, detail ? Aria2Parser.detailKeys : Aria2Parser.statusKeys])
        return Aria2Parser.parseDownload(r as? [String: Any] ?? [:])
    }

    public func peers(_ gid: String) async throws -> [Peer] {
        Aria2Parser.parsePeers(try await call("aria2.getPeers", [gid]))
    }

    public func options(_ gid: String) async throws -> [String: String] {
        (try await call("aria2.getOption", [gid]) as? [String: String]) ?? [:]
    }

    public func globalOptions() async throws -> [String: String] {
        (try await call("aria2.getGlobalOption") as? [String: String]) ?? [:]
    }

    public func changeOptions(_ gid: String, _ options: [String: String]) async throws {
        _ = try await call("aria2.changeOption", [gid, options])
    }

    public func changeGlobalOptions(_ options: [String: String]) async throws {
        _ = try await call("aria2.changeGlobalOption", [options])
    }

    @discardableResult
    public func addURIs(_ uris: [String], options: [String: String] = [:]) async throws -> String {
        let r = try await call("aria2.addUri", [uris, options])
        return r as? String ?? ""
    }

    /// Like `addURIs` but accepts option values that are lists (for example several `header` lines).
    @discardableResult
    public func addURIs(_ uris: [String], rawOptions: [String: Any]) async throws -> String {
        let r = try await call("aria2.addUri", [uris, rawOptions])
        return r as? String ?? ""
    }

    @discardableResult
    public func addTorrent(_ data: Data, options: [String: String] = [:]) async throws -> String {
        let r = try await call("aria2.addTorrent", [data.base64EncodedString(), [String](), options])
        return r as? String ?? ""
    }

    @discardableResult
    public func addMetalink(_ data: Data, options: [String: String] = [:]) async throws -> [String] {
        let r = try await call("aria2.addMetalink", [data.base64EncodedString(), options])
        return r as? [String] ?? []
    }

    /// Chooses which files of a multi-file download are fetched. Indexes are aria2's 1-based file numbers.
    public func selectFiles(_ gid: String, indexes: [Int]) async throws {
        let list = indexes.sorted().map(String.init).joined(separator: ",")
        _ = try await call("aria2.changeOption", [gid, ["select-file": list.isEmpty ? "1" : list]])
    }

    /// Adds extra trackers to one torrent.
    public func addTrackers(_ gid: String, _ urls: [String]) async throws {
        guard !urls.isEmpty else { return }
        _ = try await call("aria2.changeOption", [gid, ["bt-tracker": urls.joined(separator: ",")]])
    }

    public func pause(_ gid: String) async throws { _ = try await call("aria2.forcePause", [gid]) }
    public func resume(_ gid: String) async throws { _ = try await call("aria2.unpause", [gid]) }
    public func pauseAll() async throws { _ = try await call("aria2.forcePauseAll") }
    public func resumeAll() async throws { _ = try await call("aria2.unpauseAll") }

    /// Removes a live download, or clears a finished one from the stopped list.
    public func remove(_ gid: String, isStopped: Bool) async throws {
        if isStopped {
            _ = try await call("aria2.removeDownloadResult", [gid])
        } else {
            _ = try await call("aria2.forceRemove", [gid])
        }
    }

    public func purgeStopped() async throws { _ = try await call("aria2.purgeDownloadResult") }
    public func moveToTop(_ gid: String) async throws { _ = try await call("aria2.changePosition", [gid, 0, "POS_SET"]) }
    public func shutdown() async throws { _ = try await call("aria2.shutdown") }
    public func saveSession() async throws { _ = try await call("aria2.saveSession") }
}
