import AppKit
import RivuletCore
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case info, activity, peers, files, options
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .activity: return "chart.xyaxis.line"
        case .peers: return "person.2"
        case .files: return "doc.on.doc"
        case .options: return "slider.horizontal.3"
        }
    }
    var title: String { rawValue.capitalized }
}

/// Floating inspector, modelled on Transmission's: icon tabs across the top, details below.
struct InspectorView: View {
    @Bindable private var state = AppState.shared
    @State private var tab: InspectorTab = .info
    @State private var detail: Download?
    @State private var peers: [Peer] = []
    @State private var options: [String: String] = [:]

    private var gid: String? { state.selection.count == 1 ? state.selection.first : nil }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(InspectorTab.allCases) { t in
                    Label(t.title, systemImage: t.symbol).labelStyle(.iconOnly).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            Group {
                if state.selection.count > 1 {
                    multiple
                } else if let d = detail, gid != nil {
                    VStack(spacing: 0) {
                        header(d)
                        Divider()
                        switch tab {
                        case .info: InfoTab(d: d)
                        case .activity: ActivityTab(d: d, peers: peers)
                        case .peers: PeersTab(d: d, peers: peers)
                        case .files: FilesTab(d: d)
                        case .options: OptionsTab(d: d, options: options)
                        }
                    }
                } else {
                    placeholder("No Selection")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 360, idealWidth: 380, minHeight: 380, idealHeight: 470)
        .background(WindowFloater())
        .task(id: gid) {
            detail = nil
            peers = []
            options = [:]
            guard let gid else { return }
            options = await state.options(gid)
            while !Task.isCancelled {
                detail = await state.detail(gid, detail: true)
                if tab == .peers || tab == .activity { peers = await state.peers(gid) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: tab) { _, new in
            guard new == .peers || new == .activity, let gid else { return }
            Task { peers = await state.peers(gid) }
        }
    }

    private func header(_ d: Download) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: DownloadRow.icon(for: d)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text("\(Format.bytes(d.totalLength)) - \(Format.percent(d.fraction))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
    }

    private var multiple: some View {
        let items = state.selectedDownloads
        return VStack(spacing: 6) {
            Text("\(items.count) Transfers Selected").font(.headline)
            Text("Total size: \(Format.bytes(items.reduce(0) { $0 + $1.totalLength }))")
                .foregroundStyle(.secondary)
            Text("Downloaded: \(Format.bytes(items.reduce(0) { $0 + $1.completedLength }))")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.title3).foregroundStyle(.tertiary)
    }
}

/// Keeps the inspector above the main window like a Transmission utility panel.
private struct WindowFloater: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.level = .floating
            v.window?.collectionBehavior.insert(.fullScreenAuxiliary)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Tabs

private struct KeyValueGrid<Footer: View>: View {
    let rows: [(String, String)]
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.0)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                                .frame(width: 110, alignment: .trailing)
                            Text(row.1.isEmpty ? "-" : row.1)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                footer()
            }
            .font(.system(size: 12))
            .padding(12)
        }
    }
}

extension KeyValueGrid where Footer == EmptyView {
    fileprivate init(rows: [(String, String)]) {
        self.init(rows: rows, footer: { EmptyView() })
    }
}

private struct InfoTab: View {
    let d: Download

    var body: some View {
        KeyValueGrid(rows: [
            ("Size", Format.bytes(d.totalLength)),
            ("Location", d.dir),
            ("Type", d.isTorrent ? "BitTorrent" : "Direct download"),
            ("Source", d.isTorrent ? "" : (d.primaryURI ?? "")),
            ("Hash", d.infoHash ?? ""),
            ("Pieces", d.numPieces > 0 ? "\(d.numPieces) pieces, \(Format.bytes(d.pieceLength)) each" : ""),
            ("Comment", d.comment ?? ""),
            ("Created", d.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? ""),
            ("Trackers", d.trackers.flatMap { $0 }.joined(separator: "\n")),
            ("Identifier", d.id),
        ])
    }
}

private struct ActivityTab: View {
    let d: Download
    let peers: [Peer]

    var body: some View {
        let availability = PieceMap.availability(own: d.bitfield, peers: peers.map(\.bitfield), pieces: d.numPieces)
        KeyValueGrid(rows: [
            ("State", stateText),
            ("Have", "\(Format.bytes(d.completedLength)) (\(Format.percent(d.fraction)))"),
            ("Uploaded", Format.bytes(d.uploadLength)),
            ("Ratio", Format.ratio(d.ratio)),
            ("Download rate", Format.speed(d.downloadSpeed)),
            ("Upload rate", Format.speed(d.uploadSpeed)),
            ("Connections", "\(d.connections)"),
            ("Seeders", d.isTorrent ? "\(d.numSeeders)" : ""),
            ("Availability", d.isTorrent && !peers.isEmpty ? "\(Format.percent(availability.reachable)) reachable, \(String(format: "%.2f", availability.copies)) copies" : ""),
            ("Time remaining", d.status == .active && !d.isSeeding ? Format.eta(d.eta) : ""),
            ("Error", d.errorMessage ?? ""),
        ]) {
            if d.isTorrent, d.numPieces > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pieces: \(d.numPieces) of \(Format.bytes(d.pieceLength))").foregroundStyle(.secondary)
                    PieceMapView(cells: PieceMap.cells(bitfield: d.bitfield, pieces: d.numPieces, count: min(d.numPieces, 600)))
                }
            }
        }
    }

    private var stateText: String {
        if d.isSeeding { return "Seeding" }
        return d.status.rawValue.capitalized
    }
}

