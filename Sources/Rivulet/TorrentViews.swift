import AppKit
import RivuletCore
import SwiftUI

/// Sheet for choosing which files of a torrent to download, shown when a torrent is added,
/// when a magnet link finishes fetching its metadata, and from the context menu.
struct FilePickerSheet: View {
    let gid: String
    @Environment(\.dismiss) private var dismiss
    @State private var download: Download?
    @State private var selected: Set<Int> = []
    @State private var loaded = false
    @State private var attempts = 0
    private let state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let d = download, !d.files.isEmpty {
                HStack(spacing: 10) {
                    Image(nsImage: DownloadRow.icon(for: d)).resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text("\(d.files.count) files, \(Format.bytes(d.files.reduce(0) { $0 + $1.length })) in total")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Select All") { selected = Set(d.files.map(\.index)) }
                    Button("Select None") { selected = [] }
                    Spacer()
                    Text("\(selected.count) selected, \(Format.bytes(selectedBytes(d)))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .controlSize(.small)

                List(d.files) { f in
                    Toggle(isOn: Binding(
                        get: { selected.contains(f.index) },
                        set: { on in if on { selected.insert(f.index) } else { selected.remove(f.index) } }
                    )) {
                        HStack {
                            Text(relativePath(f, in: d)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Format.bytes(f.length)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                }
                .listStyle(.inset)
                .frame(minHeight: 200)

                HStack {
                    Button("Cancel and Remove", role: .destructive) {
                        state.cancelPending(gid)
                        close()
                    }
                    Spacer()
                    if d.status == .paused {
                        Button("Add Paused") { apply(d, resume: false) }
                    }
                    Button(d.status == .paused ? "Start" : "Apply") { apply(d, resume: true) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected.isEmpty)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(attempts > 15 ? "Could not read the file list." : "Reading the file list...")
                        .foregroundStyle(.secondary)
                    if attempts > 15 { Button("Close") { close() } }
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .padding(18)
        .frame(width: 520)
        .task {
            while !Task.isCancelled && !loaded {
                if let d = await state.detail(gid), !d.files.isEmpty {
                    download = d
                    selected = Set(d.files.filter(\.selected).map(\.index))
                    loaded = true
                } else {
                    attempts += 1
                    try? await Task.sleep(for: .seconds(1))
                    if attempts > 15 { break }
                }
            }
        }
    }

    private func close() {
        state.pickerGID = nil
        dismiss()
    }

    private func apply(_ d: Download, resume: Bool) {
        state.setFileSelection(d, indexes: selected, thenResume: resume)
        close()
    }

    private func selectedBytes(_ d: Download) -> Int64 {
        d.files.filter { selected.contains($0.index) }.reduce(0) { $0 + $1.length }
    }

    private func relativePath(_ f: DownloadFile, in d: Download) -> String {
        var p = f.path
        let prefix = d.dir.hasSuffix("/") ? d.dir : d.dir + "/"
        if p.hasPrefix(prefix) { p.removeFirst(prefix.count) }
        let top = d.name + "/"
        if p.hasPrefix(top) { p.removeFirst(top.count) }
        return p.isEmpty ? f.name : p
    }
}

/// A strip showing which pieces of a torrent have been downloaded.
struct PieceMapView: View {
    let cells: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard !cells.isEmpty else { return }
            let cols = min(cells.count, max(1, Int(size.width / 4)))
            let rows = Int(ceil(Double(cells.count) / Double(cols)))
            let cw = size.width / CGFloat(cols)
            let ch = min(size.height / CGFloat(rows), 10)
            for (i, v) in cells.enumerated() {
                let r = CGRect(x: CGFloat(i % cols) * cw, y: CGFloat(i / cols) * ch, width: cw - 0.5, height: ch - 0.5)
                ctx.fill(Path(r), with: .color(v >= 0.999 ? .accentColor : (v > 0 ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.12))))
            }
        }
        .frame(height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
