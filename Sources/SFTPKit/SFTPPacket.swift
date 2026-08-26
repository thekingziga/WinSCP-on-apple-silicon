// Deliberately free of `import Foundation` — see SFTPProtocol.swift.
//
// Timestamps are carried as raw epoch seconds here; the Foundation-facing
// `Date` accessors live in SFTPPacket+Foundation.swift.

/// Big-endian packet writer for the SFTP wire format.
///
/// Every SFTP packet is `uint32 length` followed by `byte type` and a
/// type-specific body. Strings are `uint32 length` + raw bytes (UTF-8 for
/// paths in practice; the spec is byte-oriented, which matters for servers
/// with non-UTF-8 filenames — we decode leniently on the way back).
public struct SFTPWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func write(byte: UInt8) {
        bytes.append(byte)
    }

    public mutating func write(uint32 value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    public mutating func write(uint64 value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    public mutating func write(string value: String) {
        let utf8 = Array(value.utf8)
        write(uint32: UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
    }

    public mutating func write(data value: [UInt8]) {
        write(uint32: UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    /// Raw append with no length prefix.
    public mutating func append(raw value: [UInt8]) {
        bytes.append(contentsOf: value)
    }

    /// Frame the accumulated body as a complete packet of the given type.
    public func framedBytes(type: SFTPPacketType) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + 5)
        let length = UInt32(bytes.count + 1)  // +1 for the type byte
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(type.rawValue)
        out.append(contentsOf: bytes)
        return out
    }
}

/// Big-endian packet reader.
public struct SFTPReader {
    private let bytes: [UInt8]
    private var offset: Int = 0

    public init(_ data: [UInt8]) { self.bytes = data }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { offset >= bytes.count }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset + count <= bytes.count else {
            throw SFTPError.malformedPacket(
                "wanted \(count) bytes at offset \(offset), have \(bytes.count)")
        }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    public mutating func readByte() throws -> UInt8 {
        guard let b = try take(1).first else {
            throw SFTPError.malformedPacket("empty read")
        }
        return b
    }

    public mutating func readUInt32() throws -> UInt32 {
        try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    public mutating func readUInt64() throws -> UInt64 {
        try take(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    public mutating func readBytes() throws -> [UInt8] {
        let count = Int(try readUInt32())
        return Array(try take(count))
    }

    /// Decodes as UTF-8, falling back to a byte-wise Latin-1 mapping so a
    /// single oddly-encoded filename can't abort an entire directory listing.
    /// WinSCP does the equivalent via its UTF-8 detection in SftpFileSystem.
    public mutating func readString() throws -> String {
        let raw = try readBytes()
        // `String(validating:as:)` would say this directly but is macOS 15+.
        // Decoding substitutes U+FFFD for invalid sequences, so re-encoding and
        // comparing tells us whether the input was well-formed UTF-8.
        let decoded = String(decoding: raw, as: UTF8.self)
        if Array(decoded.utf8) == raw { return decoded }
        // Latin-1: every byte maps to the scalar of the same value.
        return String(raw.map { Character(UnicodeScalar($0)) })
    }

    /// Reads a file-attributes structure (draft-02 §5).
    public mutating func readAttributes() throws -> SFTPFileAttributes {
        var attrs = SFTPFileAttributes()
        let flags = SFTPAttributeFlags(rawValue: try readUInt32())
        attrs.flags = flags

        if flags.contains(.size) {
            attrs.size = try readUInt64()
        }
        if flags.contains(.uidgid) {
            attrs.uid = try readUInt32()
            attrs.gid = try readUInt32()
        }
        if flags.contains(.permissions) {
            attrs.permissions = try readUInt32()
        }
        if flags.contains(.acmodtime) {
            attrs.accessTimeEpoch = try readUInt32()
            attrs.modifyTimeEpoch = try readUInt32()
        }
        if flags.contains(.extended) {
            let count = try readUInt32()
            // Guard a hostile or desynced server from driving a huge loop.
            guard count <= 4096 else {
                throw SFTPError.malformedPacket("extended pair count \(count)")
            }
            for _ in 0..<count {
                let key = try readString()
                let value = try readString()
                attrs.extended[key] = value
            }
        }
        return attrs
    }
}

/// Decoded file attributes.
public struct SFTPFileAttributes: Sendable, Equatable {
    public var flags: SFTPAttributeFlags = []
    public var size: UInt64 = 0
    public var uid: UInt32 = 0
    public var gid: UInt32 = 0
    public var permissions: UInt32 = 0
    public var accessTimeEpoch: UInt32?
    public var modifyTimeEpoch: UInt32?
    public var extended: [String: String] = [:]

    public init() {}

    public var isDirectory: Bool { (permissions & POSIXFileType.mask) == POSIXFileType.directory }
    public var isSymlink: Bool { (permissions & POSIXFileType.mask) == POSIXFileType.symlink }
    public var isRegularFile: Bool { (permissions & POSIXFileType.mask) == POSIXFileType.regular }

    /// Rendered as `rwxr-xr-x`.
    public var permissionString: String {
        SFTPFileAttributes.renderPermissions(permissions)
    }

    public static func renderPermissions(_ mode: UInt32) -> String {
        let bits = mode & 0o777
        var out = ""
        for shift in [UInt32(6), UInt32(3), UInt32(0)] {
            let triad = (bits >> shift) & 0o7
            out += (triad & 0o4) != 0 ? "r" : "-"
            out += (triad & 0o2) != 0 ? "w" : "-"
            out += (triad & 0o1) != 0 ? "x" : "-"
        }
        return out
    }

    /// Parse a permission mode the way `chmod` accepts it: three or four octal
    /// digits (`644`, `0644`), or a nine-character `rwxr-xr-x` string as
    /// rendered by `renderPermissions`. Returns nil on anything else, so a
    /// caller can reject bad input rather than silently applying a wrong mode.
    ///
    /// The inverse of `renderPermissions`, and kept beside it: a dialog that
    /// shows a mode has to read one back, and splitting the pair across layers
    /// is how they drift.
    public static func parsePermissions(_ text: String) -> UInt32? {
        let trimmed = text.trimmingASCIIWhitespace()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.allSatisfy({ $0.isASCIIOctalDigit }) {
            // Four digits allows a leading zero (`0644`); more cannot be a
            // plain permission mode. Setuid and friends are out of scope —
            // SETSTAT here only ever carries the low nine bits.
            guard trimmed.count <= 4 else { return nil }
            var mode: UInt32 = 0
            for character in trimmed {
                mode = mode << 3 | UInt32(character.asciiValue! - 48)
            }
            guard mode <= 0o777 else { return nil }
            return mode
        }

        guard trimmed.count == 9 else { return nil }
        var mode: UInt32 = 0
        // Three triads of r/w/x, each position either its letter or '-'.
        let expected: [Character] = ["r", "w", "x"]
        for (index, character) in trimmed.enumerated() {
            let bit = expected[index % 3]
            if character == bit {
                mode |= 1 << UInt32(8 - index)
            } else if character != "-" {
                return nil
            }
        }
        return mode
    }
}

private extension Character {
    var isASCIIOctalDigit: Bool {
        guard let value = asciiValue else { return false }
        return value >= 48 && value <= 55
    }
}

private extension String {
    /// Foundation's `trimmingCharacters` is unavailable in this file — the
    /// codec is deliberately stdlib-only so it stays testable without an SDK.
    func trimmingASCIIWhitespace() -> String {
        var characters = Substring(self)
        while let first = characters.first, first == " " || first == "\t" {
            characters = characters.dropFirst()
        }
        while let last = characters.last, last == " " || last == "\t" {
            characters = characters.dropLast()
        }
        return String(characters)
    }
}

extension SFTPAttributeFlags: Equatable {}