private struct PeersTab: View {
    let d: Download
    let peers: [Peer]

    var body: some View {
        if !d.isTorrent {
            VStack(spacing: 6) {
                Text("\(d.connections) \(d.connections == 1 ? "connection" : "connections")")
                    .font(.headline)
                Text("Peer details are only available for torrents.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if peers.isEmpty {
            Text("No peers connected").foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(peers) {
                TableColumn("Address") { Text($0.address).monospacedDigit() }
                TableColumn("Client") { Text($0.client) }
                TableColumn("Flags") { Text($0.flags).font(.system(size: 11, design: .monospaced)) }
                    .width(44)
                TableColumn("Done") { Text(Format.percent($0.progress)).monospacedDigit() }
                    .width(52)
                TableColumn("Down") { Text(Format.speed($0.downloadSpeed)).monospacedDigit() }
                    .width(70)
                TableColumn("Up") { Text(Format.speed($0.uploadSpeed)).monospacedDigit() }
                    .width(70)
            }
        }
    }
}

private struct FilesTab: View {
    let d: Download
    @State private var edits: Set<Int>?
    private let state = AppState.shared

    private var current: Set<Int> { Set(d.files.filter(\.selected).map(\.index)) }
    private var chosen: Set<Int> { edits ?? current }
    private var canEdit: Bool { d.isTorrent && d.files.count > 1 && !d.isStopped }

    var body: some View {
        VStack(spacing: 0) {
            List(d.files) { f in
                HStack(spacing: 8) {
                    if canEdit {
                        Toggle("", isOn: Binding(
                            get: { chosen.contains(f.index) },
                            set: { on in
                                var set = chosen
                                if on { set.insert(f.index) } else { set.remove(f.index) }
                                edits = set == current ? nil : set
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    } else {
                        Image(systemName: f.selected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(f.selected ? Color.accentColor : .secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.name).lineLimit(1).truncationMode(.middle)
                        TransferProgressBar(fraction: f.fraction, tint: f.fraction >= 1 ? .green : .accentColor)
                    }
                    Text(Format.bytes(f.length))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
            .listStyle(.inset)

            if let edits {
                Divider()
                HStack {
                    Text("\(edits.count) of \(d.files.count) files selected")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revert") { self.edits = nil }
                    Button("Apply") {
                        state.setFileSelection(d, indexes: edits, thenResume: d.status != .paused)
                        self.edits = nil
                    }
                    .disabled(edits.isEmpty)
                }
                .controlSize(.small)
                .padding(8)
            }
        }
    }
}

private struct OptionsTab: View {
    let d: Download
    let options: [String: String]
    @State private var downKB = ""
    @State private var upKB = ""
    @State private var ratio = ""
    @State private var newTrackers = ""
    private let state = AppState.shared

    var body: some View {
        Form {
            Section("Speed Limits") {
                TextField("Download limit (KB/s, 0 = unlimited)", text: $downKB)
                TextField("Upload limit (KB/s, 0 = unlimited)", text: $upKB)
            }
            if d.isTorrent {
                Section("Seeding") {
                    TextField("Stop at ratio (0 = never)", text: $ratio)
                }
            }
            if d.isTorrent {
                Section("Add Trackers (one per line)") {
                    TextEditor(text: $newTrackers)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 54)
                        .scrollContentBackground(.hidden)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Apply") { apply() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: options) { _, _ in load() }
    }

    private func load() {
        downKB = kb(options["max-download-limit"])
        upKB = kb(options["max-upload-limit"])
        ratio = options["seed-ratio"] ?? "0"
    }

    private func kb(_ bytes: String?) -> String {
        guard let bytes, let n = Int(bytes) else { return "0" }
        return "\(n / 1024)"
    }

    private func apply() {
        var o: [String: String] = [:]
        if let n = Int(downKB) { o["max-download-limit"] = "\(n * 1024)" }
        if let n = Int(upKB) { o["max-upload-limit"] = "\(n * 1024)" }
        if d.isTorrent, Double(ratio) != nil { o["seed-ratio"] = ratio }
        state.setOptions(d.id, o)
        if d.isTorrent, !newTrackers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.addTrackers(d, newTrackers)
            newTrackers = ""
        }
    }
}
