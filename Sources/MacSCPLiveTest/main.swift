import Foundation
import SFTPKit
import CoreKit
import AppCore

// End-to-end exercise of SFTPKit against a real SFTP server.
//
//   swift run MacSCPLiveTest <target> [port] [ssh options...]
//   swift run MacSCPLiveTest ziga@127.0.0.1 2222 -o IdentitiesOnly=yes -i /path/key
//
// Everything happens inside a temporary directory under the login directory,
// and the directory is removed at the end.

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ label: String) {
    checks += 1
    print("  \(condition ? "ok  " : "FAIL") \(label)")
    if !condition { failures += 1 }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual == expected {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)\n         expected: \(expected)\n         actual:   \(actual)")
        failures += 1
    }
}

func section(_ name: String) { print("\n== \(name) ==") }

/// Progress callbacks are `@Sendable` and now fire from pipelined transfer
/// work, so observing them needs a lock rather than a captured `var`.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var hits = 0
    func record(_ v: UInt64) {
        lock.lock(); value = max(value, v); hits += 1; lock.unlock()
    }
    var peak: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    var callbackCount: Int { lock.lock(); defer { lock.unlock() }; return hits }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let target = args.first else {
    print("usage: MacSCPLiveTest <target> [port] [ssh options...]")
    exit(2)
}
var port: Int?
var sshOptions: [String] = []
if args.count > 1 {
    if let p = Int(args[1]) {
        port = p
        sshOptions = Array(args.dropFirst(2))
    } else {
        sshOptions = Array(args.dropFirst(1))
    }
}

print("target:  \(target)")
print("port:    \(port.map(String.init) ?? "22 (default)")")
print("options: \(sshOptions.joined(separator: " "))")

