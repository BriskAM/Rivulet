import Foundation
import Testing
@testable import RivuletCore

// MARK: Helpers

private func makeTempDir() throws -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("rivulet-engine-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base.resolvingSymlinksInPath()
}

private func write(_ url: URL, _ text: String = "x") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

private func item(_ name: String, in dir: URL, bytes: Int64 = 1000, torrent: Bool = false, host: String? = nil) -> CompletedItem {
    CompletedItem(name: name, paths: [dir.appendingPathComponent(name).path], directory: dir.path,
                  totalBytes: bytes, isTorrent: torrent, sourceHost: host)
}

@discardableResult
private func sh(_ exe: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

private let python3Available = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

private func makePython(_ script: String, args: [String]) -> Bool {
    sh("/usr/bin/python3", ["-I", "-c", script] + args) == 0
}

// MARK: Rules

@Suite struct RuleTests {
    @Test func conditions() {
        let dir = URL(fileURLWithPath: "/tmp/x")
        let it = item("Movie.2024.MKV", in: dir, bytes: 200 * 1_048_576, torrent: true, host: "tracker.Example.org")
        #expect(RuleEngine.matches(Rule(name: "a", conditions: [.extensionIn(["mkv", ".mp4"])], actions: []), it))
        #expect(!RuleEngine.matches(Rule(name: "a", conditions: [.extensionIn(["zip"])], actions: []), it))
        #expect(RuleEngine.matches(Rule(name: "a", conditions: [.nameMatches("movie\\.\\d{4}")], actions: []), it))
        #expect(!RuleEngine.matches(Rule(name: "a", conditions: [.nameMatches("([")], actions: []), it))
        #expect(RuleEngine.matches(Rule(name: "a", conditions: [.largerThanMB(100), .smallerThanMB(300)], actions: []), it))
        #expect(!RuleEngine.matches(Rule(name: "a", conditions: [.largerThanMB(100), .smallerThanMB(150)], actions: []), it))
        #expect(RuleEngine.matches(Rule(name: "a", conditions: [.isTorrent(true), .sourceHostContains("example")], actions: []), it))
        #expect(!RuleEngine.matches(Rule(name: "a", conditions: [.sourceHostContains("nope")], actions: []), it))
        #expect(RuleEngine.matches(Rule(name: "a", conditions: [.always], actions: []), it))
        #expect(!RuleEngine.matches(Rule(name: "a", conditions: [], actions: []), it))
    }

    @Test func moveAndCollisionRenaming() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let dest = root.appendingPathComponent("Sorted")
        try write(dest.appendingPathComponent("a.txt"), "existing")
        try write(dest.appendingPathComponent("a 2.txt"), "existing2")
        try write(root.appendingPathComponent("in/a.txt"), "new")

        let rule = Rule(name: "move", conditions: [.always], actions: [.moveTo(dest.path)])
        let (paths, results) = await RuleEngine().apply([rule], to: item("a.txt", in: root.appendingPathComponent("in")))
        #expect(results.allSatisfy { $0.success })
        #expect(paths == [dest.appendingPathComponent("a 3.txt").path])
        #expect(try String(contentsOf: dest.appendingPathComponent("a.txt"), encoding: .utf8) == "existing")
        #expect(try String(contentsOf: dest.appendingPathComponent("a 3.txt"), encoding: .utf8) == "new")
        #expect(!exists(root.appendingPathComponent("in/a.txt")))
    }

    @Test func moveRejectsTraversalAndRelative() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("f.txt"))
        let it = item("f.txt", in: root)
        for bad in [root.path + "/../escape", "relative/dir"] {
            let (paths, results) = await RuleEngine().apply([Rule(name: "m", conditions: [.always], actions: [.moveTo(bad)])], to: it)
            #expect(results.first?.success == false)
            #expect(paths == it.paths)
        }
        #expect(exists(root.appendingPathComponent("f.txt")))
        #expect(!exists(root.deletingLastPathComponent().appendingPathComponent("escape")))
    }

    @Test func renameTemplate() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("song.mp3"))
        try write(root.appendingPathComponent("[mine] song.mp3"))   // forces a collision
        let rule = Rule(name: "r", conditions: [.always], actions: [.rename("[{host}] {base}.{ext}")])
        let (paths, results) = await RuleEngine().apply([rule], to: item("song.mp3", in: root, host: "mine"))
        #expect(results.allSatisfy { $0.success })
        #expect(paths == [root.appendingPathComponent("[mine] song 2.mp3").path])
        #expect(exists(root.appendingPathComponent("[mine] song.mp3")))
    }

    @Test func renameTemplateCannotTraverse() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let inner = root.appendingPathComponent("inner")
        try write(inner.appendingPathComponent("f.txt"))
        let rule = Rule(name: "r", conditions: [.always], actions: [.rename("../../evil/{name}")])
        let (paths, results) = await RuleEngine().apply([rule], to: item("f.txt", in: inner))
        #expect(results.allSatisfy { $0.success })
        #expect(paths.count == 1)
        #expect((paths[0] as NSString).deletingLastPathComponent == inner.path)
        #expect(!(paths[0] as NSString).lastPathComponent.contains("/"))
        #expect(!exists(root.appendingPathComponent("evil")))

        let it = item("f.txt", in: inner)
        #expect(throws: (any Error).self) { try RuleEngine.expandTemplate("..", path: it.paths[0], item: it) }
        #expect(throws: (any Error).self) { try RuleEngine.expandTemplate("//", path: it.paths[0], item: it) }
        #expect(throws: (any Error).self) { try RuleEngine.expandTemplate("   ", path: it.paths[0], item: it) }
    }

    @Test func actionsChainAndStopProcessing() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("a.txt"))
        let dest = root.appendingPathComponent("out")
        let r1 = Rule(name: "one", conditions: [.always], actions: [.rename("b.txt"), .moveTo(dest.path)], stopProcessing: true)
        let r2 = Rule(name: "two", conditions: [.always], actions: [.rename("c.txt")])
        let disabled = Rule(name: "off", enabled: false, conditions: [.always], actions: [.rename("d.txt")])
        let (paths, results) = await RuleEngine().apply([disabled, r1, r2], to: item("a.txt", in: root))
        #expect(paths == [dest.appendingPathComponent("b.txt").path])
        #expect(results.map(\.ruleName) == ["one", "one"])
    }

    @Test func failedActionStopsRemainingActionsOfThatRule() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("a.txt"))
        var trashed: [URL] = []
        let engine = RuleEngine(trash: { trashed.append($0) })
        let rule = Rule(name: "x", conditions: [.always], actions: [.moveTo("relative"), .moveToTrash])
        let (_, results) = await engine.apply([rule], to: item("a.txt", in: root))
        #expect(results.count == 1)
        #expect(trashed.isEmpty)
    }

    @Test func moveToTrashUsesInjectedClosure() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("a.txt"))
        var trashed: [URL] = []
        let engine = RuleEngine(trash: { trashed.append($0) })
        let (paths, results) = await engine.apply([Rule(name: "t", conditions: [.always], actions: [.moveToTrash])], to: item("a.txt", in: root))
        #expect(results.allSatisfy { $0.success })
        #expect(trashed.map(\.path) == [root.appendingPathComponent("a.txt").path])
        #expect(paths.isEmpty)
        #expect(exists(root.appendingPathComponent("a.txt")))   // the closure, not the engine, removes it
    }

    @Test func extractZipIntoSubfolderAndTrashArchive() async throws {
        try #require(python3Available)
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("pack.zip")
        #expect(makePython("import sys,zipfile\nz=zipfile.ZipFile(sys.argv[1],'w')\nz.writestr('dir/hello.txt','hi')\nz.writestr('top.txt','t')\nz.close()", args: [zip.path]))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pack"), withIntermediateDirectories: true) // collision
        var trashed: [URL] = []
        let engine = RuleEngine(trash: { trashed.append($0) })
        let rule = Rule(name: "unzip", conditions: [.always], actions: [.extractArchive(deleteArchive: true, intoSubfolder: true)])
        let (paths, results) = await engine.apply([rule], to: item("pack.zip", in: root))
        #expect(results.allSatisfy { $0.success })
        #expect(paths == [root.appendingPathComponent("pack 2").path])
        #expect(try String(contentsOf: root.appendingPathComponent("pack 2/dir/hello.txt"), encoding: .utf8) == "hi")
        #expect(trashed.map(\.path) == [zip.path])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".rivulet-extract") }
        #expect(leftovers.isEmpty)
    }

    @Test func extractTarGzFlatKeepsArchive() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("src/one.txt"), "1")
        try write(root.appendingPathComponent("src/two.txt"), "2")
        try write(root.appendingPathComponent("work/one.txt"), "already here")
        let tgz = root.appendingPathComponent("work/bundle.tar.gz")
        #expect(sh("/usr/bin/bsdtar", ["-czf", tgz.path, "-C", root.appendingPathComponent("src").path, "one.txt", "two.txt"]) == 0)
        var trashed: [URL] = []
        let engine = RuleEngine(trash: { trashed.append($0) })
        let rule = Rule(name: "x", conditions: [.always], actions: [.extractArchive(deleteArchive: false, intoSubfolder: false)])
        let (paths, results) = await engine.apply([rule], to: item("bundle.tar.gz", in: root.appendingPathComponent("work")))
        #expect(results.allSatisfy { $0.success })
        #expect(Set(paths.map { ($0 as NSString).lastPathComponent }) == ["one 2.txt", "two.txt"])
        #expect(try String(contentsOf: root.appendingPathComponent("work/one.txt"), encoding: .utf8) == "already here")
        #expect(trashed.isEmpty)
        #expect(exists(tgz))
    }

    @Test func zipSlipIsRejected() async throws {
        try #require(python3Available)
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("evil.zip")
        #expect(makePython("import sys,zipfile\nz=zipfile.ZipFile(sys.argv[1],'w')\nz.writestr('ok.txt','ok')\nz.writestr('../escaped.txt','bad')\nz.close()", args: [zip.path]))
        var trashed: [URL] = []
        let engine = RuleEngine(trash: { trashed.append($0) })
        let rule = Rule(name: "unzip", conditions: [.always], actions: [.extractArchive(deleteArchive: true, intoSubfolder: false)])
        let (paths, results) = await engine.apply([rule], to: item("evil.zip", in: work))
        #expect(results.first?.success == false)
        #expect(trashed.isEmpty)                       // archive is never deleted after a failure
        #expect(paths == [zip.path])
        #expect(!exists(root.appendingPathComponent("escaped.txt")))
        #expect(!exists(work.appendingPathComponent("escaped.txt")))
        #expect(!exists(work.appendingPathComponent("ok.txt")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path) == ["evil.zip"])
    }

    @Test func tarWithAbsoluteAndDotDotEntriesIsRejected() async throws {
        try #require(python3Available)
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let tar = work.appendingPathComponent("evil.tar")
        #expect(makePython("import sys,tarfile,io\nt=tarfile.open(sys.argv[1],'w')\ni=tarfile.TarInfo('../../tarescape.txt')\nd=b'bad'\ni.size=len(d)\nt.addfile(i,io.BytesIO(d))\nt.close()", args: [tar.path]))
        let (_, results) = await RuleEngine().apply([Rule(name: "x", conditions: [.always], actions: [.extractArchive(deleteArchive: false, intoSubfolder: true)])],
                                                     to: item("evil.tar", in: work))
        #expect(results.first?.success == false)
        #expect(!exists(root.deletingLastPathComponent().appendingPathComponent("tarescape.txt")))
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path) == ["evil.tar"])
    }

    @Test func symlinkEscapeIsRejected() async throws {
        try #require(python3Available)
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let tar = work.appendingPathComponent("link.tar")
        #expect(makePython("import sys,tarfile\nt=tarfile.open(sys.argv[1],'w')\ni=tarfile.TarInfo('innocent')\ni.type=tarfile.SYMTYPE\ni.linkname='/etc'\nt.addfile(i)\nt.close()", args: [tar.path]))
        let (_, results) = await RuleEngine().apply([Rule(name: "x", conditions: [.always], actions: [.extractArchive(deleteArchive: false, intoSubfolder: true)])],
                                                     to: item("link.tar", in: work))
        #expect(results.first?.success == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path) == ["link.tar"])
    }

    @Test func verifyContainedAcceptsInternalSymlink() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("real.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("ok").path, withDestinationPath: "real.txt")
        try RuleEngine.verifyContained(root)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("bad").path, withDestinationPath: "../outside")
        #expect(throws: (any Error).self) { try RuleEngine.verifyContained(root) }
    }

    @Test func storeRoundTripAndDefaults() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuleStore(fileURL: root.appendingPathComponent("sub/rules.json"))
        #expect(store.load().isEmpty)
        let rules = RuleDefaults.examples
        #expect(!rules.isEmpty)
        #expect(rules.allSatisfy { !$0.enabled })
        try store.save(rules)
        #expect(store.load() == rules)
        try "not json".write(to: root.appendingPathComponent("sub/rules.json"), atomically: true, encoding: .utf8)
        #expect(store.load().isEmpty)
    }
}

