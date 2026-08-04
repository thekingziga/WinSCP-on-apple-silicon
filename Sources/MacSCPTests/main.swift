import Foundation
import SFTPKit
import CoreKit

// Neither XCTest nor Swift Testing ships with Command Line Tools, so the suite
// is a plain executable with its own assertions. Run with `swift run MacSCPTests`.
//
// The pure-codec checks also exist in Scripts/CodecVerification.swift, which
// compiles without Foundation and therefore survives a broken SDK. This target
// covers the Foundation-dependent layers that harness cannot reach.

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL: \(label)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  FAIL: \(label)\n    expected: \(expected)\n    actual:   \(actual)")
    }
}

func section(_ name: String) { print("== \(name) ==") }

// MARK: - Codec sanity (mirrors the standalone harness)

section("SFTP codec")
do {
    var w = SFTPWriter()
    w.write(uint32: sftpClientVersion)
    expectEqual(w.framedBytes(type: .initialize), [0, 0, 0, 5, 1, 0, 0, 0, 3], "SSH_FXP_INIT framing")
    expectEqual([UInt8](w.framed(type: .initialize)), [0, 0, 0, 5, 1, 0, 0, 0, 3], "Data framing matches")

    var w2 = SFTPWriter()
    w2.write(string: "é")
    expectEqual(w2.bytes, [0, 0, 0, 2, 0xC3, 0xA9], "utf8 byte-length prefix")

    // Round-trip through Data, exercising the Foundation bridge.
    var w3 = SFTPWriter()
    w3.write(string: "dir/name.txt")
    var r = SFTPReader(Data(w3.bytes))
    expectEqual(try! r.readString(), "dir/name.txt", "Data-backed reader round-trip")
}

section("UTF-8 validation (round-trip check replaces macOS 15 API)")
do {
    var w = SFTPWriter()
    w.write(data: [0xFF, 0xFE])
    var r = SFTPReader(w.bytes)
    let s = try! r.readString()
    expect(!s.isEmpty, "invalid utf8 falls back rather than returning empty")
    expectEqual(s.count, 2, "latin-1 fallback yields one character per byte")

    // Valid multi-byte input must survive unchanged, not get mangled by the
    // fallback path.
    var w2 = SFTPWriter()
    w2.write(string: "naïve—ok✓")
    var r2 = SFTPReader(w2.bytes)
    expectEqual(try! r2.readString(), "naïve—ok✓", "valid multi-byte utf8 preserved")

    var w3 = SFTPWriter()
    w3.write(string: "日本語のファイル.txt")
    var r3 = SFTPReader(w3.bytes)
    expectEqual(try! r3.readString(), "日本語のファイル.txt", "CJK filename preserved")
}

section("Attribute → Date bridge")
do {
    var w = SFTPWriter()
    w.write(uint32: SFTPAttributeFlags.acmodtime.rawValue)
    w.write(uint32: 1_700_000_000)
    w.write(uint32: 1_700_000_500)
    var r = SFTPReader(w.bytes)
    let a = try! r.readAttributes()
    expectEqual(a.modifyTime?.timeIntervalSince1970, 1_700_000_500, "mtime bridges to Date")
    expectEqual(a.accessTime?.timeIntervalSince1970, 1_700_000_000, "atime bridges to Date")

    var empty = SFTPReader([0, 0, 0, 0])
    let none = try! empty.readAttributes()
    expect(none.modifyTime == nil, "absent mtime bridges to nil")
}

// MARK: - FileMask

section("FileMask")
do {
    let mask = FileMask("*.txt;*.md|draft*")
    expect(mask.matches(name: "notes.txt", isDirectory: false), "include *.txt")
    expect(mask.matches(name: "readme.md", isDirectory: false), "include *.md")
    expect(!mask.matches(name: "image.png", isDirectory: false), "exclude unmatched extension")
    expect(!mask.matches(name: "draft.txt", isDirectory: false), "exclusion beats inclusion")

    let empty = FileMask("")
    expect(empty.matchesEverything, "empty mask matches everything")
    expect(empty.matches(name: "anything", isDirectory: false), "empty mask admits any name")

    let commas = FileMask("*.a,*.b")
    expect(commas.matches(name: "x.a", isDirectory: false), "comma separator")
    expect(commas.matches(name: "x.b", isDirectory: false), "comma separator, second entry")

    let dirOnly = FileMask("build/")
    expect(dirOnly.matches(name: "build", isDirectory: true), "directory-only mask matches directory")
    expect(!dirOnly.matches(name: "build", isDirectory: false), "directory-only mask skips files")

    let spaced = FileMask(" *.log ; *.tmp ")
    expect(spaced.matches(name: "a.log", isDirectory: false), "whitespace around entries trimmed")

    let excludeOnly = FileMask("|*.tmp")
    expect(excludeOnly.matches(name: "keep.txt", isDirectory: false), "exclude-only admits others")
    expect(!excludeOnly.matches(name: "junk.tmp", isDirectory: false), "exclude-only rejects match")
}

// MARK: - FileItem

