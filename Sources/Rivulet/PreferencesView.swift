import AppKit
import RivuletCore
import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPrefs()
                .tabItem { Label("General", systemImage: "gearshape") }
            TransferPrefs()
                .tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down") }
            TorrentPrefs()
                .tabItem { Label("Torrents", systemImage: "point.3.connected.trianglepath.dotted") }
            SourcesPrefs()
                .tabItem { Label("Sources", systemImage: "puzzlepiece.extension") }
            AutomationPrefs()
                .tabItem { Label("Automation", systemImage: "wand.and.stars") }
            SchedulePrefs()
                .tabItem { Label("Schedule", systemImage: "calendar.badge.clock") }
            NetworkPrefs()
                .tabItem { Label("Network", systemImage: "network") }
        }
        .frame(width: 560, height: 520)
    }
}

private struct GeneralPrefs: View {
    @AppStorage(PrefKey.downloadDir) private var downloadDir = Prefs.downloadDir
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBar = true
    @AppStorage(PrefKey.showSpeedInMenuBar) private var showSpeed = false
    @AppStorage(PrefKey.badgeDock) private var badge = true
    @AppStorage(PrefKey.notifyOnComplete) private var notify = true
    @AppStorage(PrefKey.confirmRemove) private var confirm = true

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Save to") {
                    HStack {
                        Text(downloadDir).lineLimit(1).truncationMode(.middle)
                        Button("Choose...") { choose() }
                    }
                }
                Toggle("Confirm before removing transfers", isOn: $confirm)
            }
            Section("Appearance") {
                Toggle("Show icon in the menu bar", isOn: $showMenuBar)
                Toggle("Show transfer speed in the menu bar", isOn: $showSpeed)
                    .disabled(!showMenuBar)
                Toggle("Badge the Dock icon with the number of active downloads", isOn: $badge)
            }
            Section("Notifications") {
                Toggle("Notify when a transfer finishes or fails", isOn: $notify)
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            downloadDir = url.path
            Task { try? await applyDir(url.path) }
        }
    }

    @MainActor
    private func applyDir(_ path: String) async throws {
        // Takes effect for new transfers immediately; the daemon default is updated on next launch for managed mode.
        await AppState.shared.applyGlobalSettings()
    }
}

private struct TransferPrefs: View {
    @AppStorage(PrefKey.maxDownloadKB) private var maxDown = 0
    @AppStorage(PrefKey.maxUploadKB) private var maxUp = 0
    @AppStorage(PrefKey.altDownloadKB) private var altDown = 100
    @AppStorage(PrefKey.altUploadKB) private var altUp = 50
    @AppStorage(PrefKey.maxConcurrent) private var concurrent = 5
    @AppStorage(PrefKey.seedRatio) private var seedRatio = 1.0

    var body: some View {
        Form {
            Section("Speed Limits (KB/s, 0 for unlimited)") {
                numberField("Download", $maxDown)
                numberField("Upload", $maxUp)
            }
            Section("Alternate Speed Limits (turtle button)") {
                numberField("Download", $altDown)
                numberField("Upload", $altUp)
            }
            Section("Queue and Seeding") {
                Stepper("Active downloads at once: \(concurrent)", value: $concurrent, in: 1...20)
                HStack {
                    Text("Seed torrents until ratio")
                    Spacer()
                    TextField("", value: $seedRatio, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: maxDown) { _, _ in apply() }
        .onChange(of: maxUp) { _, _ in apply() }
        .onChange(of: altDown) { _, _ in apply() }
        .onChange(of: altUp) { _, _ in apply() }
        .onChange(of: concurrent) { _, _ in apply() }
        .onChange(of: seedRatio) { _, _ in apply() }
    }

    private func numberField(_ title: String, _ value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: value, format: .number)
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
        }
    }

    private func apply() {
        Task { await AppState.shared.applyGlobalSettings() }
    }
}

private struct NetworkPrefs: View {
    @AppStorage(PrefKey.connectionMode) private var mode = "managed"
    @AppStorage(PrefKey.host) private var host = "localhost"
    @AppStorage(PrefKey.port) private var port = 6800
    @AppStorage(PrefKey.secret) private var secret = ""
    @AppStorage(PrefKey.aria2Path) private var aria2Path = ""
    @State private var copied = false
    private let state = AppState.shared

