import Foundation
import RivuletCore

/// Central place for UserDefaults keys so views (via @AppStorage) and state agree.
enum PrefKey {
    static let connectionMode = "connectionMode"     // "managed" or "external"
    static let host = "rpcHost"
    static let port = "rpcPort"
    static let secret = "rpcSecret"
    static let downloadDir = "downloadDir"
    static let aria2Path = "aria2Path"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let showSpeedInMenuBar = "showSpeedInMenuBar"
    static let notifyOnComplete = "notifyOnComplete"
    static let confirmRemove = "confirmRemove"
    static let maxDownloadKB = "maxDownloadKB"
    static let maxUploadKB = "maxUploadKB"
    static let altDownloadKB = "altDownloadKB"
    static let altUploadKB = "altUploadKB"
    static let altSpeedEnabled = "altSpeedEnabled"
    static let maxConcurrent = "maxConcurrent"
    static let seedRatio = "seedRatio"
    static let sortOrder = "sortOrder"
    static let badgeDock = "badgeDock"
    static let pickFiles = "pickFiles"
    static let addPublicTrackers = "addPublicTrackers"
    static let customTrackers = "customTrackers"
    static let publicTrackerCache = "publicTrackerCache"
    static let publicTrackerFetchedAt = "publicTrackerFetchedAt"
    static let requireEncryption = "requireEncryption"
    static let enableDHT = "enableDHT"
    static let enablePEX = "enablePEX"
    static let enableLPD = "enableLPD"
    static let btListenPort = "btListenPort"
    static let btMaxPeers = "btMaxPeers"
    static let seedTimeMinutes = "seedTimeMinutes"
    static let watchClipboard = "watchClipboard"
    static let grabberUseYtDlp = "grabberUseYtDlp"
}

enum Prefs {
    static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            PrefKey.connectionMode: "managed",
            PrefKey.host: "localhost",
            PrefKey.port: 6800,
            PrefKey.secret: "",
            PrefKey.downloadDir: NSString(string: "~/Downloads").expandingTildeInPath,
            PrefKey.aria2Path: "",
            PrefKey.showMenuBarIcon: true,
            PrefKey.showSpeedInMenuBar: false,
            PrefKey.notifyOnComplete: true,
            PrefKey.confirmRemove: true,
            PrefKey.maxDownloadKB: 0,
            PrefKey.maxUploadKB: 0,
            PrefKey.altDownloadKB: 100,
            PrefKey.altUploadKB: 50,
            PrefKey.altSpeedEnabled: false,
            PrefKey.maxConcurrent: 5,
            PrefKey.seedRatio: 1.0,
            PrefKey.sortOrder: "queue",
            PrefKey.badgeDock: true,
            PrefKey.pickFiles: true,
            PrefKey.addPublicTrackers: false,
            PrefKey.customTrackers: "",
            PrefKey.requireEncryption: false,
            PrefKey.enableDHT: true,
            PrefKey.enablePEX: true,
            PrefKey.enableLPD: true,
            PrefKey.btListenPort: 6881,
            PrefKey.btMaxPeers: 55,
            PrefKey.seedTimeMinutes: 0,
            PrefKey.watchClipboard: false,
            PrefKey.grabberUseYtDlp: false,
        ])
        ensureSecret()
    }

    /// Managed mode needs a secret; generate a random one the first time.
    static func ensureSecret() {
        if (defaults.string(forKey: PrefKey.secret) ?? "").isEmpty {
            let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            let secret = String((0..<24).map { _ in chars.randomElement()! })
            defaults.set(secret, forKey: PrefKey.secret)
        }
    }

    static var isManaged: Bool { defaults.string(forKey: PrefKey.connectionMode) != "external" }

    static var endpoint: Aria2Endpoint {
        Aria2Endpoint(
            host: isManaged ? "localhost" : (defaults.string(forKey: PrefKey.host) ?? "localhost"),
            port: defaults.integer(forKey: PrefKey.port),
            secret: defaults.string(forKey: PrefKey.secret) ?? ""
        )
    }

    static var downloadDir: String {
        defaults.string(forKey: PrefKey.downloadDir) ?? NSString(string: "~/Downloads").expandingTildeInPath
    }

    /// Options passed to a managed aria2c at launch (they cannot all be changed while it runs).
    static var torrentLaunchOptions: [String] {
        let d = defaults
        func flag(_ key: String) -> String { d.bool(forKey: key) ? "true" : "false" }
        return [
            "enable-dht=\(flag(PrefKey.enableDHT))",
            "bt-enable-lpd=\(flag(PrefKey.enableLPD))",
            "enable-peer-exchange=\(flag(PrefKey.enablePEX))",
            "listen-port=\(max(1025, d.integer(forKey: PrefKey.btListenPort)))",
            "dht-listen-port=\(max(1025, d.integer(forKey: PrefKey.btListenPort)))",
        ]
    }
}
