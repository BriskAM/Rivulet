import Foundation

/// A finished download handed to the rule engine.
public struct CompletedItem: Sendable {
    public var name: String
    /// Absolute files, or the single top-level folder for multi-file downloads.
    public var paths: [String]
    public var directory: String
    public var totalBytes: Int64
    public var isTorrent: Bool
    public var sourceHost: String?

    public init(name: String, paths: [String], directory: String, totalBytes: Int64, isTorrent: Bool, sourceHost: String? = nil) {
        self.name = name
        self.paths = paths
        self.directory = directory
        self.totalBytes = totalBytes
        self.isTorrent = isTorrent
        self.sourceHost = sourceHost
    }
}

public enum RuleCondition: Codable, Sendable, Hashable {
    case extensionIn([String])
    case nameMatches(String)
    case largerThanMB(Int)
    case smallerThanMB(Int)
    case isTorrent(Bool)
    case sourceHostContains(String)
    case always
}

public enum RuleAction: Codable, Sendable, Hashable {
    case moveTo(String)
    case rename(String)
    case extractArchive(deleteArchive: Bool, intoSubfolder: Bool)
    case open
    case revealInFinder
    case runShortcut(String)
    case moveToTrash
}

public struct Rule: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    /// All conditions must match. An empty list never matches.
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]
    public var stopProcessing: Bool

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, conditions: [RuleCondition], actions: [RuleAction], stopProcessing: Bool = false) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.conditions = conditions
        self.actions = actions
        self.stopProcessing = stopProcessing
    }
}

public struct ActionResult: Sendable {
    public var ruleName: String
    public var action: String
    public var success: Bool
    public var detail: String

    public init(ruleName: String, action: String, success: Bool, detail: String) {
        self.ruleName = ruleName
        self.action = action
        self.success = success
        self.detail = detail
    }
}

/// JSON persistence for rules (atomic writes).
public final class RuleStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> [Rule] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Rule].self, from: data)) ?? []
    }

    public func save(_ rules: [Rule]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rules)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum RuleDefaults {
    /// Example rules, all disabled until the user opts in.
    public static var examples: [Rule] {
        [
            Rule(name: "Unzip archives",
                 enabled: false,
                 conditions: [.extensionIn(["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"])],
                 actions: [.extractArchive(deleteArchive: false, intoSubfolder: true)]),
            Rule(name: "Move installers to ~/Downloads/Installers",
                 enabled: false,
                 conditions: [.extensionIn(["dmg", "pkg"])],
                 actions: [.moveTo("~/Downloads/Installers")]),
            Rule(name: "Sort large videos",
                 enabled: false,
                 conditions: [.extensionIn(["mp4", "mkv", "avi", "mov", "m4v", "webm"]), .largerThanMB(50)],
                 actions: [.moveTo("~/Movies/Downloads")]),
            Rule(name: "File torrents separately",
                 enabled: false,
                 conditions: [.isTorrent(true)],
                 actions: [.moveTo("~/Downloads/Torrents")]),
            Rule(name: "Prefix files with the date",
                 enabled: false,
                 conditions: [.always],
                 actions: [.rename("{date} {name}")]),
            Rule(name: "Reveal big downloads",
                 enabled: false,
                 conditions: [.largerThanMB(1000)],
                 actions: [.revealInFinder]),
        ]
    }
}
