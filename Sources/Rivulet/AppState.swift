import AppKit
import Observation
import RivuletCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum ConnectionState: Equatable {
    case connecting
    case connected(String)
    case failed(String)

    var isConnected: Bool { if case .connected = self { return true } else { return false } }
}

enum DownloadFilter: String, CaseIterable, Identifiable {
    case all, active, downloading, seeding, paused, error
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .downloading: return "Downloading"
        case .seeding: return "Seeding"
        case .paused: return "Paused"
        case .error: return "Error"
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case queue, name, progress, size, speed, state
    var id: String { rawValue }
    var title: String {
        switch self {
        case .queue: return "Queue Order"
        case .name: return "Name"
        case .progress: return "Progress"
        case .size: return "Size"
        case .speed: return "Transfer Rate"
        case .state: return "State"
        }
    }
}

extension Download {
    var displayName: String {
        if name.hasPrefix("[METADATA]") { return "Retrieving metadata" }
        return name
    }

    var isStopped: Bool { status == .complete || status == .error || status == .removed }
    var isDone: Bool { status == .complete || isSeeding || (totalLength > 0 && completedLength >= totalLength) }
    var isDownloading: Bool { status == .active && !isSeeding }
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var downloads: [Download] = []
    var stat = GlobalStat()
    /// Recent transfer speeds in bytes per second, one sample per snapshot, newest last.
    var downHistory: [Int64] = Array(repeating: 0, count: SpeedGraph.samples)
    var upHistory: [Int64] = Array(repeating: 0, count: SpeedGraph.samples)
    var connection: ConnectionState = .connecting
    var selection = Set<String>()
    var filter: DownloadFilter = .all
    var searchText = ""
    var sortOrder: SortOrder = SortOrder(rawValue: UserDefaults.standard.string(forKey: PrefKey.sortOrder) ?? "") ?? .queue {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: PrefKey.sortOrder) }
    }
    var reverseSort = false
    var altSpeedOn = UserDefaults.standard.bool(forKey: PrefKey.altSpeedEnabled)
    var alertMessage: String?

    /// Set by a live view so the Dock icon and menu bar can bring the main window back after it is closed.
    var openMainWindow: (() -> Void)?

    // Sheets and importers
    var showAddURL = false
    var showTorrentImporter = false
    var pendingRemoval: [Download] = []
    var showRemoveConfirm = false

    // Torrent file picker: the gid of a paused torrent the user is choosing files for.
    var pickerGID: String?
    var awaitingMetadata: Set<String> = []

    var client: Aria2Client?
    private var loop: Task<Void, Never>?
    private var lastLaunchAttempt = Date.distantPast
    private var wasDone: [String: Bool] = [:]
    private var previousStatus: [String: DownloadStatus] = [:]
    private var tickCount = 0
    var openGrabberWindow: (() -> Void)?
    private var settingsApplied = false

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        requestNotificationPermission()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .milliseconds(1000))
            }
        }
    }

    func reconnect() {
        Task {
            await client?.close()
            client = nil
            settingsApplied = false
            connection = .connecting
            await tick()
        }
    }

    func shutdown() {
        loop?.cancel()
        loop = nil
        if Prefs.isManaged { DaemonManager.shared.stop() }
    }

    private func tick() async {
        if let client, await client.isConnected {
            do {
                let result = try await client.snapshot()
                apply(result.downloads, stat: result.stat)
                tickCount += 1
                Automation.shared.watchClipboard(self)
                if tickCount % 30 == 1 {
                    Task {
                        await Automation.shared.evaluateSchedule(self)
                        await Automation.shared.pollFeeds(self)
                    }
                }
            } catch {
                await client.close()
                self.client = nil
                connection = .failed(error.localizedDescription)
            }
            return
        }
        await connectIfPossible()
    }

    private func connectIfPossible() async {
        let endpoint = Prefs.endpoint
        let candidate = Aria2Client(endpoint: endpoint)
        do {
            let version = try await candidate.connect()
            await candidate.setHandlers(onEvent: nil, onDisconnect: nil)
            client = candidate
            connection = .connected(version)
            if !settingsApplied {
                settingsApplied = true
                await applyGlobalSettings()
            }
        } catch let error as Aria2Error where error.isUnauthorized {
            connection = .failed("The RPC secret was rejected. Check the secret in Preferences, or stop the aria2 process already using port \(endpoint.port).")
        } catch {
            if Prefs.isManaged {
                launchDaemonIfNeeded(endpoint: endpoint)
            } else {
                connection = .failed("Cannot reach aria2 at \(endpoint.host):\(endpoint.port). Make sure it is running with RPC enabled.")
            }
        }
    }

    private func launchDaemonIfNeeded(endpoint: Aria2Endpoint) {
        guard Date().timeIntervalSince(lastLaunchAttempt) > 4 else { return }
        lastLaunchAttempt = Date()
        let custom = UserDefaults.standard.string(forKey: PrefKey.aria2Path)
        guard let binary = DaemonManager.locateBinary(custom: custom) else {
            connection = .failed("aria2c was not found. Install it with Homebrew (brew install aria2) or choose its location in Preferences.")
            return
        }
        do {
            try DaemonManager.shared.start(binary: binary, endpoint: endpoint, downloadDir: Prefs.downloadDir,
                                           extraOptions: Prefs.torrentLaunchOptions)
            connection = .connecting
        } catch {
            connection = .failed("Could not start aria2c: \(error.localizedDescription)")
        }
    }

    // MARK: Snapshot handling

    private func apply(_ list: [Download], stat: GlobalStat) {
        var visible = list.filter { !($0.isMetadataOnly && $0.status == .complete) }
        visible = visible.filter { $0.status != .removed }

        // Notifications for downloads that finished while the app was running.
        for d in visible {
            let done = d.isDone
            if let previous = wasDone[d.id], previous == false, done, d.status != .error {
                notifyComplete(d)
            }
            if d.status == .error, wasDone[d.id] != nil, wasDone[d.id] == false {
                notifyFailed(d)
            }
            wasDone[d.id] = d.status == .error ? true : done
        }
        // Run post-download rules when a transfer moves into the finished state while we watch.
        // A torrent is only finished once it stops seeding, so its files are never moved from under aria2.
        for d in visible where d.status == .complete && !d.isMetadataOnly {
            if let before = previousStatus[d.id], before != .complete {
                Automation.shared.runRules(for: d)
            }
        }
        previousStatus = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.status) })

        let ids = Set(visible.map(\.id))
        wasDone = wasDone.filter { ids.contains($0.key) }

        if visible != downloads { downloads = visible }
        if self.stat != stat { self.stat = stat }
        downHistory.append(stat.downloadSpeed); downHistory.removeFirst(downHistory.count - SpeedGraph.samples)
        upHistory.append(stat.uploadSpeed); upHistory.removeFirst(upHistory.count - SpeedGraph.samples)
        selection.formIntersection(ids)
        updateDockBadge()
        checkMetadataPickers(visible)
    }

    private func updateDockBadge() {
        guard UserDefaults.standard.bool(forKey: PrefKey.badgeDock) else {
            NSApp?.dockTile.badgeLabel = nil
            return
        }
        let n = downloads.filter(\.isDownloading).count
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    // MARK: Derived lists

    func matches(_ d: Download, _ f: DownloadFilter) -> Bool {
        switch f {
        case .all: return true
        case .active: return d.status == .active && (d.downloadSpeed > 0 || d.uploadSpeed > 0)
        case .downloading: return d.isDownloading
        case .seeding: return d.isSeeding
        case .paused: return d.status == .paused
        case .error: return d.status == .error
        }
    }

    func count(for f: DownloadFilter) -> Int { downloads.filter { matches($0, f) }.count }

    var visibleDownloads: [Download] {
        var list = downloads.filter { matches($0, filter) }
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { list = list.filter { $0.displayName.localizedCaseInsensitiveContains(q) } }
        switch sortOrder {
        case .queue: break
        case .name: list.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .progress: list.sort { $0.fraction > $1.fraction }
        case .size: list.sort { $0.totalLength > $1.totalLength }
        case .speed: list.sort { ($0.downloadSpeed + $0.uploadSpeed) > ($1.downloadSpeed + $1.uploadSpeed) }
        case .state: list.sort { $0.status.rawValue < $1.status.rawValue }
        }
        return reverseSort ? list.reversed() : list
    }

    var selectedDownloads: [Download] { downloads.filter { selection.contains($0.id) } }
    var activeTargets: [Download] { selectedDownloads }

    // MARK: Actions

    func perform(_ work: @escaping (Aria2Client) async throws -> Void) {
        Task {
            guard let client else {
                alertMessage = "Not connected to aria2."
                return
            }
            do { try await work(client) } catch { alertMessage = error.localizedDescription }
        }
    }

    func addURIs(_ text: String, options: [String: String] = [:]) {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        let pick = UserDefaults.standard.bool(forKey: PrefKey.pickFiles)
        perform { [weak self] client in
            // One download per line. Several mirrors of the same file can be space separated.
            for line in lines {
                let mirrors = line.split(separator: " ").map(String.init)
                var opts = options
                let isMagnet = mirrors.first?.lowercased().hasPrefix("magnet:") == true
                if isMagnet && pick { opts["pause-metadata"] = "true" }
                let gid = try await client.addURIs(mirrors, options: opts)
                if isMagnet && pick {
                    await MainActor.run { _ = self?.awaitingMetadata.insert(gid) }
                }
            }
        }
    }

    func addFile(_ url: URL, options: [String: String] = [:]) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            alertMessage = "Could not read \(url.lastPathComponent)."
            return
        }
        let ext = url.pathExtension.lowercased()
        let pick = UserDefaults.standard.bool(forKey: PrefKey.pickFiles)
        perform { [weak self] client in
            if ext == "metalink" || ext == "meta4" {
                try await client.addMetalink(data, options: options)
            } else {
                var opts = options
                if pick { opts["pause"] = "true" }
                let gid = try await client.addTorrent(data, options: opts)
                TorrentArchive.save(data, forGID: gid, client: client)
                if pick { await MainActor.run { self?.pickerGID = gid } }
            }
        }
    }

    func handleIncoming(_ urls: [URL]) {
        for url in urls {
            if url.scheme == "rivulet" {
                // rivulet://open shows the window. rivulet://add?url=... queues a link (handy for Shortcuts).
                if url.host == "add",
                   let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                    let links = items.filter { $0.name == "url" }.compactMap(\.value)
                    let allowed = links.filter { ["http", "https", "magnet", "ftp"].contains(URL(string: $0)?.scheme?.lowercased() ?? "") }
                    if !allowed.isEmpty { addURIs(allowed.joined(separator: "\n")) }
                } else {
                    NSApp.activate(ignoringOtherApps: true)
                    openMainWindow?()
                }
            } else if url.isFileURL {
                addFile(url)
            } else {
                addURIs(url.absoluteString)
            }
        }
    }

    func pause(_ items: [Download]) {
        let ids = items.filter { !$0.isStopped && $0.status != .paused }.map(\.id)
        perform { client in for id in ids { try await client.pause(id) } }
    }

    func resume(_ items: [Download]) {
        let paused = items.filter { $0.status == .paused }.map(\.id)
        let failed = items.filter { $0.status == .error }
        perform { client in
            for id in paused { try await client.resume(id) }
            for d in failed {
                if let uri = d.primaryURI {
                    try await client.addURIs([uri])
                    try await client.remove(d.id, isStopped: true)
                }
            }
        }
    }

    func pauseAll() { perform { try await $0.pauseAll() } }
    func resumeAll() { perform { try await $0.resumeAll() } }

    func requestRemove(_ items: [Download]) {
        guard !items.isEmpty else { return }
        if UserDefaults.standard.bool(forKey: PrefKey.confirmRemove) {
            pendingRemoval = items
            showRemoveConfirm = true
        } else {
            remove(items, deleteFiles: false)
        }
    }

    func remove(_ items: [Download], deleteFiles: Bool) {
        let snapshot = items
        perform { client in
            for d in snapshot {
                try? await client.remove(d.id, isStopped: d.isStopped)
                if !d.isStopped { try? await client.remove(d.id, isStopped: true) }
            }
        }
        if deleteFiles {
            for d in snapshot { trashFiles(of: d) }
        }
        selection.subtract(snapshot.map(\.id))
    }

    func clearFinished() {
        perform { try await $0.purgeStopped() }
    }

    private func trashFiles(of d: Download) {
        let fm = FileManager.default
        var targets: [String] = []
        if d.isTorrent, d.files.count > 1 {
            targets.append((d.dir as NSString).appendingPathComponent(d.name))
        } else {
            targets += d.files.map(\.path)
        }
        targets += targets.map { $0 + ".aria2" }
        for path in targets where fm.fileExists(atPath: path) {
            try? fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
    }

    func reveal(_ d: Download) {
        let path = d.localPath
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else if FileManager.default.fileExists(atPath: d.dir) {
            NSWorkspace.shared.open(URL(fileURLWithPath: d.dir))
        } else {
            NSSound.beep()
        }
    }

    func moveToTop(_ items: [Download]) {
        let ids = items.map(\.id)
        perform { client in for id in ids.reversed() { try await client.moveToTop(id) } }
    }

    func copyMagnet(_ d: Download) {
        guard let link = d.magnetLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    // MARK: Global options

    func applyGlobalSettings() async {
        guard let client else { return }
        let d = UserDefaults.standard
        let alt = d.bool(forKey: PrefKey.altSpeedEnabled)
        let down = alt ? d.integer(forKey: PrefKey.altDownloadKB) : d.integer(forKey: PrefKey.maxDownloadKB)
        let up = alt ? d.integer(forKey: PrefKey.altUploadKB) : d.integer(forKey: PrefKey.maxUploadKB)
        var options: [String: String] = [
            "max-overall-download-limit": "\(down * 1024)",
            "max-overall-upload-limit": "\(up * 1024)",
            "max-concurrent-downloads": "\(max(1, d.integer(forKey: PrefKey.maxConcurrent)))",
            "seed-ratio": String(format: "%.2f", d.double(forKey: PrefKey.seedRatio)),
        ]
        if Prefs.isManaged { options["dir"] = Prefs.downloadDir }
        for (k, v) in await torrentGlobalOptions() { options[k] = v }
        do { try await client.changeGlobalOptions(options) } catch { alertMessage = error.localizedDescription }
        altSpeedOn = alt
    }

    func toggleAltSpeed() {
        let on = !UserDefaults.standard.bool(forKey: PrefKey.altSpeedEnabled)
        UserDefaults.standard.set(on, forKey: PrefKey.altSpeedEnabled)
        altSpeedOn = on
        Task { await applyGlobalSettings() }
    }

    // MARK: Inspector data

    func detail(_ gid: String, detail: Bool = false) async -> Download? { try? await client?.status(gid, detail: detail) }
    func peers(_ gid: String) async -> [Peer] { (try? await client?.peers(gid)) ?? [] }
    func options(_ gid: String) async -> [String: String] { (try? await client?.options(gid)) ?? [:] }

    func setOptions(_ gid: String, _ options: [String: String]) {
        perform { try await $0.changeOptions(gid, options) }
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func post(title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: PrefKey.notifyOnComplete),
              Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func notifyComplete(_ d: Download) {
        post(title: d.isTorrent ? "Download Complete" : "Download Finished", body: d.displayName)
    }

    private func notifyFailed(_ d: Download) {
        post(title: "Download Failed", body: "\(d.displayName): \(d.errorMessage ?? "unknown error")")
    }
}
