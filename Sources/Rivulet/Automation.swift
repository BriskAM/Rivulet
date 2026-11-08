import AppKit
import Foundation
import Observation
import RivuletCore

/// Owns the engines behind the plugin, rules, feeds, accounts and schedule features, and their saved settings.
@MainActor
@Observable
final class Automation {
    static let shared = Automation()

    let accountStore: AccountStore
    let resolver: ResolverEngine
    let ruleStore: RuleStore
    let ruleEngine = RuleEngine()
    let feedMonitor: FeedMonitor

    var rules: [Rule] = []
    var feeds: [FeedSubscription] = []
    var feedStatus: [UUID: String] = [:]
    var schedule: [ScheduleEntry] = []
    var accounts: [AccountRecord] = []
    var plugins: [PluginInfo] = []
    var pluginErrors: [String] = []
    var ruleLog: [String] = []
    var accountError: String?

    let grabber = LinkGrabber()

    private let feedsURL: URL
    private let scheduleURL: URL
    private var lastPolled: [UUID: Date] = [:]
    private var activeScheduleID: UUID?
    private var scheduleSavedAlt = false
    private var schedulePaused = false
    private var clipboardCount = NSPasteboard.general.changeCount

    static var userPluginDirectory: URL {
        let dir = DaemonManager.supportDirectory.appendingPathComponent("Plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        let support = DaemonManager.supportDirectory
        let accountStore = AccountStore(metadataURL: support.appendingPathComponent("accounts.json"))
        self.accountStore = accountStore
        var dirs = [Self.userPluginDirectory]
        var bundled: [URL] = []
        if let res = Bundle.main.resourceURL?.appendingPathComponent("Plugins", isDirectory: true),
           FileManager.default.fileExists(atPath: res.path) {
            dirs.append(res)
            bundled.append(res)
        }
        self.resolver = ResolverEngine(
            pluginDirectories: dirs,
            bundledDirectories: bundled,
            accounts: { host in accountStore.credentials(forHost: host) }
        )
        self.ruleStore = RuleStore(fileURL: support.appendingPathComponent("rules.json"))
        self.feedMonitor = FeedMonitor(stateURL: support.appendingPathComponent("feeds-state.json"))
        self.feedsURL = support.appendingPathComponent("feeds.json")
        self.scheduleURL = support.appendingPathComponent("schedule.json")

        rules = ruleStore.load()
        feeds = Self.load([FeedSubscription].self, from: feedsURL) ?? []
        schedule = Self.load([ScheduleEntry].self, from: scheduleURL) ?? []
        accounts = accountStore.list()
        reloadPlugins()
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Plugins

    func reloadPlugins() {
        resolver.reload()
        plugins = resolver.plugins
        pluginErrors = resolver.loadErrors
    }

    func updatePlugins(from indexString: String) async -> String {
        guard let url = URL(string: indexString.trimmingCharacters(in: .whitespaces)),
              ["https", "file"].contains(url.scheme) else {
            return "Enter an https address for the plugin index."
        }
        do {
            let updated = try await PluginRepository(installDirectory: Self.userPluginDirectory).update(from: url)
            reloadPlugins()
            return updated.isEmpty ? "All plugins are up to date." : "Updated: \(updated.joined(separator: ", "))"
        } catch {
            return "Update failed: \(error.localizedDescription)"
        }
    }

    // MARK: Accounts

    func addAccount(host: String, username: String, password: String, note: String) {
        accountError = nil
        let record = AccountRecord(host: host.trimmingCharacters(in: .whitespaces).lowercased(),
                                   username: username, note: note)
        do {
            try accountStore.add(record, password: password)
            accounts = accountStore.list()
        } catch {
            accountError = "Could not save to the Keychain: \(error.localizedDescription)"
        }
    }

    func removeAccount(_ id: UUID) {
        try? accountStore.remove(id)
        accounts = accountStore.list()
    }

    // MARK: Rules

    func saveRules() { try? ruleStore.save(rules) }

    func runRules(for d: Download) {
        let active = rules.filter(\.enabled)
        guard !active.isEmpty else { return }
        var paths = d.files.map(\.path).filter { !$0.isEmpty }
        if d.isTorrent, d.files.count > 1 { paths = [(d.dir as NSString).appendingPathComponent(d.name)] }
        let item = CompletedItem(
            name: d.displayName, paths: paths, directory: d.dir, totalBytes: d.totalLength,
            isTorrent: d.isTorrent, sourceHost: d.primaryURI.flatMap { URL(string: $0)?.host }
        )
        Task {
            let (_, results) = await ruleEngine.apply(active, to: item)
            for r in results {
                ruleLog.append("\(r.success ? "ok" : "failed"): \(r.ruleName) - \(r.action) - \(r.detail)")
            }
            if ruleLog.count > 60 { ruleLog.removeFirst(ruleLog.count - 60) }
            let failed = results.filter { !$0.success }
            if let first = failed.first {
                AppState.shared.alertMessage = "A rule failed on \"\(d.displayName)\": \(first.ruleName), \(first.action): \(first.detail)"
            }
        }
    }

    // MARK: Feeds

    func saveFeeds() { Self.save(feeds, to: feedsURL) }

    func pollFeeds(_ state: AppState) async {
        for sub in feeds where sub.enabled {
            let due = lastPolled[sub.id].map { Date().timeIntervalSince($0) >= Double(max(5, sub.intervalMinutes)) * 60 } ?? true
            guard due else { continue }
            lastPolled[sub.id] = Date()
            await poll(sub, state)
        }
    }

    func pollNow(_ sub: FeedSubscription, _ state: AppState) {
        lastPolled[sub.id] = Date()
        Task { await poll(sub, state) }
    }

    private func poll(_ sub: FeedSubscription, _ state: AppState) async {
        do {
            let items = try await feedMonitor.poll(sub)
            var options: [String: String] = [:]
            if let dir = sub.downloadDirectory, !dir.isEmpty { options["dir"] = (dir as NSString).expandingTildeInPath }
            var queued = 0
            for item in items {
                guard let uri = item.magnet ?? item.enclosureURL ?? item.link else { continue }
                state.addURIs(uri, options: options)
                queued += 1
            }
            feedStatus[sub.id] = "\(Date().formatted(date: .omitted, time: .shortened)): \(queued) new"
        } catch {
            feedStatus[sub.id] = "Error: \(error.localizedDescription)"
        }
    }

    // MARK: Schedule

    func saveSchedule() {
        Self.save(schedule, to: scheduleURL)
        activeScheduleID = nil
    }

    func evaluateSchedule(_ state: AppState) async {
        let current = SpeedSchedule(entries: schedule.filter(\.enabled)).active(at: Date())
        guard current?.id != activeScheduleID else { return }

        // Leaving a window: put back what the user had.
        if activeScheduleID != nil {
            UserDefaults.standard.set(scheduleSavedAlt, forKey: PrefKey.altSpeedEnabled)
            if schedulePaused { state.resumeAll(); schedulePaused = false }
            await state.applyGlobalSettings()
        }
        activeScheduleID = current?.id
        guard let entry = current else { return }

        scheduleSavedAlt = UserDefaults.standard.bool(forKey: PrefKey.altSpeedEnabled)
        switch entry.action {
        case .alternateLimits:
            UserDefaults.standard.set(true, forKey: PrefKey.altSpeedEnabled)
            await state.applyGlobalSettings()
        case .limits(let down, let up):
            try? await state.client?.changeGlobalOptions([
                "max-overall-download-limit": "\(max(0, down) * 1024)",
                "max-overall-upload-limit": "\(max(0, up) * 1024)",
            ])
        case .pauseAll:
            state.pauseAll()
            schedulePaused = true
        }
    }

    // MARK: Clipboard

    /// When enabled, links copied from a supported site are sent to the Link Grabber.
    func watchClipboard(_ state: AppState) {
        guard UserDefaults.standard.bool(forKey: PrefKey.watchClipboard) else {
            clipboardCount = NSPasteboard.general.changeCount
            return
        }
        let board = NSPasteboard.general
        guard board.changeCount != clipboardCount else { return }
        clipboardCount = board.changeCount
        guard let text = board.string(forType: .string), text.count < 20_000 else { return }
        let urls = ResolverEngine.extractURLs(from: text)
        let interesting = urls.contains { url in
            url.scheme == "magnet" || resolver.plugin(matching: url) != nil
        }
        guard interesting else { return }
        grabber.input = text
        state.openGrabberWindow?()
        grabber.startResolve()
    }
}