    var body: some View {
        Form {
            Section("aria2") {
                Picker("Daemon", selection: $mode) {
                    Text("Rivulet starts and manages aria2c").tag("managed")
                    Text("Connect to an aria2 that is already running").tag("external")
                }
                .pickerStyle(.radioGroup)

                if mode == "external" {
                    TextField("Host", text: $host)
                }
                TextField("Port", value: $port, format: .number.grouping(.never))
                SecureField("RPC secret", text: $secret)
                if mode == "managed" {
                    LabeledContent("aria2c") {
                        Text(DaemonManager.locateBinary(custom: aria2Path) ?? "Not found")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            Section("Browser Extension") {
                LabeledContent("RPC URL") {
                    Text("http://localhost:\(port, format: .number.grouping(.never))/jsonrpc")
                        .textSelection(.enabled)
                }
                HStack {
                    Text("Use the same secret in the extension's options page.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy Secret") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(secret, forType: .string)
                        copied = true
                    }
                }
            }
            Section {
                HStack {
                    statusText
                    Spacer()
                    Button("Reconnect") { state.reconnect() }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusText: some View {
        switch state.connection {
        case .connected(let v): Label("Connected, aria2 \(v)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .connecting: Label("Connecting...", systemImage: "circle.dotted")
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        }
    }
}

private struct TorrentPrefs: View {
    @AppStorage(PrefKey.pickFiles) private var pickFiles = true
    @AppStorage(PrefKey.addPublicTrackers) private var publicTrackers = false
    @AppStorage(PrefKey.customTrackers) private var customTrackers = ""
    @AppStorage(PrefKey.requireEncryption) private var encryption = false
    @AppStorage(PrefKey.enableDHT) private var dht = true
    @AppStorage(PrefKey.enablePEX) private var pex = true
    @AppStorage(PrefKey.enableLPD) private var lpd = true
    @AppStorage(PrefKey.btListenPort) private var port = 6881
    @AppStorage(PrefKey.btMaxPeers) private var maxPeers = 55
    @AppStorage(PrefKey.seedTimeMinutes) private var seedTime = 0

    var body: some View {
        Form {
            Section("Adding") {
                Toggle("Choose files when adding a torrent", isOn: $pickFiles)
            }
            Section("Trackers") {
                Toggle("Add a list of public trackers to new torrents", isOn: $publicTrackers)
                Text("Downloads a community maintained list from GitHub once a week. Off by default.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Extra trackers for every torrent (one per line)").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $customTrackers)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 56)
                    .scrollContentBackground(.hidden)
            }
            Section("Peers") {
                Toggle("Require encrypted connections", isOn: $encryption)
                HStack {
                    Text("Maximum peers per torrent")
                    Spacer()
                    TextField("", value: $maxPeers, format: .number)
                        .frame(width: 70).multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Stop seeding after (minutes, 0 = use ratio only)")
                    Spacer()
                    TextField("", value: $seedTime, format: .number)
                        .frame(width: 70).multilineTextAlignment(.trailing)
                }
            }
            Section("Discovery (applied the next time aria2 starts)") {
                Toggle("DHT", isOn: $dht)
                Toggle("Peer exchange", isOn: $pex)
                Toggle("Local peer discovery", isOn: $lpd)
                HStack {
                    Text("Listen port")
                    Spacer()
                    TextField("", value: $port, format: .number.grouping(.never))
                        .frame(width: 70).multilineTextAlignment(.trailing)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: publicTrackers) { _, _ in apply() }
        .onChange(of: customTrackers) { _, _ in apply() }
        .onChange(of: encryption) { _, _ in apply() }
        .onChange(of: maxPeers) { _, _ in apply() }
        .onChange(of: seedTime) { _, _ in apply() }
    }

    private func apply() {
        Task { await AppState.shared.applyGlobalSettings() }
    }
}
