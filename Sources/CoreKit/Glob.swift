// Deliberately free of `import Foundation` so the matcher can be compiled and
// tested standalone.

/// Wildcard matching, ported from the mask semantics in WinSCP
/// `source/core/FileMasks.cpp`: `*` matches any run of characters (including
/// none), `?` matches exactly one, comparison is case-insensitive.
public enum Glob {
    /// Iterative match with backtracking. The recursive formulation is the
    /// obvious one, but a pattern like `*a*a*a*a*b` against a long name drives
    /// it exponential; tracking a single restart point keeps it linear in
    /// practice and cannot blow the stack.
    public static func match(pattern: String, name: String) -> Bool {
        let p = Array(pattern.lowercased())
        let s = Array(name.lowercased())

        var pi = 0, si = 0
        var starIndex = -1
        var matchIndex = 0

        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) {
                pi += 1
                si += 1
            } else if pi < p.count && p[pi] == "*" {
                starIndex = pi
                matchIndex = si
                pi += 1
            } else if starIndex != -1 {
                pi = starIndex + 1
                matchIndex += 1
                si = matchIndex
            } else {
                return false
            }
        }

        // Trailing stars can absorb the empty remainder.
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
