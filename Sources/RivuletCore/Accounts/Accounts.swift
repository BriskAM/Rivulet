import Foundation
import Security

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain error \(status): \(msg)"
    }
}

/// Thin wrapper over generic-password Keychain items. Items are device-local
/// (no iCloud sync) and only available while the device is unlocked.
public final class KeychainStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    public func set(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        var status = SecItemUpdate(baseQuery(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func get(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct AccountRecord: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var host: String
    public var username: String
    public var note: String

    public init(id: UUID = UUID(), host: String, username: String, note: String = "") {
        self.id = id
        self.host = host
        self.username = username
        self.note = note
    }
}

/// Site logins: metadata in a JSON file (never passwords), passwords in the Keychain.
public final class AccountStore: @unchecked Sendable {
    private let keychain: KeychainStore
    private let metadataURL: URL
    private let lock = NSLock()

    public init(service: String = "app.rivulet.mac.accounts", metadataURL: URL) {
        self.keychain = KeychainStore(service: service)
        self.metadataURL = metadataURL
    }

    private func readRecords() -> [AccountRecord] {
        guard let data = try? Data(contentsOf: metadataURL) else { return [] }
        return (try? JSONDecoder().decode([AccountRecord].self, from: data)) ?? []
    }

    private func writeRecords(_ records: [AccountRecord]) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(records).write(to: metadataURL, options: .atomic)
    }

    public func list() -> [AccountRecord] {
        lock.lock(); defer { lock.unlock() }
        return readRecords()
    }

    public func add(_ record: AccountRecord, password: String) throws {
        lock.lock(); defer { lock.unlock() }
        var rec = record
        rec.host = Self.normalize(record.host)
        try keychain.set(password, account: rec.id.uuidString)
        var records = readRecords().filter { $0.id != rec.id }
        records.append(rec)
        do { try writeRecords(records) } catch {
            try? keychain.delete(account: rec.id.uuidString)
            throw error
        }
    }

    public func remove(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try keychain.delete(account: id.uuidString)
        try writeRecords(readRecords().filter { $0.id != id })
    }

    public func password(for id: UUID) -> String? {
        keychain.get(account: id.uuidString)
    }

    /// Finds credentials for a host, matching the exact host or a parent domain
    /// (a record for example.com serves cdn.example.com). The most specific record wins.
    public func credentials(forHost host: String) -> (username: String, password: String)? {
        let h = Self.normalize(host)
        guard !h.isEmpty else { return nil }
        let candidates = list()
            .filter { !$0.host.isEmpty && (h == $0.host || h.hasSuffix("." + $0.host)) }
            .sorted { $0.host.count > $1.host.count }
        for rec in candidates {
            if let pw = password(for: rec.id) { return (rec.username, pw) }
        }
        return nil
    }

    static func normalize(_ host: String) -> String {
        var h = host.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }
}
