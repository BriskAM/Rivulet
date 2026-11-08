import AppKit
import RivuletCore
import SwiftUI
import UniformTypeIdentifiers

/// A single transfer, laid out like a Transmission row.
struct DownloadRow: View {
    let download: Download
    let isSelected: Bool
    @Environment(\.openWindow) private var openWindow
    private let state = AppState.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: Self.icon(for: download))
                .resizable()
                .interpolation(.high)
                .frame(width: 38, height: 38)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(download.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(progressLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    TransferProgressBar(fraction: download.fraction, tint: tint, emphasized: isSelected)
                    RowButton(symbol: download.status == .paused || download.status == .error ? "play.circle.fill" : "pause.circle.fill",
                              help: download.status == .paused ? "Resume" : (download.status == .error ? "Retry" : "Pause")) {
                        if download.status == .paused || download.status == .error {
                            state.resume([download])
                        } else {
                            state.pause([download])
                        }
                    }
                    .disabled(download.status == .complete)
                    RowButton(symbol: "magnifyingglass.circle.fill", help: "Show in Finder") {
                        state.reveal(download)
                    }
                }

                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 5)
        .opacity(download.status == .paused ? 0.7 : 1)
        .contentShape(Rectangle())
    }

    // MARK: Text

    private var progressLine: String {
        let done = Format.bytes(download.completedLength)
        let total = Format.bytes(download.totalLength)
        if download.isSeeding || (download.isDone && download.isTorrent) {
            return "\(total), uploaded \(Format.bytes(download.uploadLength)) (Ratio: \(Format.ratio(download.ratio)))"
        }
        if download.status == .complete {
            return "\(total) - Complete"
        }
        if download.totalLength == 0 {
            return download.status == .active ? "Starting" : "Size unknown"
        }
        var line = "\(done) of \(total) (\(Format.percent(download.fraction)))"
        if download.status == .active {
            line += " - \(Format.eta(download.eta))"
        }
        return line
    }

    private var statusLine: String {
        let dl = Format.speed(download.downloadSpeed)
        let ul = Format.speed(download.uploadSpeed)
        switch download.status {
        case .active:
            if download.verifyPending { return "Waiting to verify" }
            if download.isSeeding {
                return "Seeding to \(download.connections) \(download.connections == 1 ? "peer" : "peers") - UL: \(ul)"
            }
            if download.isTorrent {
                return "Downloading from \(download.numSeeders) of \(download.connections) peers - DL: \(dl), UL: \(ul)"
            }
            let n = download.connections
            return "Downloading from \(n) \(n == 1 ? "connection" : "connections") - DL: \(dl)"
        case .waiting: return "Waiting in queue"
        case .paused: return "Paused"
        case .error: return download.errorMessage ?? "Error"
        case .complete: return "Complete"
        case .removed: return "Removed"
        case .unknown: return ""
        }
    }

    private var tint: Color {
        switch download.status {
        case .error: return .red
        case .paused, .waiting: return .gray
        case .complete: return .green
        default: return download.isSeeding ? .green : .accentColor
        }
    }

    // MARK: Icon

    static func icon(for d: Download) -> NSImage {
        if d.files.count > 1 { return NSWorkspace.shared.icon(for: .folder) }
        let fileName = d.files.first?.name ?? d.name
        let ext = (fileName as NSString).pathExtension
        if ext.isEmpty { return NSWorkspace.shared.icon(for: .data) }
        return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
    }
}

struct TransferProgressBar: View {
    let fraction: Double
    let tint: Color
    var emphasized = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(emphasized ? Color.white.opacity(0.9) : tint)
                    .frame(width: max(fraction > 0 ? 6 : 0, geo.size.width * fraction))
            }
        }
        .frame(height: 8)
    }
}

struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .symbolRenderingMode(.hierarchical)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
