import AppKit
import Foundation
import RivuletCore

/// Keeps a copy of each .torrent added through Rivulet so a torrent can be re-added later (verify, move).
enum TorrentArchive {
    static var directory: URL {
        let dir = DaemonManager.supportDirectory.appendingPathComponent("torrents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(forHash hash: String) -> URL {
        directory.appendingPathComponent("\(hash.lowercased()).torrent")
    }

    static func save(_ data: Data, forGID gid: String, client: Aria2Client) {
        Task {
            guard let d = try? await client.status(gid), let hash = d.infoHash, !hash.isEmpty else { return }
            try? data.write(to: url(forHash: hash), options: .atomic)
        }
    }

    /// The torrent bytes for a download, from our archive or from aria2's saved metadata next to the data.
    static func load(for d: Download) -> Data? {
        guard let hash = d.infoHash?.lowercased() else { return nil }
        if let data = try? Data(contentsOf: url(forHash: hash)) { return data }
        let beside = URL(fileURLWithPath: d.dir).appendingPathComponent("\(hash).torrent")
        return try? Data(contentsOf: beside)
    }
}

extension AppState {
    // MARK: File selection

    /// Applies a file selection. A running torrent is paused around the change, because aria2 only
    /// accepts a new selection for a paused download.
    func setFileSelection(_ d: Download, indexes: Set<Int>, thenResume: Bool) {
        let gid = d.id
        let wasPaused = d.status == .paused
        let chosen = Array(indexes)
        perform { client in
            if !wasPaused { try await client.pause(gid) }
            try await client.selectFiles(gid, indexes: chosen)
            if thenResume || !wasPaused { try await client.resume(gid) }
        }
    }

    /// Removes a torrent the user decided not to download, along with anything aria2 created for it.
    func cancelPending(_ gid: String) {
        perform { client in
            try? await client.remove(gid, isStopped: false)
            try? await client.remove(gid, isStopped: true)
        }
    }

    /// Called after every snapshot: when a magnet's metadata finishes, aria2 creates the real
    /// download (paused, because of pause-metadata). Offer the file picker for it.
    func checkMetadataPickers(_ list: [Download]) {
        guard !awaitingMetadata.isEmpty else { return }
        for source in awaitingMetadata {
            guard let metadata = list.first(where: { $0.id == source }) else {
                // The metadata download is gone from the list; stop waiting for it.
                if !list.contains(where: { $0.id == source }) { awaitingMetadata.remove(source) }
                continue
            }
            guard metadata.status == .complete || metadata.status == .removed || !metadata.followedBy.isEmpty,
                  let child = metadata.followedBy.first else { continue }
            awaitingMetadata.remove(source)
            if list.contains(where: { $0.id == child && $0.status == .paused }) { pickerGID = child }
        }
    }

    // MARK: Verify and move

    func verifyLocalData(_ d: Download) {
        guard d.isTorrent else {
            alertMessage = "Only torrents can be re-verified."
            return
        }
        guard let data = TorrentArchive.load(for: d) else {
            alertMessage = "Rivulet does not have the .torrent file for this transfer, so it cannot re-check it. Torrents added from a file or from a magnet link while Rivulet is open are kept automatically."
            return
        }
        let dir = d.dir
        perform { client in
            try? await client.remove(d.id, isStopped: d.isStopped)
            if !d.isStopped { try? await client.remove(d.id, isStopped: true) }
            try await client.addTorrent(data, options: ["dir": dir, "check-integrity": "true"])
        }
    }

    func moveData(_ d: Download, to destination: URL) {
        let fm = FileManager.default
        guard d.isDone || d.status == .paused else {
            alertMessage = "Pause the transfer or wait for it to finish before moving its data."
            return
        }
        let source = d.isTorrent && d.files.count > 1
            ? URL(fileURLWithPath: d.dir).appendingPathComponent(d.name)
            : URL(fileURLWithPath: d.files.first?.path ?? "")
        guard fm.fileExists(atPath: source.path) else {
            alertMessage = "The files for this transfer were not found on disk."
            return
        }
        let target = destination.appendingPathComponent(source.lastPathComponent)
        guard !fm.fileExists(atPath: target.path) else {
            alertMessage = "\(destination.lastPathComponent) already contains \"\(source.lastPathComponent)\"."
            return
        }
        let torrentData = d.isTorrent ? TorrentArchive.load(for: d) : nil
        if d.isTorrent && torrentData == nil {
            alertMessage = "Rivulet does not have the .torrent file for this transfer, so it cannot keep seeding from a new folder."
            return
        }
        perform { client in
            if d.isTorrent {
                try? await client.remove(d.id, isStopped: d.isStopped)
                if !d.isStopped { try? await client.remove(d.id, isStopped: true) }
            }
            try fm.moveItem(at: source, to: target)
            if d.isTorrent, let data = torrentData {
                try await client.addTorrent(data, options: ["dir": destination.path, "check-integrity": "true"])
            }
        }
    }

    func chooseFolderAndMove(_ d: Download) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        if panel.runModal() == .OK, let url = panel.url { moveData(d, to: url) }
    }

    // MARK: Torrent global options

    /// Everything torrent related that aria2 accepts while running.
    func torrentGlobalOptions() async -> [String: String] {
        let d = UserDefaults.standard
        var options: [String: String] = [
            "bt-max-peers": "\(max(0, d.integer(forKey: PrefKey.btMaxPeers)))",
            "bt-require-crypto": d.bool(forKey: PrefKey.requireEncryption) ? "true" : "false",
            "bt-min-crypto-level": d.bool(forKey: PrefKey.requireEncryption) ? "arc4" : "plain",
        ]
        // aria2 treats seed-time=0 as "do not seed at all", so only send it when the user set a limit.
        let seedMinutes = d.integer(forKey: PrefKey.seedTimeMinutes)
        if seedMinutes > 0 { options["seed-time"] = "\(seedMinutes)" }
        var trackers = Self.parseTrackers(d.string(forKey: PrefKey.customTrackers) ?? "")
        if d.bool(forKey: PrefKey.addPublicTrackers) {
            trackers += await publicTrackers()
        }
        var seen = Set<String>()
        trackers = trackers.filter { seen.insert($0).inserted }
        options["bt-tracker"] = trackers.joined(separator: ",")
        return options
    }

    static func parseTrackers(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { url in
                let l = url.lowercased()
                return l.hasPrefix("udp://") || l.hasPrefix("http://") || l.hasPrefix("https://") || l.hasPrefix("wss://")
            }
    }

    /// A community maintained list of public trackers, fetched only when the user turns the option on,
    /// and cached for a week.
    func publicTrackers() async -> [String] {
        let d = UserDefaults.standard
        let fetched = d.double(forKey: PrefKey.publicTrackerFetchedAt)
        let cached = Self.parseTrackers(d.string(forKey: PrefKey.publicTrackerCache) ?? "")
        if !cached.isEmpty, Date().timeIntervalSince1970 - fetched < 7 * 86_400 { return cached }
        guard let url = URL(string: "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt") else { return cached }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 200_000,
              let text = String(data: data, encoding: .utf8) else { return cached }
        let list = Self.parseTrackers(text)
        guard !list.isEmpty else { return cached }
        d.set(list.joined(separator: "\n"), forKey: PrefKey.publicTrackerCache)
        d.set(Date().timeIntervalSince1970, forKey: PrefKey.publicTrackerFetchedAt)
        return list
    }

    func addTrackers(_ d: Download, _ text: String) {
        let list = Self.parseTrackers(text)
        guard !list.isEmpty else { return }
        perform { try await $0.addTrackers(d.id, list) }
    }
}
