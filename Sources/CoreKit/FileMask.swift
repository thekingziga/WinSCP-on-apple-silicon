import Foundation

/// File masks, ported from WinSCP `source/core/FileMasks.cpp`.
///
/// A mask list is semicolon- or comma-separated. Entries prefixed with `|`
/// are exclusions, matching WinSCP's `include|exclude` syntax. A trailing `/`
/// restricts an entry to directories. `*` matches any run of characters,
/// `?` matches exactly one.
public struct FileMask: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var pattern: String
        public var directoryOnly: Bool
    }

    public private(set) var includes: [Entry] = []
    public private(set) var excludes: [Entry] = []
    public let source: String

    public init(_ mask: String) {
        self.source = mask

        // Split include and exclude sections on the first unescaped '|'.
        let sections = mask.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let includeText = sections.count > 0 ? String(sections[0]) : ""
        let excludeText = sections.count > 1 ? String(sections[1]) : ""

        includes = FileMask.parse(includeText)
        excludes = FileMask.parse(excludeText)
    }

    private static func parse(_ text: String) -> [Entry] {
        text
            .split(whereSeparator: { $0 == ";" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { raw in
                var pattern = raw
                var directoryOnly = false
                if pattern.hasSuffix("/") {
                    directoryOnly = true
                    pattern.removeLast()
                }
                return Entry(pattern: pattern, directoryOnly: directoryOnly)
            }
    }

    /// An empty include list means "match everything", as in WinSCP.
    public var matchesEverything: Bool { includes.isEmpty && excludes.isEmpty }

    public func matches(name: String, isDirectory: Bool) -> Bool {
        for entry in excludes where entry.directoryOnly == false || isDirectory {
            if FileMask.wildcardMatch(pattern: entry.pattern, name: name) { return false }
        }
        if includes.isEmpty { return true }
        for entry in includes where entry.directoryOnly == false || isDirectory {
            if FileMask.wildcardMatch(pattern: entry.pattern, name: name) { return true }
        }
        return false
    }

    /// Case-insensitive `*`/`?` glob. Implementation lives in `Glob` so it can
    /// be compiled and tested without Foundation.
    public static func wildcardMatch(pattern: String, name: String) -> Bool {
        Glob.match(pattern: pattern, name: name)
    }
}
