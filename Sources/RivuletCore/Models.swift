import Foundation

public enum DownloadStatus: String, Sendable {
    case active, waiting, paused, error, complete, removed, unknown

    public init(raw: String?) {
        self = DownloadStatus(rawValue: raw ?? "") ?? .unknown
    }
}

public struct DownloadFile: Identifiable, Hashable, Sendable {
    public var id: Int { index }
    public let index: Int
    public let path: String
    public let length: Int64
    public let completedLength: Int64
    public let selected: Bool

    public var name: String { (path as NSString).lastPathComponent }
    public var fraction: Double { length > 0 ? Double(completedLength) / Double(length) : 0 }
}

public struct Peer: Identifiable, Hashable, Sendable {
    public var id: String { "\(address):\(port)" }
    public let address: String
    public let port: String
    public let client: String
    public let downloadSpeed: Int64
    public let uploadSpeed: Int64
    public let seeder: Bool
    public let progress: Double
    public let amChoking: Bool
    public let peerChoking: Bool
    public let bitfield: String

    /// Short flags in the style of other clients: d/u mean we are downloading from / uploading to the peer,
    /// D/U mean we would but are choked.
    public var flags: String {
        var f = ""
        f += peerChoking ? (downloadSpeed > 0 ? "D" : "d") : "D"
        f += amChoking ? "u" : "U"
        if seeder { f += "S" }
        return f
    }
}

public struct Download: Identifiable, Hashable, Sendable {
    public let id: String          // gid
    public var status: DownloadStatus
    public var name: String
    public var dir: String
    public var totalLength: Int64
    public var completedLength: Int64
    public var uploadLength: Int64
    public var downloadSpeed: Int64
    public var uploadSpeed: Int64
    public var connections: Int
    public var numSeeders: Int
    public var isSeeder: Bool
    public var isTorrent: Bool
    public var infoHash: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var files: [DownloadFile]
    public var primaryURI: String?
    public var comment: String?
    public var creationDate: Date?
    public var numPieces: Int
    public var pieceLength: Int64
    public var followedBy: [String]
    public var verifyPending: Bool
    public var trackers: [[String]]
    public var bitfield: String?

    public var fraction: Double {
        totalLength > 0 ? min(1, Double(completedLength) / Double(totalLength)) : 0
    }

    public var ratio: Double {
        completedLength > 0 ? Double(uploadLength) / Double(completedLength) : 0
    }

    /// Seconds remaining at the current speed, or nil when unknown.
    public var eta: TimeInterval? {
        guard downloadSpeed > 0, totalLength > completedLength else { return nil }
        return Double(totalLength - completedLength) / Double(downloadSpeed)
    }

    /// A finished torrent that aria2 keeps seeding is reported as active.
    public var isSeeding: Bool { status == .active && isSeeder && isTorrent }

    /// aria2 reports a magnet metadata fetch as a download that is replaced by a follow-up gid.
    public var isMetadataOnly: Bool { !followedBy.isEmpty }

    public var magnetLink: String? {
        guard let hash = infoHash, isTorrent else { return nil }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return "magnet:?xt=urn:btih:\(hash)&dn=\(encoded)"
    }

    public var localPath: String {
        if files.count == 1, let first = files.first, !first.path.isEmpty { return first.path }
        if isTorrent, files.count > 1 { return (dir as NSString).appendingPathComponent(name) }
        return files.first.map { $0.path } ?? dir
    }

    public init(
        id: String, status: DownloadStatus = .unknown, name: String = "", dir: String = "",
        totalLength: Int64 = 0, completedLength: Int64 = 0, uploadLength: Int64 = 0,
        downloadSpeed: Int64 = 0, uploadSpeed: Int64 = 0, connections: Int = 0, numSeeders: Int = 0,
        isSeeder: Bool = false, isTorrent: Bool = false, infoHash: String? = nil,
        errorCode: String? = nil, errorMessage: String? = nil, files: [DownloadFile] = [],
        primaryURI: String? = nil, comment: String? = nil, creationDate: Date? = nil,
        numPieces: Int = 0, pieceLength: Int64 = 0, followedBy: [String] = [], verifyPending: Bool = false,
        trackers: [[String]] = [], bitfield: String? = nil
    ) {
        self.id = id; self.status = status; self.name = name; self.dir = dir
        self.totalLength = totalLength; self.completedLength = completedLength
        self.uploadLength = uploadLength; self.downloadSpeed = downloadSpeed
        self.uploadSpeed = uploadSpeed; self.connections = connections; self.numSeeders = numSeeders
        self.isSeeder = isSeeder; self.isTorrent = isTorrent; self.infoHash = infoHash
        self.errorCode = errorCode; self.errorMessage = errorMessage; self.files = files
        self.primaryURI = primaryURI; self.comment = comment; self.creationDate = creationDate
        self.numPieces = numPieces; self.pieceLength = pieceLength; self.followedBy = followedBy
        self.verifyPending = verifyPending
        self.trackers = trackers
        self.bitfield = bitfield
    }
}

public struct GlobalStat: Sendable, Equatable {
    public var downloadSpeed: Int64 = 0
    public var uploadSpeed: Int64 = 0
    public var numActive: Int = 0
    public var numWaiting: Int = 0
    public var numStopped: Int = 0
    public init() {}
}

// MARK: - Parsing aria2 status dictionaries (all values arrive as strings)

public enum Aria2Parser {
    public static let statusKeys = [
        "gid", "status", "totalLength", "completedLength", "uploadLength", "downloadSpeed",
        "uploadSpeed", "connections", "numSeeders", "seeder", "bittorrent", "infoHash", "dir",
        "files", "errorCode", "errorMessage", "numPieces", "pieceLength", "followedBy",
        "verifyIntegrityPending",
    ]

