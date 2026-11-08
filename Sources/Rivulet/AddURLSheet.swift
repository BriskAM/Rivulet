import AppKit
import RivuletCore
import SwiftUI

struct AddURLSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var destination = Prefs.downloadDir
    @State private var startPaused = false
    private let state = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Links").font(.headline)
                    Text("Web addresses, magnet links and torrent URLs. One per line.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))

            HStack {
                Text("Destination").foregroundStyle(.secondary)
                Text(destination)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose...") { chooseFolder() }
            }
            .font(.system(size: 12))

            Toggle("Start paused", isOn: $startPaused)
                .font(.system(size: 12))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    var options = ["dir": destination]
                    if startPaused { options["pause"] = "true" }
                    state.addURIs(text, options: options)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear(perform: prefillFromClipboard)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: destination)
        if panel.runModal() == .OK, let url = panel.url { destination = url.path }
    }

    private func prefillFromClipboard() {
        guard text.isEmpty, let clip = NSPasteboard.general.string(forType: .string) else { return }
        let lines = clip.split(whereSeparator: \.isNewline).map(String.init)
        let looksLikeLinks = !lines.isEmpty && lines.allSatisfy {
            let l = $0.lowercased()
            return l.hasPrefix("http://") || l.hasPrefix("https://") || l.hasPrefix("magnet:") || l.hasPrefix("ftp://")
        }
        if looksLikeLinks { text = clip }
    }
}