// MARK: Accounts

private let keychainAvailable: Bool = {
    let kc = KeychainStore(service: "app.rivulet.mac.probe.\(UUID().uuidString)")
    do {
        try kc.set("probe", account: "probe")
        let ok = kc.get(account: "probe") == "probe"
        try kc.delete(account: "probe")
        return ok
    } catch { return false }
}()

@Suite struct AccountTests {
    @Test(.enabled(if: keychainAvailable)) func keychainRoundTrip() throws {
        let kc = KeychainStore(service: "app.rivulet.mac.test.\(UUID().uuidString)")
        defer { try? kc.delete(account: "a") }
        #expect(kc.get(account: "a") == nil)
        try kc.set("one", account: "a")
        try kc.set("two", account: "a")
        #expect(kc.get(account: "a") == "two")
        try kc.delete(account: "a")
        #expect(kc.get(account: "a") == nil)
        try kc.delete(account: "a")   // deleting a missing item is not an error
    }

    @Test(.enabled(if: keychainAvailable)) func accountStoreKeepsPasswordsOutOfJSON() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = "app.rivulet.mac.test.\(UUID().uuidString)"
        let meta = root.appendingPathComponent("accounts.json")
        let store = AccountStore(service: service, metadataURL: meta)
        let parent = AccountRecord(host: "Example.com", username: "alice", note: "main")
        let child = AccountRecord(host: "cdn.example.com", username: "bob")
        try store.add(parent, password: "s3cret-parent")
        try store.add(child, password: "s3cret-child")
        defer { try? store.remove(parent.id); try? store.remove(child.id) }

