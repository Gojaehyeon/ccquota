import Foundation

/// Detects whether Claude Code has been used since a given moment, by looking at
/// the transcripts it writes under `~/.claude/projects`.
///
/// This exists because quota figures only move when Claude is actually used.
/// Polling on a fixed timer spends requests all night to re-read numbers that
/// cannot have changed, and that constant background traffic is what put this
/// tool in trouble in the first place. Reading a local mtime costs nothing and
/// answers the only question that matters: is there anything new to fetch?
public enum Activity {
    public static var transcriptRoot: URL {
        if let override = ProcessInfo.processInfo.environment["CCQUOTA_TRANSCRIPT_DIR"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Newest modification time across the transcript tree, or nil if there is
    /// nothing to read. Enumeration is shallow in cost — it reads directory
    /// metadata, never the transcripts themselves, which stay private.
    public static func lastUsed() -> Date? {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: transcriptRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: Date?
        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modified = values.contentModificationDate else { continue }
            if newest == nil || modified > newest! { newest = modified }
        }
        return newest
    }

    /// True when a transcript changed after `date` — meaning tokens were spent
    /// and the quota figures are worth re-fetching.
    public static func usedSince(_ date: Date) -> Bool {
        guard let last = lastUsed() else { return false }
        return last > date
    }
}
