import Foundation

/// Reads and writes the live Claude Code credential in the login Keychain.
///
/// We shell out to `/usr/bin/security` rather than calling SecItem directly:
/// the existing item's ACL already trusts that binary, so reads succeed without
/// an authorization prompt. A freshly built Swift binary would not be on the
/// ACL and would prompt on every rebuild.
public enum Keychain {
    public static let service = "Claude Code-credentials"

    static var account: String {
        ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
    }

    /// A credential shell for accounts registered by browser authorisation,
    /// which have no Keychain entry to copy from.
    public static func emptyBlob() throws -> CredentialBlob {
        try CredentialBlob(json: Data("{}".utf8))
    }

    public static func readLiveCredential() throws -> CredentialBlob {
        let out = try Shell.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", service, "-a", account, "-w"]
        )
        guard let data = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .data(using: .utf8), !data.isEmpty else {
            throw CCError("Keychain 항목 '\(service)'을 읽지 못했습니다. Claude Code에 로그인되어 있는지 확인하십시오.")
        }
        return try CredentialBlob(json: data)
    }

    /// Overwrites the live credential, leaving the item's ACL untouched.
    ///
    /// Deliberately no `-A`. That flag rewrites the access list, and changing an
    /// existing item's ACL needs the login keychain password — so every switch
    /// stopped on a "security wants to change access permissions" dialog. It was
    /// never needed: `claude` reads this item through /usr/bin/security, which
    /// the existing ACL already trusts, and which is the same tool writing here.
    public static func writeLiveCredential(_ blob: CredentialBlob) throws {
        let json = try blob.serialized()
        guard let text = String(data: json, encoding: .utf8) else {
            throw CCError("자격증명을 직렬화하지 못했습니다.")
        }
        _ = try Shell.run("/usr/bin/security",
                          ["add-generic-password", "-U",
                           "-s", service, "-a", account, "-w", text])
    }
}

public enum Shell {
    /// Opens a URL in the user's browser.
    @discardableResult
    public static func open(_ url: URL) throws -> String {
        try run("/usr/bin/open", [url.absoluteString])
    }

    @discardableResult
    public static func run(_ launchPath: String, _ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args

        let stdout = Pipe(), stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()

        // Drain before waiting so a large payload cannot fill the pipe buffer.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let err = String(data: errData, encoding: .utf8) ?? ""
            throw CCError("\(launchPath) 실패 (exit \(proc.terminationStatus)): \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
