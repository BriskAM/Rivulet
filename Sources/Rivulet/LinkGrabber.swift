import AppKit
import Foundation
import Observation
import RivuletCore
import SwiftUI

struct GrabItem: Identifiable {
    var link: ResolvedLink
    var selected = true
    var id: UUID { link.id }
    var displayName: String {
        if let n = link.fileName, !n.isEmpty { return n }
        if let u = URL(string: link.url), !u.lastPathComponent.isEmpty, u.lastPathComponent != "/" {
            return u.lastPathComponent.removingPercentEncoding ?? u.lastPathComponent
        }
        return link.url
    }
}

struct GrabPackage: Identifiable {
    let id = UUID()
    var name: String
    var pluginID: String
    var items: [GrabItem]
    var expanded = true
}

/// Staging area modelled on JDownloader's link grabber: paste pages, see the files they expand to,
/// check which are online, pick what to download.
@MainActor
@Observable
final class LinkGrabber {
    var input = ""
    var packages: [GrabPackage] = []
    var resolving = false
    var message: String?
    var hideOffline = false
    var useYtDlp = UserDefaults.standard.bool(forKey: PrefKey.grabberUseYtDlp)
    var createFolders = true
    var startPaused = false
    var destination = Prefs.downloadDir

    private var task: Task<Void, Never>?

    var allItems: [GrabItem] { packages.flatMap(\.items) }
    var selectedItems: [GrabItem] { allItems.filter(\.selected) }
    var ytDlpAvailable: Bool { YtDlpResolver.locate() != nil }

    func startResolve() {
        task?.cancel()
        let text = input
        let ytdlp = useYtDlp
        UserDefaults.standard.set(ytdlp, forKey: PrefKey.grabberUseYtDlp)
        task = Task { await resolve(text, useYtDlp: ytdlp) }
    }

    func clear() {
        task?.cancel()
        packages = []
        message = nil
        resolving = false
    }

    private func resolve(_ text: String, useYtDlp: Bool) async {
        let engine = Automation.shared.resolver
        guard !ResolverEngine.extractURLs(from: text).isEmpty || text.lowercased().contains("magnet:") else {
            message = "No links found in the text."
            return
        }
        resolving = true
        message = "Analyzing links..."
        let results = await engine.resolve(text, useYtDlpFallback: useYtDlp)
        if Task.isCancelled { return }

        var added = 0
        for r in results where !r.links.isEmpty {
            let name = r.packageName?.trimmingCharacters(in: .whitespaces)
            packages.append(GrabPackage(
                name: (name?.isEmpty == false ? name! : defaultName(for: r)),
                pluginID: r.pluginID,
                items: r.links.map { GrabItem(link: $0) }
            ))
            added += r.links.count
        }
        input = ""
        message = added == 0 ? "Nothing could be found at those links." : nil
        resolving = false
        await checkOnline()
    }

    private func defaultName(for r: ResolveResult) -> String {
        if let host = r.links.first.flatMap({ URL(string: $0.sourceURL)?.host }) { return host }
        return "Links"
    }

    /// Fills in size, file name and online or offline for every link that has not been checked.
    func checkOnline() async {
        let engine = Automation.shared.resolver
        let pending = allItems.map(\.link).filter { $0.status == .unknown && $0.url.lowercased().hasPrefix("http") }
        guard !pending.isEmpty else { return }
        message = "Checking \(pending.count) links..."
        let checked = await engine.checkOnline(pending)
        let byID = Dictionary(uniqueKeysWithValues: checked.map { ($0.id, $0) })
        for p in packages.indices {
            for i in packages[p].items.indices {
                if let updated = byID[packages[p].items[i].id] {
                    packages[p].items[i].link = updated
                    if updated.status == .offline { packages[p].items[i].selected = false }
                }
            }
        }
        message = nil
    }

    func setAll(_ on: Bool, in package: UUID? = nil) {
        for p in packages.indices where package == nil || packages[p].id == package {
            for i in packages[p].items.indices { packages[p].items[i].selected = on }
        }
    }

    func remove(_ packageID: UUID) { packages.removeAll { $0.id == packageID } }

    // MARK: Sending

    func addSelectedToDownloads(_ state: AppState) {
        let multi = packages.filter { $0.items.contains(where: \.selected) }
        guard !multi.isEmpty else { return }
        let base = destination
        let folders = createFolders
        let paused = startPaused
        let jobs: [(String, [GrabItem])] = multi.map { pkg in
            let selected = pkg.items.filter(\.selected)
            let usePackageFolder = folders && selected.count > 1 && !pkg.name.isEmpty
            let dir = usePackageFolder ? (base as NSString).appendingPathComponent(Self.safeFolderName(pkg.name)) : base
            return (dir, selected)
        }
        let engine = Automation.shared.resolver
        state.perform { client in
            for (dir, items) in jobs {
                for listed in items {
                    // Entries that are still page links (listed albums) are resolved now, when the signed link is fresh.
                    var item = listed
                    if let u = URL(string: listed.link.url), engine.plugin(matching: u) != nil {
                        let resolved = await engine.resolve(listed.link.url).flatMap(\.links)
                        guard var first = resolved.first, first.status != .offline, first.url != listed.link.url else { continue }
                        if first.fileName == nil { first.fileName = listed.link.fileName }
                        item.link = first
                    }
                    var options: [String: Any] = ["dir": dir]
                    if paused { options["pause"] = "true" }
                    if let name = item.link.fileName, Self.isPlainName(name) { options["out"] = name }
                    if !item.link.headers.isEmpty {
                        options["header"] = item.link.headers.map { "\($0.key): \($0.value)" }
                    }
                    try await client.addURIs([item.link.url], rawOptions: options)
                }
            }
        }
        packages.removeAll { pkg in multi.contains(where: { $0.id == pkg.id }) }
    }

