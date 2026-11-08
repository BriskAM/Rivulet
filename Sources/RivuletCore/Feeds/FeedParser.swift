import Foundation

public struct FeedItem: Sendable, Hashable {
    public var guid: String
    public var title: String
    public var link: String?
    public var enclosureURL: String?
    public var enclosureType: String?
    public var magnet: String?
    public var published: Date?
    public var size: Int64?

    public init(guid: String, title: String, link: String? = nil, enclosureURL: String? = nil, enclosureType: String? = nil,
                magnet: String? = nil, published: Date? = nil, size: Int64? = nil) {
        self.guid = guid
        self.title = title
        self.link = link
        self.enclosureURL = enclosureURL
        self.enclosureType = enclosureType
        self.magnet = magnet
        self.published = published
        self.size = size
    }
}

public enum FeedError: Error, CustomStringConvertible {
    case invalidXML(String)
    case forbiddenContent
    case invalidURL
    case tooLarge
    case badStatus(Int)

    public var description: String {
        switch self {
        case .invalidXML(let m): return "Invalid feed XML: \(m)"
        case .forbiddenContent: return "Feed contains entity declarations, which are not allowed"
        case .invalidURL: return "Feed URL must be http or https"
        case .tooLarge: return "Feed is larger than 5 MB"
        case .badStatus(let s): return "Feed server returned HTTP \(s)"
        }
    }
}

public enum FeedParser {
    public static func parse(_ data: Data) throws -> (title: String, items: [FeedItem]) {
        // Refuse DTD entity declarations outright (billion-laughs / XXE).
        if data.range(of: Data("<!ENTITY".utf8)) != nil { throw FeedError.forbiddenContent }
        let delegate = FeedXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw FeedError.invalidXML(parser.parserError?.localizedDescription ?? "parse failed")
        }
        return (delegate.feedTitle, delegate.items)
    }

    /// Parses sizes such as "1.2 GiB", "700 MB", "12345".
    static func parseSize(_ text: String) -> Int64? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var numberPart = ""
        var unitPart = ""
        for ch in s {
            if unitPart.isEmpty && (ch.isNumber || ch == "." || ch == ",") { numberPart.append(ch == "," ? "." : ch) }
            else if ch != " " { unitPart.append(ch) }
        }
        guard let n = Double(numberPart), n >= 0, n.isFinite else { return nil }
        let mult: Double
        switch unitPart.lowercased() {
        case "", "b", "byte", "bytes": mult = 1
        case "kib": mult = 1024
        case "mib": mult = 1024 * 1024
        case "gib": mult = 1024 * 1024 * 1024
        case "tib": mult = 1024 * 1024 * 1024 * 1024
        case "kb": mult = 1000
        case "mb": mult = 1_000_000
        case "gb": mult = 1_000_000_000
        case "tb": mult = 1_000_000_000_000
        default: return nil
        }
        let v = n * mult
        return v < 9.0e18 ? Int64(v) : nil
    }
}

private final class FeedXMLDelegate: NSObject, XMLParserDelegate {
    var feedTitle = ""
    var items: [FeedItem] = []

    private struct Builder {
        var guid: String?
        var title = ""
        var link: String?
        var enclosureURL: String?
        var enclosureType: String?
        var enclosureLength: Int64?
        var magnet: String?
        var infoHash: String?
        var published: Date?
        var updated: Date?
        var size: Int64?
    }

    private var stack: [String] = []
    private var text = ""
    private var cur: Builder?

    private lazy var rfc822: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"].map {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = $0
            return f
        }
    }()
    private lazy var iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private lazy var isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = iso.date(from: t) ?? isoFrac.date(from: t) { return d }
        for f in rfc822 { if let d = f.date(from: t) { return d } }
        return nil
    }

    private func isItem(_ n: String) -> Bool { n == "item" || n == "entry" }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String]) {
        let name = elementName.lowercased()
        stack.append(name)
        text = ""
        if isItem(name) { cur = Builder(); return }
        guard cur != nil else { return }
        switch name {
        case "enclosure":
            if let u = a["url"] { setEnclosure(u, type: a["type"], length: a["length"]) }
        case "media:content":
            if let u = a["url"], cur?.enclosureURL == nil { setEnclosure(u, type: a["type"], length: a["filesize"]) }
        case "link":
            guard let href = a["href"] else { break }
            let rel = (a["rel"] ?? "alternate").lowercased()
            let type = a["type"]?.lowercased() ?? ""
            if href.lowercased().hasPrefix("magnet:") {
                if cur?.magnet == nil { cur?.magnet = href }
            } else if rel == "enclosure" || (rel == "alternate" && type.contains("bittorrent")) {
                setEnclosure(href, type: a["type"], length: a["length"])
            } else if rel == "alternate", cur?.link == nil {
                cur?.link = href
            }
        default: break
        }
    }

    private func setEnclosure(_ url: String, type: String?, length: String?) {
        if url.lowercased().hasPrefix("magnet:") {
            if cur?.magnet == nil { cur?.magnet = url }
            return
        }
        guard cur?.enclosureURL == nil else { return }
        cur?.enclosureURL = url
        cur?.enclosureType = type
        if let length, let n = Int64(length), n > 0 { cur?.enclosureLength = n }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        defer { if !stack.isEmpty { stack.removeLast() }; text = "" }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.count >= 2 ? stack[stack.count - 2] : ""

        if isItem(name), let b = cur {
            cur = nil
            let title = b.title
            let guid = b.guid ?? b.enclosureURL ?? b.magnet ?? b.link ?? title
            var magnet = b.magnet
            if magnet == nil, let h = b.infoHash, !h.isEmpty { magnet = "magnet:?xt=urn:btih:\(h)" }
            var size = b.size
            if size == nil, let l = b.enclosureLength {
                let t = b.enclosureType?.lowercased() ?? ""
                let isTorrentFile = t.contains("bittorrent") || (b.enclosureURL?.lowercased().hasSuffix(".torrent") ?? false)
                if !isTorrentFile { size = l }
            }
            items.append(FeedItem(guid: guid, title: title, link: b.link, enclosureURL: b.enclosureURL, enclosureType: b.enclosureType,
                                  magnet: magnet, published: b.published ?? b.updated, size: size))
            return
        }

        guard cur != nil else {
            if name == "title", feedTitle.isEmpty, parent == "channel" || parent == "feed" { feedTitle = value }
            return
        }
        guard !value.isEmpty else { return }
        let directChild = isItem(parent)
        switch name {
        case "title" where directChild: cur?.title = value
        case "link" where directChild:
            if value.lowercased().hasPrefix("magnet:") { if cur?.magnet == nil { cur?.magnet = value } }
            else if cur?.link == nil { cur?.link = value }
        case "guid" where directChild, "id" where directChild: cur?.guid = value
        case "pubdate", "published", "dc:date": cur?.published = parseDate(value)
        case "updated": cur?.updated = parseDate(value)
        case "torrent:magneturi": cur?.magnet = value
        case "torrent:contentlength": if let n = Int64(value) { cur?.size = n }
        case "nyaa:size", "torrent:size": if let n = FeedParser.parseSize(value) { cur?.size = n }
        case "nyaa:infohash", "torrent:infohash": cur?.infoHash = value
        default: break
        }
    }
}
