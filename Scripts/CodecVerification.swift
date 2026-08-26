// Standalone verification harness for the Foundation-free layers of MacSCP.
// Compiled directly against the real source files, no Foundation, no SPM.

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

print("== SFTPWriter: integer encoding (big-endian) ==")
do {
    var w = SFTPWriter()
    w.write(uint32: 0x0102_0304)
    expectEqual(w.bytes, [1, 2, 3, 4], "uint32 is big-endian")

    var w2 = SFTPWriter()
    w2.write(uint64: 1)
    expectEqual(w2.bytes, [0, 0, 0, 0, 0, 0, 0, 1], "uint64 is big-endian")

    var w3 = SFTPWriter()
    w3.write(uint64: 0xDEAD_BEEF_CAFE_0001)
    expectEqual(w3.bytes, [0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0x00, 0x01], "uint64 full width")

    var w4 = SFTPWriter()
    w4.write(uint32: UInt32.max)
    expectEqual(w4.bytes, [0xFF, 0xFF, 0xFF, 0xFF], "uint32 max")
}

print("== SFTPWriter: string and byte-string encoding ==")
do {
    var w = SFTPWriter()
    w.write(string: "abc")
    expectEqual(w.bytes, [0, 0, 0, 3, 97, 98, 99], "string is uint32 length + utf8")

    var w2 = SFTPWriter()
    w2.write(string: "")
    expectEqual(w2.bytes, [0, 0, 0, 0], "empty string is just a zero length")

    // Multi-byte UTF-8 must be counted in BYTES, not characters. Getting this
    // wrong is the classic way to desync an SFTP stream.
    var w3 = SFTPWriter()
    w3.write(string: "é")
    expectEqual(w3.bytes, [0, 0, 0, 2, 0xC3, 0xA9], "utf8 length is byte count")

    var w4 = SFTPWriter()
    w4.write(data: [0xAA, 0xBB])
    expectEqual(w4.bytes, [0, 0, 0, 2, 0xAA, 0xBB], "byte string is length-prefixed")
}

print("== SFTPWriter: packet framing ==")
do {
    // SSH_FXP_INIT with version 3 is the very first thing on the wire.
    var w = SFTPWriter()
    w.write(uint32: sftpClientVersion)
    let framed = w.framedBytes(type: .initialize)
    // length = 4 (body) + 1 (type) = 5
    expectEqual(framed, [0, 0, 0, 5, 1, 0, 0, 0, 3], "SSH_FXP_INIT v3 wire bytes")

    let empty = SFTPWriter()
    expectEqual(empty.framedBytes(type: .close), [0, 0, 0, 1, 4], "empty body frames to length 1")
}

print("== SFTPReader: primitive round-trips ==")
do {
    var w = SFTPWriter()
    w.write(uint32: 42)
    w.write(uint64: 0x1122_3344_5566_7788)
    w.write(string: "hello/world.txt")
    w.write(data: [9, 8, 7])
    w.write(byte: 0xFE)

    var r = SFTPReader(w.bytes)
    expectEqual(try! r.readUInt32(), 42, "uint32 round-trip")
    expectEqual(try! r.readUInt64(), 0x1122_3344_5566_7788, "uint64 round-trip")
    expectEqual(try! r.readString(), "hello/world.txt", "string round-trip")
    expectEqual(try! r.readBytes(), [9, 8, 7], "byte string round-trip")
    expectEqual(try! r.readByte(), 0xFE, "byte round-trip")
    expect(r.isAtEnd, "reader consumed exactly the written bytes")
}

print("== SFTPReader: truncation is an error, not a crash ==")
do {
    var r = SFTPReader([0, 0, 0])  // three bytes, uint32 needs four
    var threw = false
    do { _ = try r.readUInt32() } catch { threw = true }
    expect(threw, "short uint32 throws")

    // Declares a 16-byte string but supplies four bytes.
    var r2 = SFTPReader([0, 0, 0, 16, 1, 2, 3, 4])
    var threw2 = false
    do { _ = try r2.readString() } catch { threw2 = true }
    expect(threw2, "over-long declared string throws")

    var r3 = SFTPReader([])
    var threw3 = false
    do { _ = try r3.readByte() } catch { threw3 = true }
    expect(threw3, "read from empty buffer throws")
}

print("== SFTPReader: non-UTF-8 filenames degrade instead of failing ==")
do {
    var w = SFTPWriter()
    w.write(data: [0xFF, 0xFE])  // invalid UTF-8
    var r = SFTPReader(w.bytes)
    let s = try! r.readString()
    expect(!s.isEmpty, "invalid utf8 falls back to latin-1 rather than empty")
}