        let json = try String(contentsOf: meta, encoding: .utf8)
        #expect(!json.contains("s3cret"))
        #expect(store.list().count == 2)
        #expect(store.password(for: parent.id) == "s3cret-parent")

        #expect(store.credentials(forHost: "example.com")?.username == "alice")
        #expect(store.credentials(forHost: "dl.example.com")?.password == "s3cret-parent")
        #expect(store.credentials(forHost: "cdn.example.com")?.username == "bob")       // most specific wins
        #expect(store.credentials(forHost: "notexample.com") == nil)
        #expect(store.credentials(forHost: "example.org") == nil)

        try store.remove(child.id)
        #expect(store.password(for: child.id) == nil)
        #expect(store.credentials(forHost: "cdn.example.com")?.username == "alice")
        #expect(store.list().map(\.id) == [parent.id])
    }
}

// MARK: Feeds

private let rssSample = """
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:torrent="http://xmlns.ezrss.it/0.1/" xmlns:nyaa="https://nyaa.si/xmlns/nyaa">
<channel>
  <title>Test Tracker</title>
  <link>https://tracker.example/</link>
  <item>
    <title>Show S01E02 1080p</title>
    <link>https://tracker.example/view/2</link>
    <guid isPermaLink="false">guid-2</guid>
    <pubDate>Sat, 08 Nov 2025 10:30:00 +0000</pubDate>
    <enclosure url="https://tracker.example/dl/2.torrent" length="12345" type="application/x-bittorrent"/>
    <torrent:magnetURI><![CDATA[magnet:?xt=urn:btih:AAAA&dn=Show]]></torrent:magnetURI>
    <torrent:contentLength>1073741824</torrent:contentLength>
  </item>
  <item>
    <title>Show S01E01 480p &amp; extras</title>
    <link>magnet:?xt=urn:btih:BBBB</link>
    <guid>guid-1</guid>
    <nyaa:size>700.5 MiB</nyaa:size>
    <nyaa:infoHash>bbbb</nyaa:infoHash>
  </item>
  <item>
    <title>Plain file</title>
    <enclosure url="https://files.example/a.iso" length="2048" type="application/octet-stream"/>
  </item>
</channel>
</rss>
"""

