import AppKit
import RivuletCore
import SwiftUI

struct MenuBarLabel: View {
    private let state = AppState.shared
    @AppStorage(PrefKey.showSpeedInMenuBar) private var showSpeed = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if showSpeed && state.stat.downloadSpeed > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.circle")
                    Text(Format.speed(state.stat.downloadSpeed))
                }
            } else {
                Image(systemName: state.stat.numActive > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
        }
        .onAppear {
            AppState.shared.openMainWindow = {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
        }
    }
}

struct MenuBarContent: View {
    private let state = AppState.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var active: [Download] {
        state.downloads.filter { $0.status == .active || $0.status == .waiting }.prefix(8).map { $0 }
    }

    var body: some View {
        Text("Download: \(Format.speed(state.stat.downloadSpeed))    Upload: \(Format.speed(state.stat.uploadSpeed))")

        if !state.connection.isConnected {
            Text("aria2 is not connected")
        }

        Divider()

        if active.isEmpty {
            Text("No active transfers")
        } else {
            ForEach(active) { d in
                Button {
                    state.selection = [d.id]
                    show()
                } label: {
                    Text("\(d.displayName)  -  \(Format.percent(d.fraction))")
                }
            }
        }

        Divider()

        Button("Open Rivulet") { show() }
            .keyboardShortcut("0", modifiers: [.command, .option])
        Button("Add Link...") {
            show()
            state.showAddURL = true
        }
        Button("Link Grabber...") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "grabber")
        }
        Button("Open Torrent File...") {
            show()
            state.showTorrentImporter = true
        }

        Divider()

        Button("Pause All") { state.pauseAll() }
        Button("Resume All") { state.resumeAll() }
        Button(state.altSpeedOn ? "Turn Off Alternate Speed Limits" : "Turn On Alternate Speed Limits") {
            state.toggleAltSpeed()
        }

        Divider()

        Button("Preferences...") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        Button("Quit Rivulet") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
