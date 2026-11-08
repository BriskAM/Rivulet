import Foundation

public struct FeedFilter: Codable, Sendable, Hashable {
    /// Case-insensitive regex tested against the title. Empty means include everything.
    public var includeRegex: String
    /// Case-insensitive regex; matching titles are dropped. Empty means exclude nothing.
    public var excludeRegex: String
    /// 0 disables the bound. Items with an unknown size pass the size checks.
    public var minMB: Int
    public var maxMB: Int

    public init(includeRegex: String = "", excludeRegex: String = "", minMB: Int = 0, maxMB: Int = 0) {
        self.includeRegex = includeRegex
        self.excludeRegex = excludeRegex
        self.minMB = minMB
        self.maxMB = maxMB
    }

    /// An invalid regex fails closed (the item does not match).
    public func matches(_ item: FeedItem) -> Bool {
        let range = NSRange(item.title.startIndex..., in: item.title)
        if !includeRegex.isEmpty {
            guard let re = try? NSRegularExpression(pattern: includeRegex, options: [.caseInsensitive]),
                  re.firstMatch(in: item.title, options: [], range: range) != nil else { return false }
        }
        if !excludeRegex.isEmpty {
            guard let re = try? NSRegularExpression(pattern: excludeRegex, options: [.caseInsensitive]) else { return false }
            if re.firstMatch(in: item.title, options: [], range: range) != nil { return false }
        }
        if let size = item.size {
            if minMB > 0 && size < Int64(minMB) * 1_048_576 { return false }
            if maxMB > 0 && size > Int64(maxMB) * 1_048_576 { return false }
        }
        return true
    }
}

public struct FeedSubscription: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var url: String
    public var intervalMinutes: Int
    public var filter: FeedFilter
    public var enabled: Bool
    public var downloadDirectory: String?

    public init(id: UUID = UUID(), name: String, url: String, intervalMinutes: Int = 30, filter: FeedFilter = FeedFilter(),
                enabled: Bool = true, downloadDirectory: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.intervalMinutes = intervalMinutes
        self.filter = filter
        self.enabled = enabled
        self.downloadDirectory = downloadDirectory
    }
}

public final class FeedMonitor: @unchecked Sendable {
    public static let maxResponseBytes = 5 * 1024 * 1024
    public static let maxSeenPerFeed = 5000

    private struct State: Codable { var seen: [String: [String]] = [:] }

    private let stateURL: URL
    private let fetch: @Sendable (URL) async throws -> Data
    private let lock = NSLock()
    private var state: State

    public init(stateURL: URL, fetch: @escaping @Sendable (URL) async throws -> Data = FeedMonitor.defaultFetch) {
        self.stateURL = stateURL
        self.fetch = fetch
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: data) {
            self.state = s
        } else {
            self.state = State()
        }
    }

    /// Fetches over http(s) with a 20 s timeout and a 5 MB cap.
    public static let defaultFetch: @Sendable (URL) async throws -> Data = { url in
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 20
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw FeedError.badStatus(http.statusCode) }
        if response.expectedContentLength > Int64(FeedMonitor.maxResponseBytes) { throw FeedError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > FeedMonitor.maxResponseBytes { throw FeedError.tooLarge }
        }
        return data
    }

    /// Returns items not seen before that pass the filter, then marks all new items seen.
    /// The first poll of a subscription marks everything seen and returns nothing unless `emitInitial`.
    public func poll(_ sub: FeedSubscription, emitInitial: Bool = false) async throws -> [FeedItem] {
        guard let url = URL(string: sub.url), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { throw FeedError.invalidURL }
        let data = try await fetch(url)
        if data.count > Self.maxResponseBytes { throw FeedError.tooLarge }
        let items = try FeedParser.parse(data).items

        return try record(items, for: sub, emitInitial: emitInitial)
    }

    private func record(_ items: [FeedItem], for sub: FeedSubscription, emitInitial: Bool) throws -> [FeedItem] {
        lock.lock(); defer { lock.unlock() }
        let key = sub.id.uuidString
        let previous = state.seen[key]
        let known = Set(previous ?? [])
        var batch = Set<String>()
        var fresh: [FeedItem] = []
        for item in items where !known.contains(item.guid) && batch.insert(item.guid).inserted {
            fresh.append(item)
        }
        var seen = previous ?? []
        seen.append(contentsOf: fresh.reversed().map(\.guid))   // feeds list newest first; keep newest at the end
        if seen.count > Self.maxSeenPerFeed { seen.removeFirst(seen.count - Self.maxSeenPerFeed) }
        state.seen[key] = seen
        try saveState()

        if previous == nil && !emitInitial { return [] }
        return fresh.filter { sub.filter.matches($0) }
    }

    /// Forgets the seen list of a subscription (for example when it is deleted).
    public func reset(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        state.seen[id.uuidString] = nil
        try? saveState()
    }

    private func saveState() throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
}
