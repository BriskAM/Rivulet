import Foundation

struct RuleError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// Applies post-download rules. Actions run in order; each action updates the
/// working paths used by the next one. Existing files are never overwritten.
public final class RuleEngine: @unchecked Sendable {
    private let trash: (URL) throws -> Void
    /// Timeout for external processes (extraction, shortcuts).
    var processTimeout: TimeInterval = 600

    public init() {
        self.trash = { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
    }

    init(trash: @escaping (URL) throws -> Void) {
        self.trash = trash
    }

    // MARK: Matching

    public static func matches(_ rule: Rule, _ item: CompletedItem) -> Bool {
        guard !rule.conditions.isEmpty else { return false }
        return rule.conditions.allSatisfy { matches($0, item) }
    }

    static func matches(_ cond: RuleCondition, _ item: CompletedItem) -> Bool {
        switch cond {
        case .always:
            return true
        case .extensionIn(let exts):
            let wanted = Set(exts.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) })
            var candidates = [(item.name as NSString).pathExtension.lowercased()]
            candidates += item.paths.map { ($0 as NSString).pathExtension.lowercased() }
            return candidates.contains { !$0.isEmpty && wanted.contains($0) }
        case .nameMatches(let pattern):
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            let range = NSRange(item.name.startIndex..., in: item.name)
            return re.firstMatch(in: item.name, options: [], range: range) != nil
        case .largerThanMB(let mb):
            return item.totalBytes > Int64(mb) * 1_048_576
        case .smallerThanMB(let mb):
            return item.totalBytes < Int64(mb) * 1_048_576
        case .isTorrent(let flag):
            return item.isTorrent == flag
        case .sourceHostContains(let s):
            guard let host = item.sourceHost?.lowercased(), !s.isEmpty else { return false }
            return host.contains(s.lowercased())
        }
    }

    // MARK: Apply

    public func apply(_ rules: [Rule], to item: CompletedItem) async -> (finalPaths: [String], results: [ActionResult]) {
        var current = item
        var results: [ActionResult] = []
        for rule in rules where rule.enabled {
            guard Self.matches(rule, current) else { continue }
            for action in rule.actions {
                let result = await run(action, rule: rule, item: &current)
                results.append(result)
                if !result.success { break }
            }
            if rule.stopProcessing { break }
        }
        return (current.paths, results)
    }

    private func refresh(_ item: inout CompletedItem) {
        if item.paths.count == 1 { item.name = (item.paths[0] as NSString).lastPathComponent }
        if let first = item.paths.first { item.directory = (first as NSString).deletingLastPathComponent }
    }

    private func run(_ action: RuleAction, rule: Rule, item: inout CompletedItem) async -> ActionResult {
        func ok(_ name: String, _ detail: String) -> ActionResult {
            ActionResult(ruleName: rule.name, action: name, success: true, detail: detail)
        }
        func fail(_ name: String, _ error: Error) -> ActionResult {
            ActionResult(ruleName: rule.name, action: name, success: false, detail: "\(error)")
        }
        switch action {
        case .moveTo(let dir):
            do {
                item.paths = try move(item.paths, toDirectory: dir)
                refresh(&item)
                return ok("moveTo", "moved to \(item.directory)")
            } catch { return fail("moveTo", error) }

        case .rename(let template):
            do {
                item.paths = try rename(item.paths, template: template, item: item)
                refresh(&item)
                return ok("rename", item.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
            } catch { return fail("rename", error) }

        case .extractArchive(let deleteArchive, let intoSubfolder):
            var newPaths: [String] = []
            var notes: [String] = []
            var failure: Error?
            for path in item.paths {
                guard let kind = ArchiveKind(path: path) else { newPaths.append(path); continue }
                if failure != nil { newPaths.append(path); continue }
                do {
                    let out = try await extract(URL(fileURLWithPath: path), kind: kind, intoSubfolder: intoSubfolder)
                    newPaths += out
                    notes.append("extracted \((path as NSString).lastPathComponent)")
                    if deleteArchive {
                        do { try trash(URL(fileURLWithPath: path)) } catch {
                            failure = RuleError("extracted but could not trash archive: \(error)")
                        }
                    }
                } catch {
                    failure = error
                    newPaths.append(path)
                }
            }
            item.paths = newPaths
            refresh(&item)
            if let failure { return fail("extractArchive", failure) }
            return ok("extractArchive", notes.isEmpty ? "nothing to extract" : notes.joined(separator: "; "))

        case .open:
            return await openPaths(item.paths, reveal: false, rule: rule)

        case .revealInFinder:
            return await openPaths(item.paths, reveal: true, rule: rule)

        case .runShortcut(let name):
            do {
                try await runShortcut(name, paths: item.paths)
                return ok("runShortcut", "ran \(name)")
            } catch { return fail("runShortcut", error) }

        case .moveToTrash:
            do {
                for p in item.paths { try trash(URL(fileURLWithPath: p)) }
                let n = item.paths.count
                item.paths = []
                return ok("moveToTrash", "trashed \(n) item(s)")
            } catch { return fail("moveToTrash", error) }
        }
    }

    // MARK: Move / rename

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        func exists(_ u: URL) -> Bool { (try? fm.attributesOfItem(atPath: u.path)) != nil }
        if !exists(url) { return url }
        var ext = url.pathExtension
        var base = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        if base.lowercased().hasSuffix(".tar") && !ext.isEmpty {
            ext = "tar." + ext
            base = String(base.dropLast(4))
        }
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    private func sameDirectory(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    func move(_ paths: [String], toDirectory template: String) throws -> [String] {
        let fm = FileManager.default
        let expanded = (template as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw RuleError("destination must be an absolute path") }
        if expanded.split(separator: "/").contains("..") { throw RuleError("destination contains path traversal") }
        let destDir = URL(fileURLWithPath: expanded).standardizedFileURL
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        var out: [String] = []
        for p in paths {
            let src = URL(fileURLWithPath: p)
            guard (try? fm.attributesOfItem(atPath: src.path)) != nil else { throw RuleError("missing: \(p)") }
            if sameDirectory(src.deletingLastPathComponent(), destDir) { out.append(p); continue }
            let srcReal = src.resolvingSymlinksInPath().path
            if destDir.resolvingSymlinksInPath().path.hasPrefix(srcReal + "/") {
                throw RuleError("cannot move a folder into itself")
            }
            let dest = Self.uniqueURL(destDir.appendingPathComponent(src.lastPathComponent))
            try fm.moveItem(at: src, to: dest)
            out.append(dest.path)
        }
        return out
    }

    /// Expands a rename template into a plain file name (never a path).
    static func expandTemplate(_ template: String, path: String, item: CompletedItem, now: Date = Date()) throws -> String {
        let name = (path as NSString).lastPathComponent
        var ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        if base.lowercased().hasSuffix(".tar") && !ext.isEmpty {
            ext = "tar." + ext
            base = String(base.dropLast(4))
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let values: [String: String] = [
            "name": name, "base": base, "ext": ext,
            "date": df.string(from: now), "host": item.sourceHost ?? "",
        ]
        var result = ""
        var i = template.startIndex
        while i < template.endIndex {
            let ch = template[i]
            if ch == "{", let close = template[i...].firstIndex(of: "}") {
                let key = String(template[template.index(after: i)..<close])
                if let v = values[key] {
                    result += v
                    i = template.index(after: close)
                    continue
                }
            }
            result.append(ch)
            i = template.index(after: i)
        }
        // Plain file name only: strip separators and control characters.
        result = String(result.unicodeScalars.filter { $0 != "/" && $0.value >= 32 && $0.value != 127 })
        result = result.trimmingCharacters(in: .whitespaces)
        if ext.isEmpty && result.hasSuffix(".") { result.removeLast() }
        if result.isEmpty || result == "." || result == ".." { throw RuleError("rename template produced an invalid name") }
        if result.utf8.count > 255 { throw RuleError("rename result too long") }
        return result
    }

    func rename(_ paths: [String], template: String, item: CompletedItem) throws -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for p in paths {
            let src = URL(fileURLWithPath: p)
            guard (try? fm.attributesOfItem(atPath: src.path)) != nil else { throw RuleError("missing: \(p)") }
            let newName = try Self.expandTemplate(template, path: p, item: item)
            if newName == src.lastPathComponent { out.append(p); continue }
            var dest = src.deletingLastPathComponent().appendingPathComponent(newName)
            let caseOnly = dest.path.lowercased() == src.path.lowercased()
            if !caseOnly { dest = Self.uniqueURL(dest) }
            try fm.moveItem(at: src, to: dest)
            out.append(dest.path)
        }
        return out
    }

    // MARK: Open / shortcuts

    private func openPaths(_ paths: [String], reveal: Bool, rule: Rule) async -> ActionResult {
        let name = reveal ? "revealInFinder" : "open"
        guard !paths.isEmpty else {
            return ActionResult(ruleName: rule.name, action: name, success: false, detail: "no files")
        }
        let args = (reveal ? ["-R"] : []) + paths
        let out = await runProcess("/usr/bin/open", args, timeout: 30)
        return ActionResult(ruleName: rule.name, action: name, success: out.status == 0, detail: out.status == 0 ? "ok" : out.stderr)
    }

    private func runShortcut(_ name: String, paths: [String]) async throws {
        guard !name.isEmpty, !name.hasPrefix("-") else { throw RuleError("invalid shortcut name") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rivulet-shortcut-\(UUID().uuidString).txt")
        try paths.joined(separator: "\n").write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let out = await runProcess("/usr/bin/shortcuts", ["run", name, "--input-path", tmp.path], timeout: processTimeout)
        if out.timedOut { throw RuleError("shortcut timed out") }
        if out.status != 0 { throw RuleError("shortcut failed: \(out.stderr)") }
    }

    // MARK: Extraction

    enum ArchiveKind {
        case zip, other
        init?(path: String) {
            let n = path.lowercased()
            let tar = [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz", ".7z", ".rar"]
            if n.hasSuffix(".zip") { self = .zip }
            else if tar.contains(where: { n.hasSuffix($0) }) { self = .other }
            else { return nil }
        }
    }

    static func archiveBaseName(_ name: String) -> String {
        let lower = name.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".tbz", ".txz", ".tar", ".zip", ".7z", ".rar"] where lower.hasSuffix(suffix) {
            let base = String(name.dropLast(suffix.count))
            return base.isEmpty ? "Extracted" : base
        }
        return name
    }

    private func extract(_ archive: URL, kind: ArchiveKind, intoSubfolder: Bool) async throws -> [String] {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: archive.path)) != nil else { throw RuleError("missing archive") }
        let parent = archive.deletingLastPathComponent()

        // Preflight: refuse entry names that could escape.
        let listing = await runProcess("/usr/bin/bsdtar", ["-tf", archive.path], timeout: processTimeout)
        if listing.timedOut { throw RuleError("archive listing timed out") }
        guard listing.status == 0 else { throw RuleError("cannot read archive: \(listing.stderr)") }
        for line in listing.stdout.split(whereSeparator: { $0 == "\n" }) {
            let entry = String(line)
            if entry.hasPrefix("/") || entry.contains("\0") || entry.split(separator: "/").contains("..") || entry.contains("\\..\\") {
                throw RuleError("unsafe archive entry rejected: \(entry)")
            }
        }

        let temp = parent.appendingPathComponent(".rivulet-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) }

        let result: ProcessOutput
        switch kind {
        case .zip:
            result = await runProcess("/usr/bin/ditto", ["-x", "-k", archive.path, temp.path], timeout: processTimeout)
        case .other:
            result = await runProcess("/usr/bin/bsdtar", ["-xf", archive.path, "-C", temp.path, "--no-same-owner"], timeout: processTimeout)
        }
        if result.timedOut { throw RuleError("extraction timed out") }
        guard result.status == 0 else { throw RuleError("extraction failed: \(result.stderr)") }

        try Self.verifyContained(temp)

        let children = try fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil, options: [])
        guard !children.isEmpty else { throw RuleError("archive is empty") }

        if intoSubfolder {
            let name = Self.archiveBaseName(archive.lastPathComponent)
            let dest = Self.uniqueURL(parent.appendingPathComponent(name))
            try fm.moveItem(at: temp, to: dest)
            return [dest.path]
        }
        var out: [String] = []
        for child in children {
            let dest = Self.uniqueURL(parent.appendingPathComponent(child.lastPathComponent))
            try fm.moveItem(at: child, to: dest)
            out.append(dest.path)
        }
        return out
    }

    /// Every extracted item must live inside `root`; symlinks must resolve inside it too.
    static func verifyContained(_ root: URL) throws {
        let fm = FileManager.default
        let rootReal = root.resolvingSymlinksInPath().path
        func inside(_ path: String) -> Bool { path == rootReal || path.hasPrefix(rootReal + "/") }
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
            throw RuleError("cannot inspect extracted files")
        }
        for case let url as URL in e {
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if isLink {
                let target = try fm.destinationOfSymbolicLink(atPath: url.path)
                let resolved = target.hasPrefix("/")
                    ? URL(fileURLWithPath: target)
                    : url.deletingLastPathComponent().appendingPathComponent(target)
                if !inside(resolved.resolvingSymlinksInPath().path) {
                    throw RuleError("symlink escapes extraction folder: \(url.lastPathComponent)")
                }
            } else if !inside(url.resolvingSymlinksInPath().path) {
                throw RuleError("extracted path escapes extraction folder")
            }
        }
    }
}

