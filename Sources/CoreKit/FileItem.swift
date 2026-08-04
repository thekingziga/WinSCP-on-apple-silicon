import Foundation
import SFTPKit

/// A single row in either pane.
///
/// WinSCP keeps separate `TRemoteFile` and local-file hierarchies and reconciles
/// them at the UI boundary. One model for both sides removes that seam, which
/// is most of what made `source/forms` as large as it is.
public struct FileItem: Identifiable, Sendable, Equatable {
    public var name: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var size: UInt64
    public var modified: Date?
    public var permissions: String
    public var owner: String

    public var id: String { name }

    public init(
        name: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        size: UInt64 = 0,
        modified: Date? = nil,
        permissions: String = "",
        owner: String = ""
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
    }

    /// Build from an SFTP listing entry.
    public init(remote: SFTPName) {
        let attrs = remote.attributes
        self.name = remote.filename
        self.isDirectory = attrs.isDirectory
        self.isSymlink = attrs.isSymlink
        self.size = attrs.size
        self.modified = attrs.modifyTime
        self.permissions = attrs.permissionString
        // `longname` is the server's ls -l line; column 3 is the owner.
        let columns = remote.longname.split(separator: " ", omittingEmptySubsequences: true)
        self.owner = columns.count > 2 ? String(columns[2]) : ""
    }

    public var displaySize: String {
        if isDirectory { return "—" }
        return FileItem.byteFormatter.string(fromByteCount: Int64(size))
    }

    public var displayModified: String {
        guard let modified else { return "" }
        return FileItem.dateFormatter.string(from: modified)
    }

    /// Sort the way WinSCP does: directories first, then case-insensitive name.
    public static func defaultSort(_ a: FileItem, _ b: FileItem) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}