    /// Adds the piece bitfield, which is large, so it is only requested for the inspector.
    public static let detailKeys = statusKeys + ["bitfield"]

    static func int64(_ any: Any?) -> Int64 {
        if let s = any as? String { return Int64(s) ?? 0 }
        if let n = any as? NSNumber { return n.int64Value }
        return 0
    }

    static func int(_ any: Any?) -> Int { Int(int64(any)) }

    static func bool(_ any: Any?) -> Bool {
        if let s = any as? String { return s == "true" }
        if let b = any as? Bool { return b }
        return false
    }

    public static func parseFiles(_ any: Any?) -> [DownloadFile] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.map { f in
            DownloadFile(
                index: int(f["index"]),
                path: f["path"] as? String ?? "",
                length: int64(f["length"]),
                completedLength: int64(f["completedLength"]),
                selected: bool(f["selected"])
            )
        }
    }

    public static func parseDownload(_ d: [String: Any]) -> Download? {
        guard let gid = d["gid"] as? String else { return nil }
        let files = parseFiles(d["files"])
        let bt = d["bittorrent"] as? [String: Any]
        let isTorrent = bt != nil
        var name = ""
        if let info = bt?["info"] as? [String: Any], let n = info["name"] as? String { name = n }
        var uri: String?
        if let first = (d["files"] as? [[String: Any]])?.first,
           let uris = first["uris"] as? [[String: Any]], let u = uris.first?["uri"] as? String {
            uri = u
        }
        if name.isEmpty {
            if files.count == 1, !(files[0].path.isEmpty) {
                name = files[0].name
            } else if let u = uri, let url = URL(string: u), !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" {
                name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            } else if let first = files.first, !first.path.isEmpty {
                name = first.name
            }
        }
        if name.isEmpty, let hash = d["infoHash"] as? String { name = hash }
        if name.isEmpty { name = "Unknown" }

        var creation: Date?
        if let ts = bt?["creationDate"] as? NSNumber { creation = Date(timeIntervalSince1970: ts.doubleValue) }

        return Download(
            id: gid,
            status: DownloadStatus(raw: d["status"] as? String),
            name: name,
            dir: d["dir"] as? String ?? "",
            totalLength: int64(d["totalLength"]),
            completedLength: int64(d["completedLength"]),
            uploadLength: int64(d["uploadLength"]),
            downloadSpeed: int64(d["downloadSpeed"]),
            uploadSpeed: int64(d["uploadSpeed"]),
            connections: int(d["connections"]),
            numSeeders: int(d["numSeeders"]),
            isSeeder: bool(d["seeder"]),
            isTorrent: isTorrent,
            infoHash: d["infoHash"] as? String,
            errorCode: d["errorCode"] as? String,
            errorMessage: d["errorMessage"] as? String,
            files: files,
            primaryURI: uri,
            comment: (bt?["comment"] as? String),
            creationDate: creation,
            numPieces: int(d["numPieces"]),
            pieceLength: int64(d["pieceLength"]),
            followedBy: d["followedBy"] as? [String] ?? [],
            verifyPending: bool(d["verifyIntegrityPending"]),
            trackers: bt?["announceList"] as? [[String]] ?? [],
            bitfield: d["bitfield"] as? String
        )
    }

    public static func parseGlobalStat(_ d: [String: Any]) -> GlobalStat {
        var g = GlobalStat()
        g.downloadSpeed = int64(d["downloadSpeed"])
        g.uploadSpeed = int64(d["uploadSpeed"])
        g.numActive = int(d["numActive"])
        g.numWaiting = int(d["numWaiting"])
        g.numStopped = int(d["numStopped"])
        return g
    }

    public static func parsePeers(_ any: Any?) -> [Peer] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.map { p in
            var clientName = "Unknown"
            if let peerID = p["peerId"] as? String { clientName = decodePeerID(peerID) }
            var progress = 0.0
            if let bitfield = p["bitfield"] as? String, !bitfield.isEmpty {
                let ones = bitfield.reduce(0) { $0 + (Int(String($1), radix: 16)?.nonzeroBitCount ?? 0) }
                progress = Double(ones) / Double(bitfield.count * 4)
            }
            return Peer(
                address: p["ip"] as? String ?? "",
                port: p["port"] as? String ?? "",
                client: clientName,
                downloadSpeed: int64(p["downloadSpeed"]),
                uploadSpeed: int64(p["uploadSpeed"]),
                seeder: bool(p["seeder"]),
                progress: progress,
                amChoking: bool(p["amChoking"]),
                peerChoking: bool(p["peerChoking"]),
                bitfield: p["bitfield"] as? String ?? ""
            )
        }
    }

    /// aria2 returns the peer id percent-encoded. Azureus style ids look like -qB4650-xxxxxxxxxxxx.
    static func decodePeerID(_ encoded: String) -> String {
        let decoded = encoded.removingPercentEncoding ?? encoded
        guard decoded.count >= 8, decoded.first == "-" else { return String(decoded.prefix(8)) }
        let chars = Array(decoded)
        let code = String(chars[1...2])
        let version = String(chars[3...6])
        let known = [
            "qB": "qBittorrent", "TR": "Transmission", "UT": "uTorrent", "DE": "Deluge",
            "AZ": "Vuze", "LT": "libtorrent", "lt": "libTorrent", "BT": "BitTorrent",
            "KG": "KGet", "WW": "WebTorrent", "A2": "aria2", "FD": "Free Download Manager",
        ]
        return "\(known[code] ?? code) \(version)"
    }
}