    static func isPlainName(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\\") && !s.contains("\0")
    }

    static func safeFolderName(_ s: String) -> String {
        var out = s.map { "/\\:*?\"<>|\0".contains($0) ? "_" : String($0) }.joined()
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return String(out.prefix(120)).isEmpty ? "Package" : String(out.prefix(120))
    }
}

struct LinkGrabberView: View {
    private let grabber = Automation.shared.grabber
    private let state = AppState.shared

    var body: some View {
        @Bindable var g = grabber
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Paste links or text containing links", text: $g.input, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { g.startResolve() }
                Button("Analyze") { g.startResolve() }
                    .disabled(g.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || g.resolving)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(10)

            HStack(spacing: 12) {
                Toggle("Use yt-dlp for sites without a plugin", isOn: $g.useYtDlp)
                    .disabled(!g.ytDlpAvailable)
                    .help(g.ytDlpAvailable ? "" : "Install yt-dlp with Homebrew to enable this.")
                Toggle("Hide offline", isOn: $g.hideOffline)
                Spacer()
                if g.resolving { ProgressView().controlSize(.small) }
                if let m = g.message { Text(m).foregroundStyle(.secondary) }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()

            if g.packages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
                    Text("No links yet").font(.headline)
                    Text("Paste a page, album or folder link. Rivulet finds the files, checks that they are online and lets you pick.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach($g.packages) { $pkg in
                        Section {
                            if pkg.expanded {
                                ForEach($pkg.items) { $item in
                                    if !(g.hideOffline && item.link.status == .offline) {
                                        GrabRow(item: $item)
                                    }
                                }
                            }
                        } header: {
                            PackageHeader(package: $pkg, grabber: g)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack(spacing: 10) {
                Text(g.destination).lineLimit(1).truncationMode(.middle)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: 200, alignment: .leading)
                Button("Choose...") { chooseFolder(g) }.controlSize(.small)
                Toggle("Package folders", isOn: $g.createFolders).font(.system(size: 11))
                Toggle("Start paused", isOn: $g.startPaused).font(.system(size: 11))
                Spacer()
                Button("Clear") { g.clear() }.disabled(g.packages.isEmpty)
                Button("Add \(g.selectedItems.count) to Downloads") { g.addSelectedToDownloads(state) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(g.selectedItems.isEmpty)
            }
            .padding(10)
        }
        .frame(minWidth: 620, minHeight: 420)
        .navigationTitle("Link Grabber")
        .dropDestination(for: String.self) { strings, _ in
            g.input = strings.joined(separator: "\n")
            g.startResolve()
            return true
        }
        .dropDestination(for: URL.self) { urls, _ in
            g.input = urls.map(\.absoluteString).joined(separator: "\n")
            g.startResolve()
            return !urls.isEmpty
        }
    }

    private func chooseFolder(_ g: LinkGrabber) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: g.destination)
        if panel.runModal() == .OK, let url = panel.url { g.destination = url.path }
    }
}

private struct PackageHeader: View {
    @Binding var package: GrabPackage
    let grabber: LinkGrabber

    var body: some View {
        HStack(spacing: 8) {
            Button { package.expanded.toggle() } label: {
                Image(systemName: package.expanded ? "chevron.down" : "chevron.right").frame(width: 12)
            }
            .buttonStyle(.plain)
            Image(systemName: "shippingbox")
            Text(package.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text("\(package.items.count) \(package.items.count == 1 ? "file" : "files") - \(package.pluginID)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("All") { grabber.setAll(true, in: package.id) }.controlSize(.small)
            Button("None") { grabber.setAll(false, in: package.id) }.controlSize(.small)
            Button { grabber.remove(package.id) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain)
        }
        .textCase(nil)
    }
}

private struct GrabRow: View {
    @Binding var item: GrabItem

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $item.selected).toggleStyle(.checkbox).labelsHidden()
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .help(statusHelp)
            Text(item.displayName).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let size = item.link.size {
                Text(Format.bytes(size)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.system(size: 12))
        .opacity(item.link.status == .offline ? 0.55 : 1)
    }

    private var statusSymbol: String {
        switch item.link.status {
        case .online: return "checkmark.circle.fill"
        case .offline: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch item.link.status {
        case .online: return .green
        case .offline: return .red
        case .unknown: return .secondary
        }
    }

    private var statusHelp: String {
        switch item.link.status {
        case .online: return "Online"
        case .offline: return "Offline or not found"
        case .unknown: return "Not checked"
        }
    }
}
