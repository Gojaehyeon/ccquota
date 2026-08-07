import Foundation

/// Per-account credential snapshots, kept outside the Keychain so that all three
/// accounts can be polled while only one of them is the live login.
///
/// This file holds refresh tokens, so it is created 0600 in the user's home —
/// the same posture Claude Code itself uses for `~/.claude/.credentials.json`
/// on Linux and Windows.
public struct AccountStore: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var label: String
        public var blob: CredentialBlob
        /// Set from the account's plan so the UI can label a Max 20x vs a Pro.
        public var tier: String?
        /// Stable account identity from `/api/oauth/profile`. Tokens rotate, so
        /// this is the only safe key for "is this the same account".
        public var accountUUID: String?
        public var email: String?

        public init(label: String, blob: CredentialBlob, tier: String?,
                    accountUUID: String? = nil, email: String? = nil) {
            self.label = label
            self.blob = blob
            self.tier = tier
            self.accountUUID = accountUUID
            self.email = email
        }
    }

    /// Labels that resolve to the same underlying Claude account. Two entries
    /// for one account refresh independently and invalidate each other's tokens,
    /// which surfaces as both of them returning 401.
    public var duplicateGroups: [[String]] {
        Dictionary(grouping: accounts.compactMap { entry in
            entry.accountUUID.map { ($0, entry.label) }
        }, by: \.0)
        .values
        .map { $0.map(\.1) }
        .filter { $0.count > 1 }
    }

    public var active: String?
    public var accounts: [Entry]

    public init(active: String? = nil, accounts: [Entry] = []) {
        self.active = active
        self.accounts = accounts
    }

    public subscript(label: String) -> Entry? {
        get { accounts.first { $0.label == label } }
        set {
            guard let newValue else {
                accounts.removeAll { $0.label == label }
                return
            }
            if let i = accounts.firstIndex(where: { $0.label == label }) {
                accounts[i] = newValue
            } else {
                accounts.append(newValue)
            }
        }
    }

    // MARK: - Persistence

    public static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["CCQUOTA_HOME"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ccquota")
    }

    public static var fileURL: URL { directory.appendingPathComponent("accounts.json") }

    public static func load() throws -> AccountStore {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AccountStore() }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(AccountStore.self, from: data)
    }

    public func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)

        // Write to a temp file and swap, so a crash mid-write cannot leave a
        // truncated file that would strand every stored refresh token.
        let tmp = Self.fileURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try fm.replaceItemAt(Self.fileURL, withItemAt: tmp)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }
}
