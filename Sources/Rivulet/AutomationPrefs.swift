import AppKit
import RivuletCore
import SwiftUI

// MARK: - Sources: plugins and accounts

struct SourcesPrefs: View {
    private let auto = Automation.shared
    @AppStorage(PrefKey.watchClipboard) private var watchClipboard = false
    @AppStorage("pluginIndexURL") private var indexURL = ""
    @State private var updateMessage: String?
    @State private var host = ""
    @State private var user = ""
    @State private var password = ""
    @State private var note = ""

    var body: some View {
        Form {
            Section("Site Plugins") {
                if auto.plugins.isEmpty {
                    Text("No plugins loaded.").foregroundStyle(.secondary)
                }
                ForEach(auto.plugins) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                            Text(p.patterns.first ?? "").font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text("v\(p.version)  \(p.source)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(auto.pluginErrors, id: \.self) { e in
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Reload") { auto.reloadPlugins() }
                    Button("Open Plugins Folder") {
                        NSWorkspace.shared.open(Automation.userPluginDirectory)
                    }
                }
                TextField("Plugin index address (https)", text: $indexURL)
                HStack {
                    Button("Check for Plugin Updates") {
                        Task { updateMessage = await auto.updatePlugins(from: indexURL) }
                    }
                    .disabled(indexURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let m = updateMessage { Text(m).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Plugins are small scripts that turn a page link into direct file links. Updates are verified against a checksum before they are installed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Link Grabber") {
                Toggle("Open the Link Grabber when I copy a supported link", isOn: $watchClipboard)
            }

            Section("Accounts") {
                ForEach(auto.accounts) { a in
                    HStack {
                        Text(a.host)
                        Text(a.username).foregroundStyle(.secondary)
                        Spacer()
                        Button { auto.removeAccount(a.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                    }
                }
                TextField("Site (example.com)", text: $host)
                TextField("User name", text: $user)
                SecureField("Password", text: $password)
                HStack {
                    Button("Add Account") {
                        auto.addAccount(host: host, username: user, password: password, note: note)
                        if auto.accountError == nil { host = ""; user = ""; password = "" }
                    }
                    .disabled(host.isEmpty || user.isEmpty || password.isEmpty)
                    if let e = auto.accountError { Text(e).font(.caption).foregroundStyle(.red) }
                }
                Text("Passwords are stored in the macOS Keychain and are only given to plugins for the matching site.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Automation: rules and feeds

struct AutomationPrefs: View {
    private let auto = Automation.shared
    @State private var editingRule: RuleDraft?
    @State private var editingFeed: FeedDraft?

    var body: some View {
        Form {
            Section("When a Download Finishes") {
                if auto.rules.isEmpty {
                    Text("No rules. Rules run in order on every finished transfer.").foregroundStyle(.secondary)
                }
                ForEach(Bindable(auto).rules) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.enabled).labelsHidden()
                            .onChange(of: rule.enabled) { _, _ in auto.saveRules() }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.name)
                            Text(summary(of: rule)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Edit") { editingRule = RuleDraft(rule) }
                        Button { auto.rules.removeAll { $0.id == rule.id }; auto.saveRules() } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    Button("Add Rule") { editingRule = RuleDraft() }
                    Button("Add Examples") {
                        auto.rules.append(contentsOf: RuleDefaults.examples)
                        auto.saveRules()
                    }
                }
                Text("Torrents are treated as finished once they stop seeding, so their files are never moved while they are being shared.")
                    .font(.caption).foregroundStyle(.secondary)
                if !auto.ruleLog.isEmpty {
                    DisclosureGroup("Recent activity") {
                        ForEach(Array(auto.ruleLog.suffix(8).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).lineLimit(2)
                        }
                    }
                }
            }

            Section("Feeds") {
                if auto.feeds.isEmpty {
                    Text("No feeds. Subscribe to an RSS or Atom feed to download new items automatically.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Bindable(auto).feeds) { $feed in
                    HStack {
                        Toggle("", isOn: $feed.enabled).labelsHidden()
                            .onChange(of: feed.enabled) { _, _ in auto.saveFeeds() }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(feed.name)
                            Text(auto.feedStatus[feed.id] ?? feed.url).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Check Now") { auto.pollNow(feed, AppState.shared) }
                        Button("Edit") { editingFeed = FeedDraft(feed) }
                        Button { auto.feeds.removeAll { $0.id == feed.id }; auto.saveFeeds() } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.plain)
                    }
                }
                Button("Add Feed") { editingFeed = FeedDraft() }
                Text("The first check of a new feed only records what is already there. New items after that are downloaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editingRule) { draft in
            RuleEditor(draft: draft) { saved in
                if let i = auto.rules.firstIndex(where: { $0.id == saved.id }) { auto.rules[i] = saved } else { auto.rules.append(saved) }
                auto.saveRules()
            }
        }
        .sheet(item: $editingFeed) { draft in
            FeedEditor(draft: draft) { saved in
                if let i = auto.feeds.firstIndex(where: { $0.id == saved.id }) { auto.feeds[i] = saved } else { auto.feeds.append(saved) }
                auto.saveFeeds()
            }
        }
    }

    private func summary(of rule: Rule) -> String {
        rule.actions.map { a -> String in
            switch a {
            case .moveTo(let d): return "move to \(d)"
            case .rename(let t): return "rename \(t)"
            case .extractArchive: return "extract"
            case .open: return "open"
            case .revealInFinder: return "reveal"
            case .runShortcut(let n): return "shortcut \(n)"
            case .moveToTrash: return "trash"
            }
        }.joined(separator: ", ")
    }
}

/// Flat, form friendly view of a rule.
struct RuleDraft: Identifiable {
    var id = UUID()
    var name = "New Rule"
    var enabled = true
    var extensions = ""
    var nameRegex = ""
    var minMB = 0
    var torrentsOnly = false
    var hostContains = ""
    var rename = ""
    var extract = false
    var deleteArchive = false
    var intoSubfolder = true
    var moveTo = ""
    var shortcut = ""
    var open = false
    var reveal = false
    var trash = false

    init() {}

    init(_ r: Rule) {
        id = r.id; name = r.name; enabled = r.enabled
        for c in r.conditions {
            switch c {
            case .extensionIn(let e): extensions = e.joined(separator: ", ")
            case .nameMatches(let n): nameRegex = n
            case .largerThanMB(let m): minMB = m
            case .isTorrent(let t): torrentsOnly = t
            case .sourceHostContains(let h): hostContains = h
            case .smallerThanMB, .always: break
            }
        }
        for a in r.actions {
            switch a {
            case .rename(let t): rename = t
            case .extractArchive(let d, let s): extract = true; deleteArchive = d; intoSubfolder = s
            case .moveTo(let d): moveTo = d
            case .runShortcut(let n): shortcut = n
            case .open: open = true
            case .revealInFinder: reveal = true
            case .moveToTrash: trash = true
            }
        }
    }

    func rule() -> Rule {
        var conditions: [RuleCondition] = []
        let exts = extensions.split(whereSeparator: { ", ;".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ".", with: "") }.filter { !$0.isEmpty }
        if !exts.isEmpty { conditions.append(.extensionIn(exts)) }
        if !nameRegex.isEmpty { conditions.append(.nameMatches(nameRegex)) }
        if minMB > 0 { conditions.append(.largerThanMB(minMB)) }
        if torrentsOnly { conditions.append(.isTorrent(true)) }
        if !hostContains.isEmpty { conditions.append(.sourceHostContains(hostContains)) }
        if conditions.isEmpty { conditions = [.always] }

        var actions: [RuleAction] = []
        if !rename.isEmpty { actions.append(.rename(rename)) }
        if extract { actions.append(.extractArchive(deleteArchive: deleteArchive, intoSubfolder: intoSubfolder)) }
        if !moveTo.isEmpty { actions.append(.moveTo(moveTo)) }
        if !shortcut.isEmpty { actions.append(.runShortcut(shortcut)) }
        if open { actions.append(.open) }
        if reveal { actions.append(.revealInFinder) }
        if trash { actions.append(.moveToTrash) }
        return Rule(id: id, name: name, enabled: enabled, conditions: conditions, actions: actions)
    }
}

private struct RuleEditor: View {
    @State var draft: RuleDraft
    let onSave: (Rule) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section { TextField("Name", text: $draft.name) }
                Section("If the finished item matches all of these") {
                    TextField("File types (zip, dmg, mkv)", text: $draft.extensions)
                    TextField("Name matches (regular expression)", text: $draft.nameRegex)
                    Stepper("Larger than \(draft.minMB) MB (0 = any)", value: $draft.minMB, in: 0...100_000, step: 50)
                    Toggle("Torrents only", isOn: $draft.torrentsOnly)
                    TextField("Downloaded from site containing", text: $draft.hostContains)
                }
                Section("Then, in this order") {
                    TextField("Rename to ({name} {base} {ext} {date} {host})", text: $draft.rename)
                    Toggle("Extract archives", isOn: $draft.extract)
                    if draft.extract {
                        Toggle("Into a new folder", isOn: $draft.intoSubfolder).padding(.leading, 16)
                        Toggle("Move the archive to the Trash afterwards", isOn: $draft.deleteArchive).padding(.leading, 16)
                    }
                    HStack {
                        TextField("Move to folder", text: $draft.moveTo)
                        Button("Choose...") { chooseFolder() }
                    }
                    TextField("Run Shortcut named", text: $draft.shortcut)
                    Toggle("Open", isOn: $draft.open)
                    Toggle("Show in Finder", isOn: $draft.reveal)
                    Toggle("Move to Trash", isOn: $draft.trash)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft.rule()); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 480, height: 560)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { draft.moveTo = url.path }
    }
}

struct FeedDraft: Identifiable {
    var id = UUID()
    var name = ""
    var url = ""
    var interval = 30
    var include = ""
    var exclude = ""
    var minMB = 0
    var maxMB = 0
    var directory = ""
    var enabled = true

    init() {}
    init(_ f: FeedSubscription) {
        id = f.id; name = f.name; url = f.url; interval = f.intervalMinutes
        include = f.filter.includeRegex; exclude = f.filter.excludeRegex
        minMB = f.filter.minMB; maxMB = f.filter.maxMB
        directory = f.downloadDirectory ?? ""; enabled = f.enabled
    }

    func subscription() -> FeedSubscription {
        FeedSubscription(id: id, name: name, url: url.trimmingCharacters(in: .whitespaces),
                         intervalMinutes: max(5, interval),
                         filter: FeedFilter(includeRegex: include, excludeRegex: exclude, minMB: minMB, maxMB: maxMB),
                         enabled: enabled, downloadDirectory: directory.isEmpty ? nil : directory)
    }
}

private struct FeedEditor: View {
    @State var draft: FeedDraft
    let onSave: (FeedSubscription) -> Void
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool {
        guard let u = URL(string: draft.url.trimmingCharacters(in: .whitespaces)) else { return false }
        return ["http", "https"].contains(u.scheme) && !draft.name.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    TextField("Feed address", text: $draft.url)
                    Stepper("Check every \(draft.interval) minutes", value: $draft.interval, in: 5...1440, step: 5)
                }
                Section("Only download items that") {
                    TextField("Match (regular expression, empty = all)", text: $draft.include)
                    TextField("Do not match (regular expression)", text: $draft.exclude)
                    Stepper("At least \(draft.minMB) MB (0 = any)", value: $draft.minMB, in: 0...100_000, step: 50)
                    Stepper("At most \(draft.maxMB) MB (0 = any)", value: $draft.maxMB, in: 0...100_000, step: 50)
                }
                Section {
                    TextField("Save to folder (empty = default)", text: $draft.directory)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft.subscription()); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
            .padding(12)
        }
        .frame(width: 480, height: 520)
    }
}

// MARK: - Schedule

struct SchedulePrefs: View {
    private let auto = Automation.shared

    var body: some View {
        Form {
            Section("Speed Schedule") {
                if auto.schedule.isEmpty {
                    Text("No schedule. Add a window to limit speed or pause transfers at set times.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Bindable(auto).schedule) { $entry in
                    ScheduleRow(entry: $entry) {
                        auto.schedule.removeAll { $0.id == entry.id }
                        auto.saveSchedule()
                    } changed: { auto.saveSchedule() }
                }
                Button("Add Window") {
                    auto.schedule.append(ScheduleEntry(days: Set(1...7), startMinute: 9 * 60, endMinute: 17 * 60,
                                                       action: .alternateLimits))
                    auto.saveSchedule()
                }
                Text("Alternate limits use the speeds set in the Transfers tab. When a window ends, your normal settings come back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ScheduleRow: View {
    @Binding var entry: ScheduleEntry
    let remove: () -> Void
    let changed: () -> Void

    private let symbols = Calendar.current.veryShortWeekdaySymbols

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: $entry.enabled).labelsHidden()
                HStack(spacing: 2) {
                    ForEach(1...7, id: \.self) { d in
                        Button(symbols[d - 1]) {
                            if entry.days.contains(d) { entry.days.remove(d) } else { entry.days.insert(d) }
                        }
                        .buttonStyle(.bordered)
                        .tint(entry.days.contains(d) ? .accentColor : .secondary)
                        .controlSize(.small)
                    }
                }
                Spacer()
                Button(action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.plain)
            }
            HStack {
                DatePicker("From", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                DatePicker("to", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                Picker("", selection: kindBinding) {
                    Text("Alternate limits").tag(0)
                    Text("Custom limits").tag(1)
                    Text("Pause all").tag(2)
                }
                .labelsHidden().fixedSize()
            }
            if case .limits(let down, let up) = entry.action {
                HStack {
                    Text("Down KB/s")
                    TextField("", value: Binding(get: { down }, set: { entry.action = .limits(downKBps: $0, upKBps: up) }), format: .number)
                        .frame(width: 70)
                    Text("Up KB/s")
                    TextField("", value: Binding(get: { up }, set: { entry.action = .limits(downKBps: down, upKBps: $0) }), format: .number)
                        .frame(width: 70)
                }
            }
        }
        .onChange(of: entry) { _, _ in changed() }
    }

    private var kindBinding: Binding<Int> {
        Binding(
            get: {
                switch entry.action {
                case .alternateLimits: return 0
                case .limits: return 1
                case .pauseAll: return 2
                }
            },
            set: { k in
                entry.action = k == 0 ? .alternateLimits : (k == 1 ? .limits(downKBps: 500, upKBps: 100) : .pauseAll)
            }
        )
    }

    private func minuteBinding(_ key: WritableKeyPath<ScheduleEntry, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = entry[keyPath: key]
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                entry[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }
}
