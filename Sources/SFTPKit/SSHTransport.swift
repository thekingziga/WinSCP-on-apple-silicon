import Foundation

/// Carries SFTP packets over the system OpenSSH client.
///
/// WinSCP links PuTTY in-process to own the SSH layer outright. On macOS that
/// buys us nothing: the OS ships a maintained OpenSSH, and delegating to it
/// means we inherit `~/.ssh/config`, agent forwarding, hardware-backed keys,
/// ProxyJump, and Keychain-stored passphrases for free. We drive
/// `ssh -s sftp`, which hands us the subsystem's binary channel on stdio.
public final class SSHTransport: @unchecked Sendable {
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()

    private let lock = NSLock()
    private var stderrBuffer = Data()
    private var readerThread: Thread?

    /// Invoked on the reader thread for each complete packet: (type, body).
    private let onPacket: (UInt8, [UInt8]) -> Void
    /// Invoked once when the channel closes or fails.
    private let onClose: (Error?) -> Void

    public init(
        onPacket: @escaping (UInt8, [UInt8]) -> Void,
        onClose: @escaping (Error?) -> Void
    ) {
        self.onPacket = onPacket
        self.onClose = onClose
    }

    /// Text ssh wrote to stderr — the useful part of any connection failure.
    public var stderrText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stderrBuffer, encoding: .utf8) ?? ""
    }

    public func start(target: String, port: Int?, extraOptions: [String]) throws {
        var args: [String] = []
        // Fail fast rather than blocking on an interactive prompt: this build
        // authenticates via key/agent, so a password prompt would just hang.
        args += ["-o", "BatchMode=yes"]
        args += ["-o", "StrictHostKeyChecking=accept-new"]
        if let port { args += ["-p", String(port)] }
        args += extraOptions
        args += [target, "-s", "sftp"]

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = args
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            let text = self.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if proc.terminationStatus != 0 {
                self.onClose(.some(SFTPError.transportFailed(
                    text.isEmpty ? "ssh exited with status \(proc.terminationStatus)" : text)))
            } else {
                self.onClose(nil)
            }
        }

        // Drain stderr continuously so a chatty ssh can't fill the pipe buffer
        // and deadlock the session.
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            self.stderrBuffer.append(chunk)
            self.lock.unlock()
        }

        do {
            try process.run()
        } catch {
            throw SFTPError.transportFailed(error.localizedDescription)
        }

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "SFTPKit.reader"
        thread.stackSize = 512 * 1024
        readerThread = thread
        thread.start()
    }

    public func send(_ data: Data) throws {
        do {
            try inPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            throw SFTPError.transportFailed("write failed: \(error.localizedDescription)")
        }
    }

    public func stop() {
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? inPipe.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    // MARK: - Reader

    /// Blocking read of exactly `count` bytes. Returns nil at clean EOF.
    private func readFully(_ handle: FileHandle, _ count: Int) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(count)
        while out.count < count {
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }  // EOF
            out.append(contentsOf: chunk)
            // availableData can overshoot; hand the surplus back via the spill
            // buffer so framing stays exact.
            if out.count > count {
                let extra = Array(out[count...])
                out.removeSubrange(count...)
                spill = extra + spill
            }
        }
        return out
    }

    private var spill: [UInt8] = []

    private func readExact(_ handle: FileHandle, _ count: Int) -> [UInt8]? {
        if spill.count >= count {
            let head = Array(spill.prefix(count))
            spill.removeFirst(count)
            return head
        }
        var out = spill
        spill = []
        guard let rest = readFully(handle, count - out.count) else { return nil }
        out.append(contentsOf: rest)
        return out
    }

    private func readLoop() {
        let handle = outPipe.fileHandleForReading
        while true {
            guard let lengthBytes = readExact(handle, 4) else {
                onClose(nil)
                return
            }
            let length = lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            // Guard against a desynced stream claiming an absurd allocation.
            guard length >= 1, length <= 64 * 1024 * 1024 else {
                onClose(SFTPError.malformedPacket("declared packet length \(length)"))
                return
            }
            guard let payload = readExact(handle, Int(length)) else {
                onClose(SFTPError.transportFailed("truncated packet"))
                return
            }
            onPacket(payload[0], Array(payload.dropFirst()))
        }
    }
}