// MARK: Process helper

struct ProcessOutput {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Runs an executable with an argument array (never a shell). Output goes to temp files
/// so large output cannot deadlock a pipe.
func runProcess(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> ProcessOutput {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("rivulet-proc-\(UUID().uuidString)")
    let outURL = base.appendingPathExtension("out")
    let errURL = base.appendingPathExtension("err")
    fm.createFile(atPath: outURL.path, contents: nil)
    fm.createFile(atPath: errURL.path, contents: nil)
    defer { try? fm.removeItem(at: outURL); try? fm.removeItem(at: errURL) }
    guard let outH = try? FileHandle(forWritingTo: outURL), let errH = try? FileHandle(forWritingTo: errURL) else {
        return ProcessOutput(status: -1, stdout: "", stderr: "cannot create output files", timedOut: false)
    }
    let flag = TimeoutFlag()
    let status: Int32 = await withCheckedContinuation { cont in
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = outH
            p.standardError = errH
            do { try p.run() } catch {
                cont.resume(returning: -1)
                return
            }
            let work = DispatchWorkItem { if p.isRunning { flag.set(); p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
            p.waitUntilExit()
            work.cancel()
            cont.resume(returning: p.terminationStatus)
        }
    }
    try? outH.close()
    try? errH.close()
    let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
    let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
    return ProcessOutput(status: status, stdout: out, stderr: err.trimmingCharacters(in: .whitespacesAndNewlines), timedOut: flag.isSet)
}