let client = SFTPClient()
let localScratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("macscp-live-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: localScratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: localScratch) }

var remoteBase = ""

do {
    section("Connect")
    try await client.connect(target: target, port: port, extraOptions: sshOptions)
    let version = await client.serverVersion
    expect(await client.isConnected, "session is connected")
    expectEqual(version, 3, "negotiated protocol version")

    section("REALPATH")
    let home = try await client.realPath(".")
    expect(home.hasPrefix("/"), "login directory is absolute (\(home))")

    let dirName = "macscp-live-\(UUID().uuidString.prefix(8))"
    remoteBase = home.hasSuffix("/") ? home + dirName : home + "/" + dirName

    section("MKDIR / LIST")
    try await client.makeDirectory(remoteBase)
    let parent = try await client.listDirectory(home)
    expect(parent.contains { $0.filename == dirName }, "new directory appears in parent listing")
    expect(parent.first { $0.filename == dirName }?.attributes.isDirectory == true,
           "new entry is typed as a directory")
    expect(!parent.contains { $0.filename == "." || $0.filename == ".." },
           "dot entries filtered from listings")

    let empty = try await client.listDirectory(remoteBase)
    expectEqual(empty.count, 0, "new directory is empty")

    section("STAT")
    let dirAttrs = try await client.stat(remoteBase)
    expect(dirAttrs.isDirectory, "stat reports a directory")
    expect(!dirAttrs.permissionString.isEmpty, "stat returns permissions (\(dirAttrs.permissionString))")

    section("Upload / download: small text file")
    let smallName = "hello.txt"
    let smallBody = "hello from MacSCP — naïve ✓ 日本語\n"
    let smallLocal = localScratch.appendingPathComponent(smallName)
    try smallBody.write(to: smallLocal, atomically: true, encoding: .utf8)

    let smallRemote = remoteBase + "/" + smallName
    try await client.upload(localURL: smallLocal, to: smallRemote)

    let afterUpload = try await client.listDirectory(remoteBase)
    expectEqual(afterUpload.count, 1, "one file after upload")
    expectEqual(afterUpload.first?.filename, smallName, "uploaded filename")
    expectEqual(afterUpload.first?.attributes.size, UInt64(Data(smallBody.utf8).count),
                "remote size matches local byte count")

    let smallBack = localScratch.appendingPathComponent("hello-roundtrip.txt")
    try await client.download(remote: smallRemote, to: smallBack)
    let recovered = try String(contentsOf: smallBack, encoding: .utf8)
    expectEqual(recovered, smallBody, "text round-trips byte-identically (UTF-8 preserved)")

    section("Upload / download: multi-chunk binary")
    // The engine reads and writes in 32 KiB chunks, so 200 KiB forces several
    // round trips and exercises offset arithmetic on both paths.
    var rng = SystemRandomNumberGenerator()
    let bigBytes = (0..<(200 * 1024)).map { _ in UInt8.random(in: 0...255, using: &rng) }
    let bigData = Data(bigBytes)
    let bigLocal = localScratch.appendingPathComponent("blob.bin")
    try bigData.write(to: bigLocal)

    let bigRemote = remoteBase + "/blob.bin"
    let upCounter = Counter()
    try await client.upload(localURL: bigLocal, to: bigRemote) { done, _ in
        upCounter.record(done)
    }
    expectEqual(upCounter.peak, UInt64(bigData.count), "upload progress reached the full size")

    let bigAttrs = try await client.stat(bigRemote)
    expectEqual(bigAttrs.size, UInt64(bigData.count), "remote size matches after multi-chunk upload")

    let bigBack = localScratch.appendingPathComponent("blob-roundtrip.bin")
    let downCounter = Counter()
    try await client.download(remote: bigRemote, to: bigBack) { done, _ in
        downCounter.record(done)
    }
    let recoveredData = try Data(contentsOf: bigBack)
    expectEqual(recoveredData.count, bigData.count, "downloaded byte count")
    expect(recoveredData == bigData, "200 KiB of random bytes round-trip identically")
    expectEqual(downCounter.peak, UInt64(bigData.count), "download progress reached the full size")
    expect(downCounter.callbackCount > 1, "progress reported incrementally, not just at the end")

    section("Pipelining: unaligned size crossing many windows")
    // 1 MiB + 1 byte is not a multiple of the 32 KiB chunk or the 16-deep
    // window, so the final window is partial and the last read is short —
    // the case where offset arithmetic goes wrong.
    let oddBytes = (0..<(1024 * 1024 + 1)).map { UInt8($0 % 251) }
    let oddLocal = localScratch.appendingPathComponent("odd.bin")
    try Data(oddBytes).write(to: oddLocal)
    let oddRemote = remoteBase + "/odd.bin"
    try await client.upload(localURL: oddLocal, to: oddRemote)
    expectEqual(try await client.stat(oddRemote).size, UInt64(oddBytes.count),
                "unaligned upload size exact")

    let oddBack = localScratch.appendingPathComponent("odd-back.bin")
    try await client.download(remote: oddRemote, to: oddBack)
    let oddRecovered = [UInt8](try Data(contentsOf: oddBack))
    expectEqual(oddRecovered.count, oddBytes.count, "unaligned download size exact")
    expect(oddRecovered == oddBytes, "1 MiB + 1 byte round-trips identically")

    section("Non-ASCII filename")
    let unicodeName = "föö-日本語.txt"
    let unicodeLocal = localScratch.appendingPathComponent("u.txt")
    try "unicode name test\n".write(to: unicodeLocal, atomically: true, encoding: .utf8)
    try await client.upload(localURL: unicodeLocal, to: remoteBase + "/" + unicodeName)
    let unicodeListing = try await client.listDirectory(remoteBase)
    expect(unicodeListing.contains { $0.filename == unicodeName },
           "non-ASCII filename survives the round trip")

    section("RENAME")
    try await client.rename(from: smallRemote, to: remoteBase + "/renamed.txt")
    let afterRename = try await client.listDirectory(remoteBase)
    expect(afterRename.contains { $0.filename == "renamed.txt" }, "new name present")
    expect(!afterRename.contains { $0.filename == smallName }, "old name gone")

    section("SETSTAT (chmod)")
    try await client.setPermissions(remoteBase + "/renamed.txt", mode: 0o600)
    let chmodded = try await client.stat(remoteBase + "/renamed.txt")
    expectEqual(chmodded.permissionString, "rw-------", "permissions applied")

    section("Recursive directory upload")
    // tree/
    //   a.txt
    //   sub/b.txt
    //   sub/deeper/c.bin
    //   link -> a.txt   (must be skipped, not followed)
    let tree = localScratch.appendingPathComponent("tree")
    let deeper = tree.appendingPathComponent("sub/deeper")
    try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
    try "alpha\n".write(to: tree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "beta\n".write(to: tree.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
    let cBytes = Data((0..<70_000).map { UInt8($0 % 253) })
    try cBytes.write(to: deeper.appendingPathComponent("c.bin"))
    try? FileManager.default.createSymbolicLink(
        at: tree.appendingPathComponent("link"),
        withDestinationURL: tree.appendingPathComponent("a.txt"))

    let remoteTree = remoteBase + "/tree"
    let transferred = Counter()
    try await client.uploadDirectory(localURL: tree, to: remoteTree) { _, done, _ in
        transferred.record(done)
    }

    expectEqual(try await client.listDirectory(remoteTree).count, 2,
                "top level has a.txt and sub (symlink skipped)")
    expect(try await client.stat(remoteTree + "/a.txt").isRegularFile, "nested file uploaded")
    expect(try await client.stat(remoteTree + "/sub").isDirectory, "subdirectory created")
    expectEqual(try await client.stat(remoteTree + "/sub/deeper/c.bin").size, 70_000,
                "two-levels-deep file uploaded with correct size")

    var linkThrew = false
    do { _ = try await client.stat(remoteTree + "/link") } catch { linkThrew = true }
    expect(linkThrew, "symlink was not followed or copied")

    section("Recursive directory download")
    let treeBack = localScratch.appendingPathComponent("tree-back")
    try await client.downloadDirectory(remote: remoteTree, to: treeBack)

    let backA = try String(contentsOf: treeBack.appendingPathComponent("a.txt"), encoding: .utf8)
    expectEqual(backA, "alpha\n", "top-level file round-trips")
    let backB = try String(
        contentsOf: treeBack.appendingPathComponent("sub/b.txt"), encoding: .utf8)
    expectEqual(backB, "beta\n", "nested file round-trips")
    let backC = try Data(contentsOf: treeBack.appendingPathComponent("sub/deeper/c.bin"))
    expect(backC == cBytes, "deep binary file round-trips identically")

    section("Recursive delete")
    try await client.removeDirectoryRecursively(remoteTree)
    var treeGone = false
    do { _ = try await client.stat(remoteTree) } catch { treeGone = true }
    expect(treeGone, "recursive delete removed the whole tree")

    section("makeDirectoryIfNeeded is idempotent")
    let idem = remoteBase + "/idem"
    try await client.makeDirectoryIfNeeded(idem)
    try await client.makeDirectoryIfNeeded(idem)
    expect(try await client.stat(idem).isDirectory, "second mkdir on existing dir is a no-op")
    try await client.removeDirectory(idem)

    // ---------------------------------------------------------------------
    // Everything above drives SFTPKit directly. This section drives AppModel —
    // the object the SwiftUI views are bound to — so the wiring between the UI
    // layer and the engine is executed rather than merely reviewed. The views
    // themselves are thin: they read published properties and call these
    // methods, which is exactly what runs here.
    // ---------------------------------------------------------------------
    section("AppModel: connect and browse")

    let appRemote = remoteBase + "/app"
    try await client.makeDirectory(appRemote)

    let appLocal = localScratch.appendingPathComponent("app-local")
    try FileManager.default.createDirectory(at: appLocal, withIntermediateDirectories: true)

    // A throwaway store so the real ~/Library/.../sessions.json is untouched.
    let storeURL = localScratch.appendingPathComponent("sessions.json")
    let model = AppModel(sessionStore: SessionStore(url: storeURL))
    model.localURL = appLocal
    model.refreshLocal()

    var appSession = SessionData(
        name: "live", hostName: "127.0.0.1", userName: NSUserName(),
        portNumber: port ?? 22, remoteDirectory: appRemote)
    appSession.sshOptions = sshOptions

    await model.connect(appSession)
    expect(model.isConnected, "model reports connected")
    expectEqual(model.remotePath, appRemote, "model landed in the configured remote directory")
    expect(model.log.contains { $0.text.hasPrefix("Connected") }, "connection logged")
    expect(!model.log.contains { $0.isError }, "no errors logged during connect")
    expectEqual(model.remoteItems.count, 0, "remote pane starts empty")

    section("AppModel: create directory and navigate")
    await model.createDirectory(on: .remote, named: "sub")
    await model.refreshRemote()
    expectEqual(model.remoteItems.count, 1, "created directory shows in the pane")
    expect(model.remoteItems.first?.isDirectory == true, "shown as a directory")

    if let sub = model.remoteItems.first {
        await model.enterRemote(sub)
    }
    expectEqual(model.remotePath, appRemote + "/sub", "navigated into the subdirectory")
    await model.remoteGoUp()
    expectEqual(model.remotePath, appRemote, "navigated back up")

    section("AppModel: upload via the pane selection")
    let payload = "uploaded through AppModel\n"
    try payload.write(to: appLocal.appendingPathComponent("up.txt"),
                      atomically: true, encoding: .utf8)
    model.refreshLocal()
    model.localSelection = ["up.txt"]
    expect(model.localItems.contains { $0.name == "up.txt" }, "local pane sees the new file")

    model.uploadSelected()
    expectEqual(model.queue.items.count, 1, "upload was enqueued")
    await model.queue.waitUntilIdle()
    expectEqual(model.queue.items.first?.state, .completed, "queue item completed")
    expect(model.remoteItems.contains { $0.name == "up.txt" },
           "remote pane refreshed itself after upload")
    expectEqual(try await client.stat(appRemote + "/up.txt").size, UInt64(payload.utf8.count),
                "uploaded content reached the server")

    section("AppModel: download via the pane selection")
    try FileManager.default.removeItem(at: appLocal.appendingPathComponent("up.txt"))
    model.refreshLocal()
    model.remoteSelection = ["up.txt"]
    model.downloadSelected()
    await model.queue.waitUntilIdle()
    let roundTripped = try? String(
        contentsOf: appLocal.appendingPathComponent("up.txt"), encoding: .utf8)
    expectEqual(roundTripped, payload, "file came back through the model with identical content")
    expect(model.localItems.contains { $0.name == "up.txt" },
           "local pane refreshed itself after download")

    section("AppModel: recursive folder upload via selection")
    let folder = appLocal.appendingPathComponent("folder/inner")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "deep\n".write(to: folder.appendingPathComponent("deep.txt"),
                       atomically: true, encoding: .utf8)
    model.refreshLocal()
    model.localSelection = ["folder"]
    model.uploadSelected()
    await model.queue.waitUntilIdle()
    expectEqual(try await client.stat(appRemote + "/folder/inner/deep.txt").size, 5,
                "nested file uploaded through the model")

    section("AppModel: recursive delete via selection")
    model.remoteSelection = ["folder"]
    await model.deleteSelected(on: .remote)
    var folderGone = false
    do { _ = try await client.stat(appRemote + "/folder") } catch { folderGone = true }
    expect(folderGone, "non-empty remote folder deleted through the model")
    expect(model.remoteSelection.isEmpty, "selection cleared after delete")

    section("AppModel: session persistence")
    model.saveSession(appSession)
    expectEqual(SessionStore(url: storeURL).load().count, 1, "session saved to the injected store")
    model.deleteSession(appSession)
    expectEqual(SessionStore(url: storeURL).load().count, 0, "session deleted from the store")

    section("AppModel: failure surfaces in the log")
    let badModel = AppModel(sessionStore: SessionStore(url: storeURL))
    await badModel.connect(SessionData(hostName: "127.0.0.1", userName: "nosuchuser", portNumber: port ?? 22))
    expect(!badModel.isConnected, "bad credentials do not report connected")
    expect(badModel.log.contains { $0.isError }, "failure recorded as an error entry")

    let blankModel = AppModel(sessionStore: SessionStore(url: storeURL))
    await blankModel.connect(SessionData())
    expect(blankModel.log.contains { $0.isError }, "empty host rejected with an error")

    section("Resume: download picks up from a partial local file")
    // 500 KiB so the transfer spans many pipeline windows.
    let resumeBytes = (0..<(500 * 1024)).map { UInt8($0 % 241) }
    let resumeLocal = localScratch.appendingPathComponent("resume-source.bin")
    try Data(resumeBytes).write(to: resumeLocal)
    let resumeRemote = appRemote + "/resume.bin"
    try await client.upload(localURL: resumeLocal, to: resumeRemote)

    // Simulate an interrupted download: only the first 100 KiB landed.
    let partialLocal = localScratch.appendingPathComponent("resume-partial.bin")
    try Data(resumeBytes.prefix(100 * 1024)).write(to: partialLocal)

    try await client.download(remote: resumeRemote, to: partialLocal, resume: true)
    let resumedDown = [UInt8](try Data(contentsOf: partialLocal))
    expectEqual(resumedDown.count, resumeBytes.count, "resumed download reached full size")
    expect(resumedDown == resumeBytes, "resumed download content is correct end to end")

    // Resuming an already-complete file must be a no-op, not a duplication.
    try await client.download(remote: resumeRemote, to: partialLocal, resume: true)
    expectEqual([UInt8](try Data(contentsOf: partialLocal)).count, resumeBytes.count,
                "resuming a complete file does not append again")

    section("Resume: upload picks up from a partial remote file")
    let partialRemote = appRemote + "/resume-up.bin"
    let truncatedLocal = localScratch.appendingPathComponent("truncated.bin")
    try Data(resumeBytes.prefix(120 * 1024)).write(to: truncatedLocal)
    try await client.upload(localURL: truncatedLocal, to: partialRemote)
    expectEqual(try await client.stat(partialRemote).size, UInt64(120 * 1024),
                "partial remote file in place")

    try await client.upload(localURL: resumeLocal, to: partialRemote, resume: true)
    expectEqual(try await client.stat(partialRemote).size, UInt64(resumeBytes.count),
                "resumed upload reached full size")

    let verifyBack = localScratch.appendingPathComponent("verify-up.bin")
    try await client.download(remote: partialRemote, to: verifyBack)
    expect([UInt8](try Data(contentsOf: verifyBack)) == resumeBytes,
           "resumed upload content is correct end to end")

    section("Queue: cancelling queued items")
    model.remoteSelection = []
    model.localSelection = []
    let queueSource = appLocal.appendingPathComponent("q.bin")
    try Data(resumeBytes).write(to: queueSource)
    model.refreshLocal()

    model.queue.clearFinished()
    let a = TransferItem(name: "q1.bin", direction: .upload, localURL: queueSource,
                         remotePath: appRemote + "/q1.bin")
    let b = TransferItem(name: "q2.bin", direction: .upload, localURL: queueSource,
                         remotePath: appRemote + "/q2.bin")
    let c = TransferItem(name: "q3.bin", direction: .upload, localURL: queueSource,
                         remotePath: appRemote + "/q3.bin")
    model.queue.enqueue([a, b, c])
    // The queue is serial, so b and c are still queued while a runs.
    model.queue.cancel(b.id)
    model.queue.cancel(c.id)
    await model.queue.waitUntilIdle()

    expectEqual(model.queue.items.first { $0.id == a.id }?.state, .completed, "first item completed")
    expectEqual(model.queue.items.first { $0.id == b.id }?.state, .cancelled, "queued item cancelled")
    expectEqual(model.queue.items.first { $0.id == c.id }?.state, .cancelled, "second queued item cancelled")
    var cancelledExists = false
    do { _ = try await client.stat(appRemote + "/q2.bin") } catch { cancelledExists = true }
    expect(cancelledExists, "cancelled transfer never created its remote file")

    section("Queue: failure and retry")
    model.queue.clearFinished()
    model.queue.enqueue(TransferItem(
        name: "ghost.bin", direction: .download,
        localURL: appLocal.appendingPathComponent("ghost.bin"),
        remotePath: appRemote + "/definitely-not-here.bin"))
    await model.queue.waitUntilIdle()
    expectEqual(model.queue.failedCount, 1, "missing remote file fails the queue item")
    expect(model.queue.items.first?.state.isFailed == true, "state carries the failure")

    expectEqual(model.queue.retryFailed(), 1, "retryFailed re-queues the item")
    await model.queue.waitUntilIdle()
    expectEqual(model.queue.failedCount, 1, "still fails on retry, as expected")
    model.queue.clearFinished()
    expectEqual(model.queue.items.count, 0, "clearFinished empties the queue")

    section("Drag and drop entry point")
    // enqueueTransfer is what a pane drop calls; it must work off names alone,
    // independently of the current selection.
    model.localSelection = []
    model.refreshLocal()
    model.enqueueTransfer(names: ["q.bin"], direction: .upload)
    expectEqual(model.queue.items.count, 1, "drop enqueued one transfer")
    expectEqual(model.queue.items.first?.direction, .upload, "direction taken from the drop target")
    await model.queue.waitUntilIdle()
    expectEqual(model.queue.items.first?.state, .completed, "dropped transfer completed")
    expectEqual(try await client.stat(appRemote + "/q.bin").size, UInt64(resumeBytes.count),
                "dropped file reached the server intact")

    model.enqueueTransfer(names: ["nothing-here.bin"], direction: .upload)
    expectEqual(model.queue.items.count, 1, "unknown name enqueues nothing")
    model.queue.clearFinished()

    section("AppModel: disconnect")
    await model.disconnect()
    expect(!model.isConnected, "model reports disconnected")
    expectEqual(model.remoteItems.count, 0, "remote pane cleared on disconnect")

    try await client.removeDirectoryRecursively(appRemote)

    section("Error handling")
    var missingThrew = false
    var missingStatus: SFTPStatus?
    do {
        _ = try await client.stat(remoteBase + "/does-not-exist")
    } catch let SFTPError.server(status, _) {
        missingThrew = true
        missingStatus = status
    } catch {
        missingThrew = true
    }
    expect(missingThrew, "stat on a missing file throws")
    expectEqual(missingStatus, .noSuchFile, "missing file maps to SSH_FX_NO_SUCH_FILE")

    var rmdirThrew = false
    do {
        try await client.removeDirectory(remoteBase)  // not empty
    } catch {
        rmdirThrew = true
    }
    expect(rmdirThrew, "rmdir on a non-empty directory throws")

    // Optional throughput measurement: MACSCP_BENCH_MB=32 swift run MacSCPLiveTest ...
    if let mbText = ProcessInfo.processInfo.environment["MACSCP_BENCH_MB"],
       let mb = Int(mbText), mb > 0 {
        section("Throughput (\(mb) MiB)")
        let payload = Data((0..<(mb * 1024 * 1024)).map { UInt8($0 % 256) })
        let benchLocal = localScratch.appendingPathComponent("bench.bin")
        try payload.write(to: benchLocal)
        let benchRemote = remoteBase + "/bench.bin"

        let upStart = Date()
        try await client.upload(localURL: benchLocal, to: benchRemote)
        let upSeconds = Date().timeIntervalSince(upStart)

        let benchBack = localScratch.appendingPathComponent("bench-back.bin")
        let downStart = Date()
        try await client.download(remote: benchRemote, to: benchBack)
        let downSeconds = Date().timeIntervalSince(downStart)

        let mbd = Double(mb)
        print(String(format: "  upload   %.2f s  (%.1f MiB/s)", upSeconds, mbd / upSeconds))
        print(String(format: "  download %.2f s  (%.1f MiB/s)", downSeconds, mbd / downSeconds))

        expectEqual(try await client.stat(benchRemote).size, UInt64(payload.count),
                    "benchmark upload size exact")
        expect(try Data(contentsOf: benchBack) == payload, "benchmark payload round-trips identically")
        try await client.removeFile(benchRemote)
    }

    section("REMOVE / RMDIR cleanup")
    for entry in try await client.listDirectory(remoteBase) {
        try await client.removeFile(remoteBase + "/" + entry.filename)
    }
    expectEqual(try await client.listDirectory(remoteBase).count, 0, "directory emptied")

    try await client.removeDirectory(remoteBase)
    let finalParent = try await client.listDirectory(home)
    expect(!finalParent.contains { $0.filename == dirName }, "test directory removed")
    remoteBase = ""

    section("Disconnect")
    await client.disconnect()
    expect(!(await client.isConnected), "session reports disconnected")

} catch {
    let message = (error as? SFTPError)?.message ?? error.localizedDescription
    print("\nFATAL: \(message)")
    failures += 1

    if !remoteBase.isEmpty {
        print("note: leftover remote directory may remain at \(remoteBase)")
    }
    await client.disconnect()
}

print("")
if failures == 0 {
    print("ALL PASS — \(checks) checks")
    exit(0)
} else {
    print("\(failures) FAILED of \(checks) checks")
    exit(1)
}