section("FileItem")
do {
    var attrs = SFTPFileAttributes()
    attrs.permissions = 0o040755
    attrs.size = 4096
    let dirName = SFTPName(
        filename: "projects",
        longname: "drwxr-xr-x 2 ziga staff 4096 Jan 1 12:00 projects",
        attributes: attrs)
    let dir = FileItem(remote: dirName)
    expect(dir.isDirectory, "directory flag from attributes")
    expectEqual(dir.owner, "ziga", "owner parsed from longname column 3")
    expectEqual(dir.displaySize, "—", "directories show no size")
    expectEqual(dir.permissions, "rwxr-xr-x", "permission string")

    var fattrs = SFTPFileAttributes()
    fattrs.permissions = 0o100644
    fattrs.size = 1024
    let file = FileItem(remote: SFTPName(filename: "a.txt", longname: "", attributes: fattrs))
    expect(!file.isDirectory, "regular file")
    expect(!file.displaySize.isEmpty, "files show a size")
    expectEqual(file.owner, "", "missing longname yields empty owner")

    // Sorting: directories first, then case-insensitive by name.
    let items = [
        FileItem(name: "zebra.txt", isDirectory: false),
        FileItem(name: "Alpha", isDirectory: true),
        FileItem(name: "apple.txt", isDirectory: false),
        FileItem(name: "beta", isDirectory: true),
    ].sorted(by: FileItem.defaultSort)
    expectEqual(items.map(\.name), ["Alpha", "beta", "apple.txt", "zebra.txt"], "directories first, then name")
}

// MARK: - SessionData

section("SessionData")
do {
    var s = SessionData(hostName: "example.com")
    expectEqual(s.sshTarget, "example.com", "target without user")
    expectEqual(s.displayName, "example.com", "display falls back to target")
    expect(s.isValid, "host alone is valid")

    s.userName = "ziga"
    expectEqual(s.sshTarget, "ziga@example.com", "target with user")
    s.name = "Prod"
    expectEqual(s.displayName, "Prod", "display prefers explicit name")

    let blank = SessionData()
    expect(!blank.isValid, "empty host is invalid")
    let spaces = SessionData(hostName: "   ")
    expect(!spaces.isValid, "whitespace-only host is invalid")
}

section("SessionStore persistence")
do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macscp-test-\(UUID().uuidString).json")
    let store = SessionStore(url: tmp)

    expectEqual(store.load().count, 0, "missing file loads as empty")

    let a = SessionData(name: "A", hostName: "a.example", userName: "ziga", portNumber: 2222)
    let b = SessionData(name: "B", hostName: "b.example", sshOptions: ["-o", "ProxyJump=bastion"])
    store.save([a, b])

    let loaded = store.load()
    expectEqual(loaded.count, 2, "round-trip count")
    expectEqual(loaded.first?.name, "A", "round-trip name")
    expectEqual(loaded.first?.portNumber, 2222, "round-trip port")
    expectEqual(loaded.last?.sshOptions, ["-o", "ProxyJump=bastion"], "round-trip ssh options")
    expectEqual(loaded.first?.id, a.id, "identity preserved")

    try? FileManager.default.removeItem(at: tmp)
}

// MARK: - LocalFileSystem

section("LocalFileSystem")
do {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macscp-fs-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try! LocalFileSystem.createDirectory(at: root.appendingPathComponent("subdir"))
    FileManager.default.createFile(
        atPath: root.appendingPathComponent("note.txt").path,
        contents: Data("hello".utf8))
    FileManager.default.createFile(
        atPath: root.appendingPathComponent(".hidden").path,
        contents: Data("x".utf8))

    let visible = try! LocalFileSystem.list(root, showHidden: false)
    expectEqual(visible.count, 2, "hidden files excluded by default")
    expectEqual(visible.first?.name, "subdir", "directories sort first")
    expect(visible.first?.isDirectory == true, "subdir is a directory")

    let all = try! LocalFileSystem.list(root, showHidden: true)
    expectEqual(all.count, 3, "hidden files included when requested")

    let note = visible.first { $0.name == "note.txt" }
    expectEqual(note?.size, 5, "file size read")
    expect(note?.permissions.isEmpty == false, "permissions populated")

    try! LocalFileSystem.rename(at: root.appendingPathComponent("note.txt"), to: "renamed.txt")
    let afterRename = try! LocalFileSystem.list(root)
    expect(afterRename.contains { $0.name == "renamed.txt" }, "rename applied")
    expect(!afterRename.contains { $0.name == "note.txt" }, "old name gone")

    try! LocalFileSystem.remove(at: root.appendingPathComponent("renamed.txt"))
    expect(!(try! LocalFileSystem.list(root)).contains { $0.name == "renamed.txt" }, "remove applied")

    var threw = false
    do { _ = try LocalFileSystem.list(root.appendingPathComponent("nope")) } catch { threw = true }
    expect(threw, "listing a missing directory throws")

    expectEqual(LocalFileSystem.permissionString(0o644), "rw-r--r--", "local permission rendering")
    expectEqual(LocalFileSystem.permissionString(0o755), "rwxr-xr-x", "local permission rendering, exec")
}

// MARK: - Transport argument construction

section("Remote path joining")
do {
    // Mirrors AppModel.joinRemote, which must not produce a double slash at root.
    func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }
    expectEqual(join("/", "etc"), "/etc", "root join has no double slash")
    expectEqual(join("/home/ziga", "file.txt"), "/home/ziga/file.txt", "nested join")
    expectEqual(join("/home/ziga/", "file.txt"), "/home/ziga/file.txt", "trailing slash join")
}

print("")
if failures == 0 {
    print("ALL PASS — \(checks) checks")
    exit(0)
} else {
    print("\(failures) FAILED of \(checks) checks")
    exit(1)
}