private let atomSample = """
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Atom Releases</title>
  <entry>
    <title>Release 1.0</title>
    <id>tag:example.com,2025:1.0</id>
    <updated>2025-11-08T12:00:00Z</updated>
    <link rel="alternate" href="https://example.com/r/1.0"/>
    <link rel="enclosure" type="application/x-bittorrent" href="https://example.com/r/1.0.torrent" length="999"/>
    <link href="magnet:?xt=urn:btih:CCCC"/>
  </entry>
  <entry>
    <title>Release 0.9</title>
    <id>tag:example.com,2025:0.9</id>
    <published>2025-10-01T08:00:00.500Z</published>
    <link rel="alternate" href="https://example.com/r/0.9"/>
  </entry>
</feed>
"""

@Suite struct FeedTests {
    @Test func parsesRSSWithTorrentExtensions() throws {
        let (title, items) = try FeedParser.parse(Data(rssSample.utf8))
        #expect(title == "Test Tracker")
        #expect(items.count == 3)
        let a = items[0]
        #expect(a.guid == "guid-2")
        #expect(a.title == "Show S01E02 1080p")
        #expect(a.link == "https://tracker.example/view/2")
        #expect(a.enclosureURL == "https://tracker.example/dl/2.torrent")
        #expect(a.enclosureType == "application/x-bittorrent")
        #expect(a.magnet == "magnet:?xt=urn:btih:AAAA&dn=Show")
        #expect(a.size == 1_073_741_824)   // content length, not the .torrent size
        #expect(a.published == Date(timeIntervalSince1970: 1_762_597_800))
        let b = items[1]
        #expect(b.title == "Show S01E01 480p & extras")
        #expect(b.magnet == "magnet:?xt=urn:btih:BBBB")
        #expect(b.link == nil)
        #expect(b.size == Int64(700.5 * 1_048_576))
        let c = items[2]
        #expect(c.guid == "https://files.example/a.iso")   // fallback guid
        #expect(c.size == 2048)
    }

