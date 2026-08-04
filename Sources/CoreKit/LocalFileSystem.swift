import Foundation

/// Local-side backend for the left pane.
public enum LocalFileSystem {
    public static func list(_ directory: URL, showHidden: Bool = false) throws -> [FileItem] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey, .isHiddenKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )

        return urls.compactMap { url -> FileItem? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let posix = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber

            return FileItem(
                name: url.lastPathComponent,
                isDirectory: isDir,
                isSymlink: values?.isSymbolicLink ?? false,
                size: UInt64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate,
                permissions: posix.map { permissionString(UInt32(truncating: $0)) } ?? "",
                owner: ""
            )
        }
        .sorted(by: FileItem.defaultSort)
    }

    public static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    public static func remove(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public static func rename(at url: URL, to newName: String) throws {
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        try FileManager.default.moveItem(at: url, to: destination)
    }

    /// Same `rwxr-xr-x` rendering the remote side uses, so both panes agree.
    public static func permissionString(_ mode: UInt32) -> String {
        let bits = mode & 0o777
        var out = ""
        for shift in [6, 3, 0] {
            let triad = (bits >> UInt32(shift)) & 0o7
            out += (triad & 0o4) != 0 ? "r" : "-"
            out += (triad & 0o2) != 0 ? "w" : "-"
            out += (triad & 0o1) != 0 ? "x" : "-"
        }
        return out
    }
}
