import AppKit
import RivuletCore
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Bindable private var state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            FilterBar()
            Divider()
            content
            Divider()
            StatusBar()
        }
        .toolbar(id: "main") { MainToolbar() }
        .fileImporter(
            isPresented: $state.showTorrentImporter,
            allowedContentTypes: Self.torrentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { urls.forEach { state.addFile($0) } }
        }
        .sheet(isPresented: $state.showAddURL) { AddURLSheet() }
        .sheet(isPresented: Binding(
            get: { state.pickerGID != nil },
            set: { if !$0 { state.pickerGID = nil } }
        )) {
            if let gid = state.pickerGID { FilePickerSheet(gid: gid) }
        }
        .confirmationDialog(removalTitle, isPresented: $state.showRemoveConfirm, titleVisibility: .visible) {
            Button("Remove from List") { state.remove(state.pendingRemoval, deleteFiles: false) }
            Button("Remove and Move Data to Trash", role: .destructive) {
                state.remove(state.pendingRemoval, deleteFiles: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transfer will stop. You can also move the downloaded data to the Trash.")
        }
        .alert("Rivulet", isPresented: Binding(
            get: { state.alertMessage != nil },
            set: { if !$0 { state.alertMessage = nil } }
        )) {
            Button("OK") { state.alertMessage = nil }
        } message: {
            Text(state.alertMessage ?? "")
        }
        .dropDestination(for: URL.self) { urls, _ in
            state.handleIncoming(urls)
            return !urls.isEmpty
        }
        .dropDestination(for: String.self) { strings, _ in
            let text = strings.joined(separator: "\n")
            state.addURIs(text)
            return !text.isEmpty
        }
        .navigationTitle("Rivulet")
        .onAppear {
            state.openGrabberWindow = { openWindow(id: "grabber") }
            // Needed when the menu bar icon is hidden: lets the Dock icon reopen this window.
            if state.openMainWindow == nil {
                state.openMainWindow = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
            }
        }
    }

    static var torrentTypes: [UTType] {
        var types: [UTType] = []
        for ext in ["torrent", "metalink", "meta4"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types.isEmpty ? [.data] : types + [.data]
    }

    private var removalTitle: String {
        let n = state.pendingRemoval.count
        return n == 1 ? "Remove \"\(state.pendingRemoval.first?.displayName ?? "")\"?" : "Remove \(n) transfers?"
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = state.connection {
            ConnectionProblem(message: message)
        } else if state.visibleDownloads.isEmpty {
            EmptyTransfers(connecting: state.connection == .connecting, filtered: !state.downloads.isEmpty)
        } else {
            List(selection: $state.selection) {
                ForEach(state.visibleDownloads) { d in
                    DownloadRow(download: d, isSelected: state.selection.contains(d.id))
                        .tag(d.id)
                        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
            .contextMenu(forSelectionType: String.self) { ids in
                RowContextMenu(ids: ids)
            } primaryAction: { ids in
                state.selection = ids
                openWindow(id: "inspector")
            }
            .onDeleteCommand { state.requestRemove(state.selectedDownloads) }
        }
    }
}

// MARK: - Toolbar

struct MainToolbar: CustomizableToolbarContent {
    private let state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "open", placement: .automatic) {
            Button { state.showTorrentImporter = true } label: {
                Label("Open", systemImage: "doc.badge.plus")
            }
            .help("Open torrent or metalink files")
        }
        ToolbarItem(id: "openAddress", placement: .automatic) {
            Button { state.showAddURL = true } label: {
                Label("Open Address", systemImage: "link.badge.plus")
            }
            .help("Add a link or magnet")
        }
        ToolbarItem(id: "grabber", placement: .automatic) {
            Button { openWindow(id: "grabber") } label: {
                Label("Link Grabber", systemImage: "list.bullet.rectangle")
            }
            .help("Analyze pages, albums and folders before downloading")
        }
        ToolbarItem(id: "remove", placement: .automatic) {
            Button { state.requestRemove(state.selectedDownloads) } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .disabled(state.selection.isEmpty)
            .help("Remove selected transfers")
        }
        ToolbarItem(id: "pauseAll", placement: .automatic, showsByDefault: false) {
            Button { state.pauseAll() } label: { Label("Pause All", systemImage: "pause.circle") }
                .help("Pause all transfers")
        }
        ToolbarItem(id: "resumeAll", placement: .automatic, showsByDefault: false) {
            Button { state.resumeAll() } label: { Label("Resume All", systemImage: "play.circle") }
                .help("Resume all transfers")
        }
        ToolbarItem(id: "pauseSelected", placement: .automatic) {
            Button { state.pause(state.selectedDownloads) } label: {
                Label("Pause Selected", systemImage: "pause.fill")
            }
            .disabled(state.selection.isEmpty)
            .help("Pause selected transfers")
        }
        ToolbarItem(id: "resumeSelected", placement: .automatic) {
            Button { state.resume(state.selectedDownloads) } label: {
                Label("Resume Selected", systemImage: "play.fill")
            }
            .disabled(state.selection.isEmpty)
            .help("Resume selected transfers")
        }
        ToolbarItem(id: "inspector", placement: .automatic) {
            Button { openWindow(id: "inspector") } label: {
                Label("Inspector", systemImage: "info.circle")
            }
            .help("Show the inspector")
        }
    }
}

// MARK: - Filter bar

struct FilterBar: View {
    @Bindable private var state = AppState.shared

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DownloadFilter.allCases) { f in
                Button {
                    state.filter = f
                } label: {
                    HStack(spacing: 4) {
                        Text(f.title)
                        let n = state.count(for: f)
                        if n > 0 {
                            Text("\(n)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .font(.system(size: 11, weight: state.filter == f ? .semibold : .regular))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(state.filter == f ? Color.primary.opacity(0.12) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Filter", text: $state.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 130)
                if !state.searchText.isEmpty {
                    Button { state.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Bindable private var state = AppState.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Add Link...") { state.showAddURL = true }
                Button("Open Torrent File...") { state.showTorrentImporter = true }
                Divider()
                Button("Pause All") { state.pauseAll() }
                Button("Resume All") { state.resumeAll() }
                Button("Clear Finished") { state.clearFinished() }
                Divider()
                Picker("Sort By", selection: $state.sortOrder) {
                    ForEach(SortOrder.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Reverse Order", isOn: $state.reverseSort)
                Divider()
                Button("Preferences...") { openSettings() }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions")

            Button { state.toggleAltSpeed() } label: {
                Image(systemName: state.altSpeedOn ? "tortoise.fill" : "tortoise")
                    .foregroundStyle(state.altSpeedOn ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(state.altSpeedOn ? "Alternate speed limits are on" : "Turn on alternate speed limits")

            Spacer()
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()

            SpeedGraph(down: state.downHistory, up: state.upHistory)
                .frame(width: 84, height: 16)
                .help("Transfer speed over the last two minutes")

            HStack(spacing: 10) {
                Label(Format.speed(state.stat.downloadSpeed), systemImage: "arrow.down")
                Label(Format.speed(state.stat.uploadSpeed), systemImage: "arrow.up")
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .labelStyle(CompactLabelStyle())
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }

    private var summary: String {
        let n = state.downloads.count
        switch state.connection {
        case .connecting: return "Connecting..."
        case .failed: return "Not connected"
        case .connected: return "\(n) \(n == 1 ? "transfer" : "transfers")"
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}

// MARK: - Empty and error states

struct EmptyTransfers: View {
    let connecting: Bool
    let filtered: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: connecting ? "arrow.triangle.2.circlepath" : (filtered ? "line.3.horizontal.decrease.circle" : "arrow.down.circle"))
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text(connecting ? "Connecting to aria2" : (filtered ? "No matching transfers" : "No transfers"))
                .font(.headline)
            if !connecting && !filtered {
                Text("Drop a torrent file or link here, or use Open.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConnectionProblem: View {
    let message: String
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.orange)
            Text("Cannot connect to aria2").font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack {
                Button("Retry") { AppState.shared.reconnect() }
                Button("Open Preferences") { openSettings() }
            }
            .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Context menu

struct RowContextMenu: View {
    let ids: Set<String>
    private let state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    private var items: [Download] { state.downloads.filter { ids.contains($0.id) } }

    var body: some View {
        if !items.isEmpty {
            Button("Resume") { state.resume(items) }
            Button("Pause") { state.pause(items) }
            Divider()
            Button("Move to Top of Queue") { state.moveToTop(items) }
            Divider()
            if items.count == 1, let d = items.first {
                Button("Show in Finder") { state.reveal(d) }
                if d.isTorrent {
                    Button("Choose Files...") { state.pickerGID = d.id }
                    Button("Verify Local Data") { state.verifyLocalData(d) }
                }
                if d.isDone || d.status == .paused {
                    Button("Move Data...") { state.chooseFolderAndMove(d) }
                }
                if d.magnetLink != nil {
                    Button("Copy Magnet Link") { state.copyMagnet(d) }
                }
                if let uri = d.primaryURI, !d.isTorrent {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(uri, forType: .string)
                    }
                }
                Button("Inspector") {
                    state.selection = ids
                    openWindow(id: "inspector")
                }
                Divider()
            }
            Button("Remove...") { state.requestRemove(items) }
        }
    }
}