    @Test func parsesAtom() throws {
        let (title, items) = try FeedParser.parse(Data(atomSample.utf8))
        #expect(title == "Atom Releases")
        #expect(items.count == 2)
        #expect(items[0].guid == "tag:example.com,2025:1.0")
        #expect(items[0].link == "https://example.com/r/1.0")
        #expect(items[0].enclosureURL == "https://example.com/r/1.0.torrent")
        #expect(items[0].enclosureType == "application/x-bittorrent")
        #expect(items[0].magnet == "magnet:?xt=urn:btih:CCCC")
        #expect(items[0].size == nil)
        #expect(items[0].published == Date(timeIntervalSince1970: 1_762_603_200))
        #expect(items[1].published != nil)
        #expect(items[1].enclosureURL == nil)
    }

    @Test func rejectsMalformedAndEntityDeclarations() {
        #expect(throws: (any Error).self) { try FeedParser.parse(Data("<rss><channel><item></rss>".utf8)) }
        let xxe = "<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><rss><channel><title>&x;</title></channel></rss>"
        #expect(throws: (any Error).self) { try FeedParser.parse(Data(xxe.utf8)) }
    }

    @Test func parseSizes() {
        #expect(FeedParser.parseSize("1.5 GiB") == 1_610_612_736)
        #expect(FeedParser.parseSize("500 MB") == 500_000_000)
        #expect(FeedParser.parseSize("42") == 42)
        #expect(FeedParser.parseSize("abc") == nil)
    }

    @Test func filterMatching() {
        let mb: Int64 = 1_048_576
        func it(_ title: String, _ size: Int64?) -> FeedItem { FeedItem(guid: title, title: title, size: size) }
        let f = FeedFilter(includeRegex: "1080p|2160p", excludeRegex: "cam|ts", minMB: 100, maxMB: 2000)
        #expect(f.matches(it("Show 1080p WEB", 500 * mb)))
        #expect(!f.matches(it("Show 720p", 500 * mb)))
        #expect(!f.matches(it("Show 1080p CAM", 500 * mb)))
        #expect(!f.matches(it("Show 1080p", 50 * mb)))
        #expect(!f.matches(it("Show 1080p", 5000 * mb)))
        #expect(f.matches(it("Show 1080p", nil)))
        #expect(FeedFilter().matches(it("anything", 1)))
        #expect(!FeedFilter(includeRegex: "([").matches(it("x", nil)))   // invalid regex fails closed
    }

