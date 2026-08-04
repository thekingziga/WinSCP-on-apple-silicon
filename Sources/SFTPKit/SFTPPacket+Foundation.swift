import Foundation

// Bridges the Foundation-free codec to the Foundation types the transport and
// UI layers want. Keeping this separate is what lets SFTPPacket.swift and
// SFTPProtocol.swift compile and be tested without the platform SDK.

extension SFTPWriter {
    /// Frame the accumulated body as a complete packet, as `Data`.
    public func framed(type: SFTPPacketType) -> Data {
        Data(framedBytes(type: type))
    }
}

extension SFTPReader {
    public init(_ data: Data) {
        self.init([UInt8](data))
    }
}

extension SFTPFileAttributes {
    public var accessTime: Date? {
        accessTimeEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public var modifyTime: Date? {
        modifyTimeEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

extension SFTPError: LocalizedError {
    public var errorDescription: String? { message }
}