print("== Attributes: flag-driven parsing ==")
do {
    // A directory with size + permissions + times, as OpenSSH would send.
    var w = SFTPWriter()
    let flags: SFTPAttributeFlags = [.size, .uidgid, .permissions, .acmodtime]
    w.write(uint32: flags.rawValue)
    w.write(uint64: 4096)
    w.write(uint32: 501)          // uid
    w.write(uint32: 20)           // gid
    w.write(uint32: 0o040755)     // drwxr-xr-x
    w.write(uint32: 1_700_000_000) // atime
    w.write(uint32: 1_700_000_500) // mtime

    var r = SFTPReader(w.bytes)
    let a = try! r.readAttributes()
    expectEqual(a.size, 4096, "size parsed")
    expectEqual(a.uid, 501, "uid parsed")
    expectEqual(a.gid, 20, "gid parsed")
    expect(a.isDirectory, "directory bit recognised")
    expect(!a.isRegularFile, "not a regular file")
    expect(!a.isSymlink, "not a symlink")
    expectEqual(a.permissionString, "rwxr-xr-x", "permission rendering")
    expectEqual(a.modifyTimeEpoch, 1_700_000_500, "mtime parsed")
    expect(r.isAtEnd, "attributes consumed exactly")
}

do {
    // Only the size flag set: everything else must be skipped, not misread.
    var w = SFTPWriter()
    w.write(uint32: SFTPAttributeFlags.size.rawValue)
    w.write(uint64: 123)
    var r = SFTPReader(w.bytes)
    let a = try! r.readAttributes()
    expectEqual(a.size, 123, "size-only attributes")
    expectEqual(a.permissions, 0, "absent permissions stay zero")
    expect(a.modifyTimeEpoch == nil, "absent mtime stays nil")
    expect(r.isAtEnd, "size-only consumed exactly")
}

do {
    // A regular file, 0644.
    var w = SFTPWriter()
    w.write(uint32: SFTPAttributeFlags.permissions.rawValue)
    w.write(uint32: 0o100644)
    var r = SFTPReader(w.bytes)
    let a = try! r.readAttributes()
    expect(a.isRegularFile, "regular file bit")
    expect(!a.isDirectory, "regular file is not a directory")
    expectEqual(a.permissionString, "rw-r--r--", "0644 rendering")
}

do {
    // Symlink, 0777.
    var w = SFTPWriter()
    w.write(uint32: SFTPAttributeFlags.permissions.rawValue)
    w.write(uint32: 0o120777)
    var r = SFTPReader(w.bytes)
    let a = try! r.readAttributes()
    expect(a.isSymlink, "symlink bit")
    expectEqual(a.permissionString, "rwxrwxrwx", "0777 rendering")
}

do {
    // Extended pairs must be consumed so following fields stay aligned.
    var w = SFTPWriter()
    w.write(uint32: (SFTPAttributeFlags.size.rawValue | SFTPAttributeFlags.extended.rawValue))
    w.write(uint64: 7)
    w.write(uint32: 1)
    w.write(string: "acl")
    w.write(string: "everyone@")
    w.write(uint32: 0xABCD)  // sentinel that must survive

    var r = SFTPReader(w.bytes)
    let a = try! r.readAttributes()
    expectEqual(a.size, 7, "size before extended block")
    expectEqual(a.extended["acl"], "everyone@", "extended pair parsed")
    expectEqual(try! r.readUInt32(), 0xABCD, "stream stayed aligned past extended block")
}

do {
    // A desynced stream claiming a huge extended count must be rejected.
    var w = SFTPWriter()
    w.write(uint32: SFTPAttributeFlags.extended.rawValue)
    w.write(uint32: 0xFFFF_FFFF)
    var r = SFTPReader(w.bytes)
    var threw = false
    do { _ = try r.readAttributes() } catch { threw = true }
    expect(threw, "absurd extended count rejected")
}

print("== Permission rendering across the range ==")
do {
    expectEqual(SFTPFileAttributes.renderPermissions(0o000), "---------", "0000")
    expectEqual(SFTPFileAttributes.renderPermissions(0o777), "rwxrwxrwx", "0777")
    expectEqual(SFTPFileAttributes.renderPermissions(0o600), "rw-------", "0600")
    expectEqual(SFTPFileAttributes.renderPermissions(0o755), "rwxr-xr-x", "0755")
    expectEqual(SFTPFileAttributes.renderPermissions(0o644), "rw-r--r--", "0644")
    expectEqual(SFTPFileAttributes.renderPermissions(0o111), "--x--x--x", "0111")
    // High file-type bits must not leak into the string.
    expectEqual(SFTPFileAttributes.renderPermissions(0o040755), "rwxr-xr-x", "type bits masked off")
}

