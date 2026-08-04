// Deliberately free of `import Foundation`.
//
// The wire protocol is pure byte manipulation, so keeping this file on the
// Swift stdlib alone means the codec can be compiled and tested in isolation
// from the platform SDK. That separation is also just correct layering: the
// SFTP grammar has nothing to do with Foundation's types.

/// SFTP wire protocol constants.
///
/// Ported from WinSCP `source/core/SftpFileSystem.cpp`, which implements
/// draft-ietf-secsh-filexfer. We speak version 3, the same baseline WinSCP
/// negotiates against and what OpenSSH's server offers.
public enum SFTPPacketType: UInt8, Sendable {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20
    case link = 21

    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105

    case extended = 200
    case extendedReply = 201
}

/// Server status codes (SSH_FX_*).
public enum SFTPStatus: UInt32, Sendable {
    case ok = 0
    case eof = 1
    case noSuchFile = 2
    case permissionDenied = 3
    case failure = 4
    case badMessage = 5
    case noConnection = 6
    case connectionLost = 7
    case opUnsupported = 8

    /// Human-readable text mirroring the messages WinSCP surfaces.
    public var message: String {
        switch self {
        case .ok: return "Success"
        case .eof: return "End of file"
        case .noSuchFile: return "No such file or directory"
        case .permissionDenied: return "Permission denied"
        case .failure: return "Failure"
        case .badMessage: return "Bad message"
        case .noConnection: return "No connection"
        case .connectionLost: return "Connection lost"
        case .opUnsupported: return "Operation unsupported"
        }
    }
}

/// File attribute presence flags (SSH_FILEXFER_ATTR_*).
public struct SFTPAttributeFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let size        = SFTPAttributeFlags(rawValue: 0x0000_0001)
    public static let uidgid      = SFTPAttributeFlags(rawValue: 0x0000_0002)
    public static let permissions = SFTPAttributeFlags(rawValue: 0x0000_0004)
    public static let acmodtime   = SFTPAttributeFlags(rawValue: 0x0000_0008)
    public static let extended    = SFTPAttributeFlags(rawValue: 0x8000_0000)
}

/// File open flags (SSH_FXF_*).
public struct SFTPOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read   = SFTPOpenFlags(rawValue: 0x0000_0001)
    public static let write  = SFTPOpenFlags(rawValue: 0x0000_0002)
    public static let append = SFTPOpenFlags(rawValue: 0x0000_0004)
    public static let create = SFTPOpenFlags(rawValue: 0x0000_0008)
    public static let trunc  = SFTPOpenFlags(rawValue: 0x0000_0010)
    public static let excl   = SFTPOpenFlags(rawValue: 0x0000_0020)
}

/// POSIX file-type mask and values, as interpreted in WinSCP RemoteFiles.cpp.
public enum POSIXFileType {
    public static let mask: UInt32     = 0o170000
    public static let directory: UInt32 = 0o040000
    public static let symlink: UInt32   = 0o120000
    public static let regular: UInt32   = 0o100000
}

/// The protocol version we request. WinSCP defaults to 3 for maximum
/// server compatibility and negotiates up only when the server offers it.
public let sftpClientVersion: UInt32 = 3

/// Errors surfaced by the engine.
public enum SFTPError: Error {
    case transportFailed(String)
    case handshakeFailed(String)
    case unexpectedPacket(UInt8)
    case malformedPacket(String)
    case server(SFTPStatus, String)
    case notConnected
    case cancelled

    public var message: String {
        switch self {
        case .transportFailed(let s): return "SSH transport failed: \(s)"
        case .handshakeFailed(let s): return "SFTP handshake failed: \(s)"
        case .unexpectedPacket(let t): return "Unexpected packet type \(t) from server"
        case .malformedPacket(let s): return "Malformed packet: \(s)"
        case .server(let st, let msg):
            return msg.isEmpty ? st.message : "\(st.message): \(msg)"
        case .notConnected: return "Not connected"
        case .cancelled: return "Cancelled"
        }
    }
}
