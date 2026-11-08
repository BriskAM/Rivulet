import Foundation

public enum OnlineStatus: String, Sendable { case unknown, online, offline }

public struct ResolvedLink: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Direct download URL (http/https/magnet).
    public var url: String
    public var fileName: String?
    public var size: Int64?
    /// Headers (Referer, Cookie, User-Agent, ...) to forward to aria2.
    public var headers: [String: String]
    public var status: OnlineStatus
    /// The page the user pasted.
    public var sourceURL: String

    public init(id: UUID = UUID(), url: String, fileName: String? = nil, size: Int64? = nil,
                headers: [String: String] = [:], status: OnlineStatus = .unknown, sourceURL: String) {
        self.id = id
        self.url = url
        self.fileName = fileName
        self.size = size
        self.headers = headers
        self.status = status
        self.sourceURL = sourceURL
    }
}

public struct ResolveResult: Sendable {
    public var packageName: String?
    public var links: [ResolvedLink]
    public var pluginID: String

    public init(packageName: String? = nil, links: [ResolvedLink], pluginID: String) {
        self.packageName = packageName
        self.links = links
        self.pluginID = pluginID
    }
}

public struct PluginInfo: Identifiable, Sendable {
    public let id: String
    public var name: String
    public var version: Int
    public var patterns: [String]
    /// "bundled" or "user"
    public var source: String

    public init(id: String, name: String, version: Int, patterns: [String], source: String) {
        self.id = id
        self.name = name
        self.version = version
        self.patterns = patterns
        self.source = source
    }
}

public enum ResolverLimits {
    public static let resolveTimeout: TimeInterval = 30
    public static let maxLinks = 10000
    public static let maxBodyBytes = 8 * 1024 * 1024
}

struct ResolverError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ m: String) { message = m }
}