    private func monitor(_ root: URL, _ box: DataBox) -> FeedMonitor {
        FeedMonitor(stateURL: root.appendingPathComponent("state.json"), fetch: { _ in box.data })
    }

    @Test func firstPollMarksSeenThenOnlyNewItems() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = DataBox(Data(rssSample.utf8))
        var sub = FeedSubscription(name: "t", url: "https://feed.example/rss")
        sub.filter = FeedFilter(includeRegex: "1080p")
        let m = monitor(root, box)

        let r1 = try await m.poll(sub)
        #expect(r1.isEmpty)           // first poll: everything marked seen, nothing returned
        let r2 = try await m.poll(sub)
        #expect(r2.isEmpty)           // nothing new

        let extra = rssSample.replacingOccurrences(of: "<item>\n    <title>Show S01E02",
            with: "<item><title>Show S01E03 1080p</title><guid>guid-3</guid></item><item>\n    <title>Show S01E02")
            .replacingOccurrences(of: "<channel>", with: "<channel><item><title>Show S01E04 720p</title><guid>guid-4</guid></item>")
        box.data = Data(extra.utf8)
        let fresh = try await m.poll(sub)
        #expect(fresh.map(\.guid) == ["guid-3"])          // 720p is new but filtered out
        let r3 = try await m.poll(sub)
        #expect(r3.isEmpty)           // and still not re-emitted

        // State persists across instances.
        let m2 = monitor(root, box)
        let r4 = try await m2.poll(sub)
        #expect(r4.isEmpty)
    }

    @Test func emitInitialReturnsFilteredItemsOnce() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let box = DataBox(Data(rssSample.utf8))
        var sub = FeedSubscription(name: "t", url: "http://feed.example/rss")
        sub.filter = FeedFilter(includeRegex: "S01E0")
        let m = monitor(root, box)
        let r5 = try await m.poll(sub, emitInitial: true)
        #expect(r5.map(\.guid) == ["guid-2", "guid-1"])
        let r6 = try await m.poll(sub, emitInitial: true)
        #expect(r6.isEmpty)
    }

    @Test func rejectsNonHTTPURLsAndOversizedResponses() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let m = monitor(root, DataBox(Data(rssSample.utf8)))
        for bad in ["file:///etc/passwd", "ftp://x.example/rss", "javascript:alert(1)", "not a url", "https://"] {
            await #expect(throws: (any Error).self) { try await m.poll(FeedSubscription(name: "t", url: bad)) }
        }
        let big = FeedMonitor(stateURL: root.appendingPathComponent("s2.json"), fetch: { _ in Data(count: FeedMonitor.maxResponseBytes + 1) })
        await #expect(throws: (any Error).self) { try await big.poll(FeedSubscription(name: "t", url: "https://a.example/rss")) }
    }

    @Test func seenListIsCapped() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        var xml = "<rss><channel><title>big</title>"
        for i in 0..<(FeedMonitor.maxSeenPerFeed + 50) { xml += "<item><title>t\(i)</title><guid>g\(i)</guid></item>" }
        xml += "</channel></rss>"
        let sub = FeedSubscription(name: "t", url: "https://a.example/rss")
        let payload = Data(xml.utf8)
        let m = FeedMonitor(stateURL: root.appendingPathComponent("s.json"), fetch: { _ in payload })
        _ = try await m.poll(sub)
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("s.json"))) as? [String: Any]
        let seen = (state?["seen"] as? [String: [String]])?[sub.id.uuidString]
        #expect(seen?.count == FeedMonitor.maxSeenPerFeed)
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data: Data
    init(_ d: Data) { _data = d }
    var data: Data {
        get { lock.lock(); defer { lock.unlock() }; return _data }
        set { lock.lock(); defer { lock.unlock() }; _data = newValue }
    }
}

// MARK: Schedule

