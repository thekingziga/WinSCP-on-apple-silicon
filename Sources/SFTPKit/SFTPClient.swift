import Foundation

/// One entry in a remote directory listing.
public struct SFTPName: Sendable, Identifiable, Equatable {
    public var filename: String
    public var longname: String
    public var attributes: SFTPFileAttributes
    public var id: String { filename }

    public init(filename: String, longname: String, attributes: SFTPFileAttributes) {
        self.filename = filename
        self.longname = longname
        self.attributes = attributes
    }
}

/// A decoded server response.
enum SFTPResponse: Sendable {
    case status(SFTPStatus, String)
    case handle([UInt8])
    case data([UInt8])
    case name([SFTPName])
    case attrs(SFTPFileAttributes)
    case version(UInt32)
}

/// Progress callback for transfers: (bytesSoFar, totalBytes).
public typealias SFTPProgress = @Sendable (UInt64, UInt64) -> Void

/// An SFTP session.
///
/// Port of the request/response engine in WinSCP `source/core/SftpFileSystem.cpp`,
/// expressed with Swift actors instead of the VCL's callback plumbing. Each
/// request carries a monotonic id; the reader thread resumes the matching
/// continuation.
public actor SFTPClient {
    private var transport: SSHTransport?
    private var nextRequestID: UInt32 = 1
    private var pending: [UInt32: CheckedContinuation<SFTPResponse, Error>] = [:]
    private var versionContinuation: CheckedContinuation<SFTPResponse, Error>?
    private var closed = false
    private var closeError: Error?

    public private(set) var serverVersion: UInt32 = 0
    public private(set) var isConnected = false

    public init() {}

    // MARK: - Connection

    public func connect(target: String, port: Int? = nil, extraOptions: [String] = []) async throws {
        let transport = SSHTransport(
            onPacket: { [weak self] type, body in
                guard let self else { return }
                Task { await self.handlePacket(type: type, body: body) }
            },
            onClose: { [weak self] error in
                guard let self else { return }
                Task { await self.handleClose(error) }
            }
        )
        self.transport = transport

        do {
            try transport.start(target: target, port: port, extraOptions: extraOptions)
        } catch {
            self.transport = nil
            throw error
        }

        // SSH_FXP_INIT carries the version in place of a request id.
        var w = SFTPWriter()
        w.write(uint32: sftpClientVersion)

        let response: SFTPResponse = try await withCheckedThrowingContinuation { cont in
            self.versionContinuation = cont
            do {
                try transport.send(w.framed(type: .initialize))
            } catch {
                self.versionContinuation = nil
                cont.resume(throwing: error)
            }
        }

        guard case .version(let v) = response else {
            throw SFTPError.handshakeFailed("server did not answer SSH_FXP_INIT")
        }
        serverVersion = v
        isConnected = true
    }

    public func disconnect() {
        transport?.stop()
        transport = nil
        isConnected = false
        failAllPending(SFTPError.notConnected)
    }

    // MARK: - Packet dispatch

    private func handlePacket(type: UInt8, body: [UInt8]) {
        var reader = SFTPReader(body)

        guard let packetType = SFTPPacketType(rawValue: type) else {
            return  // Unknown packet types are ignored, as WinSCP does.
        }

        if packetType == .version {
            let v = (try? reader.readUInt32()) ?? 0
            versionContinuation?.resume(returning: .version(v))
            versionContinuation = nil
            return
        }

        guard let requestID = try? reader.readUInt32() else { return }
        guard let cont = pending.removeValue(forKey: requestID) else { return }

        do {
            switch packetType {
            case .status:
                let code = try reader.readUInt32()
                // Version 3+ appends a human-readable message and language tag.
                let message = (try? reader.readString()) ?? ""
                let status = SFTPStatus(rawValue: code) ?? .failure
                cont.resume(returning: .status(status, message))

            case .handle:
                cont.resume(returning: .handle(try reader.readBytes()))

            case .data:
                cont.resume(returning: .data(try reader.readBytes()))

            case .name:
                let count = try reader.readUInt32()
                var names: [SFTPName] = []
                names.reserveCapacity(Int(count))
                for _ in 0..<count {
                    let filename = try reader.readString()
                    let longname = try reader.readString()
                    let attrs = try reader.readAttributes()
                    names.append(SFTPName(filename: filename, longname: longname, attributes: attrs))
                }
                cont.resume(returning: .name(names))

            case .attrs:
                cont.resume(returning: .attrs(try reader.readAttributes()))

            default:
                cont.resume(throwing: SFTPError.unexpectedPacket(type))
            }
        } catch {
            cont.resume(throwing: error)
        }
    }

    private func handleClose(_ error: Error?) {
        guard !closed else { return }
        closed = true
        isConnected = false
        closeError = error
        let failure = error ?? SFTPError.transportFailed("connection closed")
        versionContinuation?.resume(throwing: failure)
        versionContinuation = nil
        failAllPending(failure)
    }

    private func failAllPending(_ error: Error) {
        let conts = pending.values
        pending.removeAll()
        for c in conts { c.resume(throwing: error) }
    }

    // MARK: - Request plumbing

    private func send(_ type: SFTPPacketType, _ build: (inout SFTPWriter) -> Void) async throws -> SFTPResponse {
        guard let transport, !closed else {
            throw closeError ?? SFTPError.notConnected
        }
        let id = nextRequestID
        nextRequestID &+= 1
        if nextRequestID == 0 { nextRequestID = 1 }

        var w = SFTPWriter()
        w.write(uint32: id)
        build(&w)
        let packet = w.framed(type: type)

        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do {
                try transport.send(packet)
            } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: error)
            }
        }
    }

    /// Requires a status response of SSH_FX_OK.
    private func expectOK(_ response: SFTPResponse) throws {
        guard case .status(let status, let msg) = response else {
            throw SFTPError.malformedPacket("expected status")
        }
        guard status == .ok else { throw SFTPError.server(status, msg) }
    }

    // MARK: - Filesystem operations

    /// Canonicalize a path. Passing "." yields the login directory — how
    /// WinSCP determines the initial remote directory.
    public func realPath(_ path: String) async throws -> String {
        let response = try await send(.realpath) { $0.write(string: path) }
        switch response {
        case .name(let names):
            guard let first = names.first else {
                throw SFTPError.malformedPacket("empty REALPATH response")
            }
            return first.filename
        case .status(let s, let m):
            throw SFTPError.server(s, m)
        default:
            throw SFTPError.malformedPacket("unexpected REALPATH response")
        }
    }

    public func stat(_ path: String) async throws -> SFTPFileAttributes {
        let response = try await send(.stat) { $0.write(string: path) }
        switch response {
        case .attrs(let a): return a
        case .status(let s, let m): throw SFTPError.server(s, m)
        default: throw SFTPError.malformedPacket("unexpected STAT response")
        }
    }

    /// Full directory listing. SSH_FXP_READDIR returns a chunk at a time and
    /// signals completion with SSH_FX_EOF, so we loop.
    public func listDirectory(_ path: String) async throws -> [SFTPName] {
        let openResponse = try await send(.opendir) { $0.write(string: path) }
        guard case .handle(let handle) = openResponse else {
            if case .status(let s, let m) = openResponse { throw SFTPError.server(s, m) }
            throw SFTPError.malformedPacket("unexpected OPENDIR response")
        }
        defer { Task { try? await self.closeHandle(handle) } }

        var results: [SFTPName] = []
        while true {
            let response = try await send(.readdir) { $0.write(data: handle) }
            switch response {
            case .name(let names):
                results.append(contentsOf: names)
            case .status(let status, let msg):
                if status == .eof {
                    return results.filter { $0.filename != "." && $0.filename != ".." }
                }
                throw SFTPError.server(status, msg)
            default:
                throw SFTPError.malformedPacket("unexpected READDIR response")
            }
        }
    }

    public func makeDirectory(_ path: String) async throws {
        try expectOK(try await send(.mkdir) { w in
            w.write(string: path)
            w.write(uint32: 0)  // no attributes
        })
    }

    public func removeFile(_ path: String) async throws {
        try expectOK(try await send(.remove) { $0.write(string: path) })
    }

    public func removeDirectory(_ path: String) async throws {
        try expectOK(try await send(.rmdir) { $0.write(string: path) })
    }

    public func rename(from: String, to: String) async throws {
        try expectOK(try await send(.rename) { w in
            w.write(string: from)
            w.write(string: to)
        })
    }

    public func setPermissions(_ path: String, mode: UInt32) async throws {
        try expectOK(try await send(.setstat) { w in
            w.write(string: path)
            w.write(uint32: SFTPAttributeFlags.permissions.rawValue)
            w.write(uint32: mode)
        })
    }

    private func closeHandle(_ handle: [UInt8]) async throws {
        _ = try await send(.close) { $0.write(data: handle) }
    }

    // MARK: - Transfers

    /// Chunk size. OpenSSH's server caps a single READ at 256 KiB; 32 KiB is
    /// the conservative value WinSCP defaults to for wide compatibility.
    private static let chunkSize: UInt32 = 32 * 1024

    /// Outstanding requests kept in flight.
    ///
    /// One chunk at a time costs a full round trip per 32 KiB, so throughput
    /// collapses to `chunk / RTT` — on a 100 ms link that is about 320 KB/s no
    /// matter how much bandwidth is available. WinSCP pipelines for the same
    /// reason. Depth 16 keeps 512 KiB in flight, which saturates typical links
    /// without letting a stalled transfer buffer unboundedly.
    private static let pipelineDepth = 16

    private func openFile(_ path: String, flags: SFTPOpenFlags) async throws -> [UInt8] {
        let response = try await send(.open) { w in
            w.write(string: path)
            w.write(uint32: flags.rawValue)
            w.write(uint32: 0)
        }
        guard case .handle(let handle) = response else {
            if case .status(let s, let m) = response { throw SFTPError.server(s, m) }
            throw SFTPError.malformedPacket("unexpected OPEN response")
        }
        return handle
    }

    /// Download a remote file to a local URL.
    ///
    /// With `resume: true`, an existing local file is treated as a partial
    /// transfer and the download restarts at its current length. As in WinSCP,
    /// this assumes the existing bytes match the server's — SFTP gives us no
    /// cheap way to verify that, so a partial file from a *different* source
    /// would silently produce a corrupt result.
    public func download(
        remote: String,
        to localURL: URL,
        progress: SFTPProgress? = nil,
        resume: Bool = false
    ) async throws {
        let total = (try? await stat(remote))?.size ?? 0

        var startOffset: UInt64 = 0
        let fm = FileManager.default
        if resume, fm.fileExists(atPath: localURL.path) {
            let existing = (try? fm.attributesOfItem(atPath: localURL.path)[.size] as? UInt64) ?? 0
            // A local file at or beyond the remote size has nothing left to fetch.
            if existing >= total && total > 0 {
                progress?(total, total)
                return
            }
            startOffset = existing
        } else {
            fm.createFile(atPath: localURL.path, contents: nil)
        }

        let handle = try await openFile(remote, flags: .read)

        guard let out = FileHandle(forWritingAtPath: localURL.path) else {
            try? await closeHandle(handle)
            throw SFTPError.transportFailed("cannot open \(localURL.path) for writing")
        }

        do {
            var offset = startOffset
            var finished = false

            while !finished {
                try Task.checkCancellation()
                let base = offset
                // Fire a window of reads at successive offsets. Responses may
                // arrive in any order, so each is tagged with its slot.
                var results: [Int: [UInt8]?] = [:]
                try await withThrowingTaskGroup(of: (Int, [UInt8]?).self) { group in
                    for slot in 0..<Self.pipelineDepth {
                        let at = base + UInt64(slot) * UInt64(Self.chunkSize)
                        group.addTask {
                            let response = try await self.send(.read) { w in
                                w.write(data: handle)
                                w.write(uint64: at)
                                w.write(uint32: Self.chunkSize)
                            }
                            switch response {
                            case .data(let bytes):
                                return (slot, bytes)
                            case .status(let status, let message):
                                if status == .eof { return (slot, nil) }
                                throw SFTPError.server(status, message)
                            default:
                                throw SFTPError.malformedPacket("unexpected READ response")
                            }
                        }
                    }
                    for try await (slot, bytes) in group { results[slot] = bytes }
                }

                // Commit in slot order so the file is written contiguously.
                for slot in 0..<Self.pipelineDepth {
                    guard let entry = results[slot], let bytes = entry, !bytes.isEmpty else {
                        finished = true
                        break
                    }
                    try out.seek(toOffset: offset)
                    try out.write(contentsOf: Data(bytes))
                    offset += UInt64(bytes.count)
                    progress?(offset, max(total, offset))

                    // A short read means the server gave us less than asked for.
                    // Every later slot in this window was requested at an offset
                    // computed from the full chunk size and is therefore stale —
                    // discard them and re-issue from where we actually got to.
                    if bytes.count < Int(Self.chunkSize) { break }
                }
            }
            progress?(offset, max(total, offset))
        } catch {
            try? out.close()
            try? await closeHandle(handle)
            throw error
        }

        try? out.close()
        try await closeHandle(handle)
    }

    /// Upload a local file to a remote path.
    ///
    /// With `resume: true`, an existing remote file is treated as a partial
    /// transfer and the upload restarts at its current length. Same caveat as
    /// `download(remote:to:progress:resume:)`: the existing bytes are trusted.
    public func upload(
        localURL: URL,
        to remote: String,
        progress: SFTPProgress? = nil,
        resume: Bool = false
    ) async throws {
        guard let input = FileHandle(forReadingAtPath: localURL.path) else {
            throw SFTPError.transportFailed("cannot open \(localURL.path) for reading")
        }
        defer { try? input.close() }

        let total = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size]
            as? UInt64) ?? 0

        var startOffset: UInt64 = 0
        if resume, let existing = try? await stat(remote), existing.size > 0 {
            if existing.size >= total {
                progress?(total, total)
                return
            }
            startOffset = existing.size
            try input.seek(toOffset: startOffset)
        }

        // Resuming must not truncate what is already there.
        let flags: SFTPOpenFlags = startOffset > 0 ? [.write] : [.write, .create, .trunc]
        let handle = try await openFile(remote, flags: flags)

        do {
            var offset = startOffset
            while true {
                try Task.checkCancellation()
                // Reading locally is cheap, so fill a window before sending.
                var batch: [(offset: UInt64, bytes: [UInt8])] = []
                for _ in 0..<Self.pipelineDepth {
                    let chunk = input.readData(ofLength: Int(Self.chunkSize))
                    if chunk.isEmpty { break }
                    batch.append((offset, [UInt8](chunk)))
                    offset += UInt64(chunk.count)
                }
                if batch.isEmpty { break }

                // WRITEs carry absolute offsets, so they are order-independent.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for item in batch {
                        group.addTask {
                            let response = try await self.send(.write) { w in
                                w.write(data: handle)
                                w.write(uint64: item.offset)
                                w.write(data: item.bytes)
                            }
                            guard case .status(let status, let message) = response else {
                                throw SFTPError.malformedPacket("expected status for WRITE")
                            }
                            guard status == .ok else {
                                throw SFTPError.server(status, message)
                            }
                        }
                    }
                    try await group.waitForAll()
                }
                progress?(offset, max(total, offset))
            }
        } catch {
            try? await closeHandle(handle)
            throw error
        }

        try await closeHandle(handle)
    }

    // MARK: - Recursive transfers

    /// Per-file progress during a directory transfer: (path, done, total).
    public typealias SFTPItemProgress = @Sendable (String, UInt64, UInt64) -> Void

    /// Recursively download a remote directory.
    ///
    /// Symbolic links are skipped rather than followed: a link pointing at `/`
    /// or into a cycle would otherwise turn one drag into an unbounded copy.
    /// WinSCP makes this configurable; skipping is the safe default.
    public func downloadDirectory(
        remote: String,
        to localURL: URL,
        progress: SFTPItemProgress? = nil,
        resume: Bool = false
    ) async throws {
        try FileManager.default.createDirectory(
            at: localURL, withIntermediateDirectories: true)

        for entry in try await listDirectory(remote) {
            try Task.checkCancellation()
            let childRemote = remote.hasSuffix("/")
                ? remote + entry.filename
                : remote + "/" + entry.filename
            let childLocal = localURL.appendingPathComponent(entry.filename)

            if entry.attributes.isSymlink {
                continue
            } else if entry.attributes.isDirectory {
                try await downloadDirectory(
                    remote: childRemote, to: childLocal, progress: progress, resume: resume)
            } else {
                try await download(remote: childRemote, to: childLocal, progress: { done, total in
                    progress?(childRemote, done, total)
                }, resume: resume)
            }
        }
    }

    /// Recursively upload a local directory.
    public func uploadDirectory(
        localURL: URL,
        to remote: String,
        progress: SFTPItemProgress? = nil,
        resume: Bool = false
    ) async throws {
        try await makeDirectoryIfNeeded(remote)

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let children = try FileManager.default.contentsOfDirectory(
            at: localURL, includingPropertiesForKeys: keys, options: [])

        for child in children {
            try Task.checkCancellation()
            let values = try? child.resourceValues(forKeys: Set(keys))
            let childRemote = remote.hasSuffix("/")
                ? remote + child.lastPathComponent
                : remote + "/" + child.lastPathComponent

            if values?.isSymbolicLink == true {
                continue
            } else if values?.isDirectory == true {
                try await uploadDirectory(
                    localURL: child, to: childRemote, progress: progress, resume: resume)
            } else {
                try await upload(localURL: child, to: childRemote, progress: { done, total in
                    progress?(childRemote, done, total)
                }, resume: resume)
            }
        }
    }

    /// MKDIR that tolerates the directory already existing. The server reports
    /// this as a generic SSH_FX_FAILURE, so the only way to distinguish it from
    /// a real error is to stat the path.
    public func makeDirectoryIfNeeded(_ path: String) async throws {
        do {
            try await makeDirectory(path)
        } catch {
            guard let attrs = try? await stat(path), attrs.isDirectory else { throw error }
        }
    }

    /// Recursively delete a remote directory.
    public func removeDirectoryRecursively(_ path: String) async throws {
        for entry in try await listDirectory(path) {
            try Task.checkCancellation()
            let child = path.hasSuffix("/") ? path + entry.filename : path + "/" + entry.filename
            if entry.attributes.isDirectory && !entry.attributes.isSymlink {
                try await removeDirectoryRecursively(child)
            } else {
                try await removeFile(child)
            }
        }
        try await removeDirectory(path)
    }
}
