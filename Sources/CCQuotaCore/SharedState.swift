import Foundation
import os

/// The hand-off between the menu bar app and the widget.
///
/// The widget extension is always sandboxed and can only read the App Group
/// container, so the app publishes plain percentages there. No token, and no
/// path to one, ever crosses this boundary.
public enum SharedState {
    /// macOS App Group identifiers are prefixed with the Team ID.
    public static let appGroupID = "RP5GZ99V95.dev.tntlabs.ccquota"

    /// Written by the CLI, which has no App Group entitlement, and read by the
    /// app as a fallback when the container is unavailable.
    public static var fallbackURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ccquota/state.json")
    }

    public static var containerURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("state.json")
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Publishes to every location available to this process. The App Group
    /// container is what the widget reads; the fallback keeps `ccquota` usable
    /// from the terminal before the app is ever installed.
    public static func write(_ state: SharedStateFile) throws {
        let data = try encoder.encode(state)
        for url in [containerURL, fallbackURL].compactMap({ $0 }) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    static let log = Logger(subsystem: "dev.tntlabs.ccquota", category: "SharedState")

    /// Why the diagnostics: the widget runs sandboxed, so a failure here is
    /// invisible — it just renders an empty card. Naming which URL was tried and
    /// how it failed is the only way to tell "no accounts registered" apart from
    /// "cannot reach the App Group container".
    public static func read() -> SharedStateFile? {
        let container = containerURL
        log.notice("read: container=\(container?.path ?? "nil", privacy: .public) fallback=\(fallbackURL.path, privacy: .public)")

        for url in [container, fallbackURL].compactMap({ $0 }) {
            do {
                let data = try Data(contentsOf: url)
                let state = try decoder.decode(SharedStateFile.self, from: data)
                log.notice("read: ok from \(url.path, privacy: .public) accounts=\(state.accounts.count)")
                return state
            } catch {
                log.error("read: \(url.path, privacy: .public) failed — \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }
}