@Suite struct ScheduleTests {
    private func cal(_ tz: String = "UTC") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // 2025-11-03 is a Monday (weekday 2); 2025-11-09 a Sunday (1).
    @Test func daytimeWindowIsHalfOpen() {
        let c = cal()
        let e = ScheduleEntry(days: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 17 * 60, action: .limits(downKBps: 500, upKBps: 50))
        let s = SpeedSchedule(entries: [e])
        #expect(s.active(at: date(c, 2025, 11, 3, 8, 59), calendar: c) == nil)
        #expect(s.active(at: date(c, 2025, 11, 3, 9, 0), calendar: c)?.id == e.id)
        #expect(s.active(at: date(c, 2025, 11, 3, 16, 59), calendar: c)?.id == e.id)
        #expect(s.active(at: date(c, 2025, 11, 3, 17, 0), calendar: c) == nil)
        #expect(s.active(at: date(c, 2025, 11, 9, 12, 0), calendar: c) == nil)   // Sunday not included
    }

    @Test func overnightWindowAttributesAfterMidnightToStartDay() {
        let c = cal()
        // Friday (6) 22:00 -> 06:00
        let e = ScheduleEntry(days: [6], startMinute: 22 * 60, endMinute: 6 * 60, action: .alternateLimits)
        let s = SpeedSchedule(entries: [e])
        #expect(s.active(at: date(c, 2025, 11, 7, 21, 59), calendar: c) == nil)    // Fri before start
        #expect(s.active(at: date(c, 2025, 11, 7, 22, 0), calendar: c) != nil)     // Fri 22:00
        #expect(s.active(at: date(c, 2025, 11, 7, 23, 59), calendar: c) != nil)
        #expect(s.active(at: date(c, 2025, 11, 8, 0, 0), calendar: c) != nil)      // Sat 00:00 belongs to Friday
        #expect(s.active(at: date(c, 2025, 11, 8, 5, 59), calendar: c) != nil)
        #expect(s.active(at: date(c, 2025, 11, 8, 6, 0), calendar: c) == nil)
        #expect(s.active(at: date(c, 2025, 11, 8, 23, 0), calendar: c) == nil)     // Saturday night is not included
        #expect(s.active(at: date(c, 2025, 11, 7, 3, 0), calendar: c) == nil)      // Fri 03:00 belongs to Thursday
    }

    @Test func sundayWrapsFromSaturday() {
        let c = cal()
        let e = ScheduleEntry(days: [7], startMinute: 23 * 60, endMinute: 2 * 60, action: .pauseAll)   // Saturday night
        let s = SpeedSchedule(entries: [e])
        #expect(s.active(at: date(c, 2025, 11, 9, 1, 0), calendar: c) != nil)      // Sunday 01:00
        #expect(s.active(at: date(c, 2025, 11, 9, 2, 0), calendar: c) == nil)
    }

    @Test func firstEnabledEntryWinsAndDisabledIgnored() {
        let c = cal()
        let off = ScheduleEntry(days: Set(1...7), startMinute: 0, endMinute: 24 * 60, action: .pauseAll, enabled: false)
        let a = ScheduleEntry(days: Set(1...7), startMinute: 0, endMinute: 24 * 60, action: .alternateLimits)
        let b = ScheduleEntry(days: Set(1...7), startMinute: 0, endMinute: 24 * 60, action: .pauseAll)
        let s = SpeedSchedule(entries: [off, a, b])
        #expect(s.active(at: date(c, 2025, 11, 3, 12, 0), calendar: c)?.id == a.id)
        #expect(SpeedSchedule().active(at: Date(), calendar: c) == nil)
    }

    @Test func usesTheCalendarTimeZone() {
        let tokyo = cal("Asia/Tokyo")
        let ny = cal("America/New_York")
        let instant = date(tokyo, 2025, 11, 3, 23, 30)           // Monday 23:30 in Tokyo, Monday 09:30 in New York
        let e = ScheduleEntry(days: [2], startMinute: 23 * 60, endMinute: 24 * 60, action: .pauseAll)
        let s = SpeedSchedule(entries: [e])
        #expect(s.active(at: instant, calendar: tokyo) != nil)
        #expect(s.active(at: instant, calendar: ny) == nil)
    }

    @Test func codableRoundTrip() throws {
        let s = SpeedSchedule(entries: [
            ScheduleEntry(days: [1, 7], startMinute: 60, endMinute: 120, action: .limits(downKBps: 1, upKBps: 2)),
            ScheduleEntry(days: [3], startMinute: 0, endMinute: 10, action: .pauseAll),
        ])
        let back = try JSONDecoder().decode(SpeedSchedule.self, from: JSONEncoder().encode(s))
        #expect(back.entries == s.entries)
    }
}
