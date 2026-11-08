import AppKit
import RivuletCore
import SwiftUI

@main
struct RivuletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(PrefKey.showMenuBarIcon) private var showMenuBar = true

    init() {
        Prefs.register()
    }

    var body: some Scene {
        Window("Rivulet", id: "main") {
            MainView()
                .frame(minWidth: 560, minHeight: 340)
        }
        .defaultSize(width: 660, height: 520)
        .commands { AppCommands() }

        Window("Link Grabber", id: "grabber") {
            LinkGrabberView()
        }
        .defaultSize(width: 700, height: 500)

        Window("Inspector", id: "inspector") {
            InspectorView()
        }
        .defaultSize(width: 380, height: 470)

        Settings {
            PreferencesView()
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var termSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppState.shared.start() }

        // Make `kill` and logout shut the managed aria2c down too, instead of orphaning it.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // terminate(_:) can be vetoed by an open sheet, so stop the daemon and leave directly.
            MainActor.assumeIsolated { AppState.shared.shutdown() }
            exit(0)
        }
        source.resume()
        termSource = source
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            Task { @MainActor in AppState.shared.openMainWindow?() }
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppState.shared.handleIncoming(urls) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.shutdown() }
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    private let state = AppState.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Torrent File...") { state.showTorrentImporter = true }
                .keyboardShortcut("o")
            Button("Add Link...") { state.showAddURL = true }
                .keyboardShortcut("u")
            Button("Link Grabber...") { openWindow(id: "grabber") }
                .keyboardShortcut("g")
        }
        CommandMenu("Transfer") {
            Button("Resume Selected") { state.resume(state.selectedDownloads) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Pause Selected") { state.pause(state.selectedDownloads) }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            Button("Resume All") { state.resumeAll() }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
            Button("Pause All") { state.pauseAll() }
                .keyboardShortcut("p", modifiers: [.command, .option, .shift])
            Divider()
            Button("Show in Finder") {
                if let d = state.selectedDownloads.first { state.reveal(d) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Remove...") { state.requestRemove(state.selectedDownloads) }
                .keyboardShortcut(.delete, modifiers: [.command])
            Button("Clear Finished") { state.clearFinished() }
        }
        CommandGroup(after: .toolbar) {
            Button("Inspector") { openWindow(id: "inspector") }
                .keyboardShortcut("i")
        }
    }
}