print("== Permission parsing ==")
do {
    expectEqual(SFTPFileAttributes.parsePermissions("644"), 0o644, "three octal digits")
    expectEqual(SFTPFileAttributes.parsePermissions("0644"), 0o644, "leading zero accepted")
    expectEqual(SFTPFileAttributes.parsePermissions("777"), 0o777, "0777")
    expectEqual(SFTPFileAttributes.parsePermissions("0"), 0o000, "bare zero")
    expectEqual(SFTPFileAttributes.parsePermissions("  644  "), 0o644, "surrounding space ignored")

    expectEqual(SFTPFileAttributes.parsePermissions("rw-r--r--"), 0o644, "symbolic rw-r--r--")
    expectEqual(SFTPFileAttributes.parsePermissions("rwxr-xr-x"), 0o755, "symbolic rwxr-xr-x")
    expectEqual(SFTPFileAttributes.parsePermissions("---------"), 0o000, "symbolic all off")
    expectEqual(SFTPFileAttributes.parsePermissions("rwxrwxrwx"), 0o777, "symbolic all on")
    expectEqual(SFTPFileAttributes.parsePermissions("--x--x--x"), 0o111, "symbolic exec only")

    // Anything that is not a mode must be rejected, not coerced.
    expect(SFTPFileAttributes.parsePermissions("") == nil, "empty rejected")
    expect(SFTPFileAttributes.parsePermissions("   ") == nil, "blank rejected")
    expect(SFTPFileAttributes.parsePermissions("888") == nil, "non-octal digits rejected")
    expect(SFTPFileAttributes.parsePermissions("99999") == nil, "too many digits rejected")
    expect(SFTPFileAttributes.parsePermissions("1777") == nil, "sticky bit out of range rejected")
    expect(SFTPFileAttributes.parsePermissions("rwxr-xr") == nil, "short symbolic rejected")
    expect(SFTPFileAttributes.parsePermissions("rwxr-xr-xx") == nil, "long symbolic rejected")
    expect(SFTPFileAttributes.parsePermissions("xwrxwrxwr") == nil, "wrong letter order rejected")
    expect(SFTPFileAttributes.parsePermissions("rw-r--r-Z") == nil, "stray letter rejected")
    expect(SFTPFileAttributes.parsePermissions("hello") == nil, "words rejected")

    // The pair must agree across the whole range they are defined on.
    var roundTripped = true
    for mode in UInt32(0)...UInt32(0o777) {
        let rendered = SFTPFileAttributes.renderPermissions(mode)
        if SFTPFileAttributes.parsePermissions(rendered) != mode { roundTripped = false; break }
    }
    expect(roundTripped, "render → parse round-trips for all 512 modes")
}

print("== Glob matching (WinSCP mask semantics) ==")
do {
    expect(Glob.match(pattern: "*", name: "anything"), "* matches anything")
    expect(Glob.match(pattern: "*", name: ""), "* matches empty")
    expect(Glob.match(pattern: "*.txt", name: "notes.txt"), "*.txt matches notes.txt")
    expect(!Glob.match(pattern: "*.txt", name: "notes.txtx"), "*.txt rejects notes.txtx")
    expect(!Glob.match(pattern: "*.txt", name: "txt"), "*.txt rejects bare txt")
    expect(Glob.match(pattern: "*.txt", name: ".txt"), "*.txt matches .txt")
    expect(Glob.match(pattern: "?.c", name: "a.c"), "?.c matches a.c")
    expect(!Glob.match(pattern: "?.c", name: "ab.c"), "?.c rejects ab.c")
    expect(!Glob.match(pattern: "?", name: ""), "? requires one character")
    expect(Glob.match(pattern: "a*b*c", name: "axxbyyc"), "multi-star match")
    expect(!Glob.match(pattern: "a*b*c", name: "axxbyy"), "multi-star rejects missing tail")
    expect(Glob.match(pattern: "backup*", name: "BACKUP_2024.tar"), "case-insensitive")
    expect(Glob.match(pattern: "*.TXT", name: "file.txt"), "case-insensitive both ways")
    expect(Glob.match(pattern: "exact", name: "exact"), "literal match")
    expect(!Glob.match(pattern: "exact", name: "exactly"), "literal rejects prefix-of")
    expect(Glob.match(pattern: "**", name: "x"), "consecutive stars")
    expect(Glob.match(pattern: "*a*", name: "a"), "stars around single char")

    // The pathological case that makes the recursive version blow up.
    let evil = String(repeating: "a", count: 60)
    expect(!Glob.match(pattern: "*a*a*a*a*a*a*b", name: evil), "backtracking case terminates")
}

print("")
if failures == 0 {
    print("ALL PASS — \(checks) checks")
} else {
    print("\(failures) FAILED of \(checks) checks")
}
