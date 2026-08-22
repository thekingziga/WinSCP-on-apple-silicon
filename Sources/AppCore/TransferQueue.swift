import Foundation
import SFTPKit

public enum TransferDirection: String, Sendable, Codable {
    case upload
    case download

    public var verb: String { self == .upload ? "Upload" : "Download" }
}

/// What to do when a transfer would overwrite an existing file.
public enum OverwritePolicy: String, Sendable, CaseIterable {
    /// Stop and wait for the user. The default: silently destroying a file is
    /// the one mistake a file manager must not make on its own.
    case ask
    case overwrite
    case skip
    /// Treat the existing bytes as a partial transfer and continue from them.
    case resume
}

public enum TransferState: Sendable, Equatable {
    case queued
    case running
    case completed
    case cancelled
    case skipped
    case failed(String)
    /// Destination already exists; carries its current size. Waiting on a
    /// decision, not an error.
    case conflict(UInt64)

    /// Not currently occupying the queue. A conflict counts as inactive — it
    /// blocks nothing while it waits for the user.
    public var isFinished: Bool {
        switch self {
        case .completed, .cancelled, .failed, .skipped, .conflict: return true
        case .queued, .running: return false
        }
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    public var needsDecision: Bool {
        if case .conflict = self { return true }
        return false
    }
}

/// One queued transfer.
public struct TransferItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var direction: TransferDirection
    public var localURL: URL
    public var remotePath: String
    public var isDirectory: Bool
    public var state: TransferState
    public var bytesDone: UInt64
    public var bytesTotal: UInt64
    /// Set once a transfer has moved bytes, so a retry can resume rather than
    /// start over.
    public var hasPartialData: Bool
    public var overwritePolicy: OverwritePolicy

    public init(
        id: UUID = UUID(),
        name: String,
        direction: TransferDirection,
        localURL: URL,
        remotePath: String,
        isDirectory: Bool = false,
        state: TransferState = .queued,
        bytesDone: UInt64 = 0,
        bytesTotal: UInt64 = 0,
        hasPartialData: Bool = false,
        overwritePolicy: OverwritePolicy = .ask
    ) {
        self.id = id
        self.name = name
        self.direction = direction
        self.localURL = localURL
        self.remotePath = remotePath
        self.isDirectory = isDirectory
        self.state = state
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.hasPartialData = hasPartialData
        self.overwritePolicy = overwritePolicy
    }

    public var fraction: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
    }
}

/// Serial transfer queue with per-item cancellation.
///
/// WinSCP runs a background queue with pause/resume/cancel per item; this is the
/// same idea. Transfers run one at a time on purpose — SFTP already pipelines 16
/// requests within a single transfer, so running several concurrently would
/// contend for the same channel without going faster, and it would make progress
/// reporting and resume bookkeeping considerably harder to reason about.
@MainActor
public final class TransferQueue: ObservableObject {
    @Published public private(set) var items: [TransferItem] = []
    @Published public private(set) var isRunning = false

    /// Emits (message, isError) for the activity log.
    public var onLog: ((String, Bool) -> Void)?
    /// Called after each item finishes, so panes can refresh.
    public var onItemFinished: ((TransferItem) -> Void)?

    /// Supplies the live session. Set by the owner after construction so the
    /// queue and the model can reference each other without an init cycle.
    public var clientProvider: (() -> SFTPClient?)?

    private var pumpTask: Task<Void, Never>?
    private var activeTransfer: Task<Void, Error>?
    private var activeItemID: UUID?

    public init() {}

    /// Suspends until the queue has nothing left to do. Intended for tests and
    /// scripted use; the UI observes `items` instead.
    public func waitUntilIdle() async {
        while isRunning || pendingCount > 0 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Queue management

    public func enqueue(_ item: TransferItem) {
        items.append(item)
        pump()
    }

    public func enqueue(_ newItems: [TransferItem]) {
        items.append(contentsOf: newItems)
        pump()
    }

    /// Cancels a single item. A running item has its task cancelled; a queued
    /// one is marked without ever starting.
    public func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].state {
        case .running:
            activeTransfer?.cancel()
        case .queued:
            items[index].state = .cancelled
        default:
            break
        }
    }

    public func cancelAll() {
        for index in items.indices where items[index].state == .queued {
            items[index].state = .cancelled
        }
        activeTransfer?.cancel()
    }

    /// Removes settled items. Conflicts are kept — they are waiting on the
    /// user, and dropping them would silently discard the request.
    public func clearFinished() {
        items.removeAll { $0.state.isFinished && !$0.state.needsDecision }
    }

    public var conflictCount: Int {
        items.filter { $0.state.needsDecision }.count
    }

    /// Answers one conflict.
    public func resolveConflict(_ id: UUID, with policy: OverwritePolicy) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state.needsDecision else { return }

        switch policy {
        case .skip, .ask:
            items[index].state = .skipped
        case .overwrite:
            items[index].overwritePolicy = .overwrite
            items[index].hasPartialData = false
            items[index].state = .queued
            pump()
        case .resume:
            items[index].overwritePolicy = .resume
            items[index].hasPartialData = true
            items[index].state = .queued
            pump()
        }
    }

    /// Answers every outstanding conflict the same way.
    @discardableResult
    public func resolveAllConflicts(with policy: OverwritePolicy) -> Int {
        let ids = items.filter { $0.state.needsDecision }.map(\.id)
        for id in ids { resolveConflict(id, with: policy) }
        return ids.count
    }

    /// Re-queues everything that failed, preserving partial progress so the
    /// retry resumes instead of restarting.
    @discardableResult
    public func retryFailed() -> Int {
        var count = 0
        for index in items.indices where items[index].state.isFailed {
            items[index].state = .queued
            count += 1
        }
        if count > 0 { pump() }
        return count
    }

    public var pendingCount: Int {
        items.filter { !$0.state.isFinished }.count
    }

    public var failedCount: Int {
        items.filter { $0.state.isFailed }.count
    }

    /// The transfer currently moving bytes, if any.
    public var activeItem: TransferItem? {
        items.first { $0.state == .running }
    }

    // MARK: - Execution

    private func pump() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            await self?.drain()
            self?.pumpTask = nil
        }
    }

    private func drain() async {
        isRunning = true
        defer { isRunning = false }

        while let index = items.firstIndex(where: { $0.state == .queued }) {
            guard let client = clientProvider?() else {
                items[index].state = .failed("Not connected")
                onLog?("\(items[index].direction.verb) \(items[index].name): not connected", true)
                continue
            }

            // Refuse to clobber an existing destination unless told to.
            if items[index].overwritePolicy == .ask, !items[index].isDirectory,
               let existing = await existingSize(of: items[index], using: client) {
                items[index].state = .conflict(existing)
                onLog?("\(items[index].name) already exists — waiting for a decision", true)
                continue
            }

            items[index].state = .running
            let item = items[index]
            activeItemID = item.id

            let task = Task<Void, Error> { [weak self] in
                try await self?.perform(item, using: client)
            }
            activeTransfer = task

            do {
                try await task.value
                update(item.id) { $0.state = .completed; $0.bytesDone = max($0.bytesDone, $0.bytesTotal) }
                onLog?("\(item.direction.verb)ed \(item.name)", false)
            } catch is CancellationError {
                update(item.id) { $0.state = .cancelled }
                onLog?("\(item.direction.verb) cancelled: \(item.name)", true)
            } catch {
                let message = (error as? SFTPError)?.message ?? error.localizedDescription
                update(item.id) { $0.state = .failed(message) }
                onLog?("\(item.direction.verb) \(item.name): \(message)", true)
            }

            activeTransfer = nil
            activeItemID = nil
            if let finished = items.first(where: { $0.id == item.id }) {
                onItemFinished?(finished)
            }
        }
    }

    /// Size of the destination if it already exists, else nil.
    private func existingSize(of item: TransferItem, using client: SFTPClient) async -> UInt64? {
        switch item.direction {
        case .download:
            guard FileManager.default.fileExists(atPath: item.localURL.path) else { return nil }
            return (try? FileManager.default.attributesOfItem(atPath: item.localURL.path)[.size]
                as? UInt64) ?? 0
        case .upload:
            guard let attrs = try? await client.stat(item.remotePath) else { return nil }
            return attrs.size
        }
    }

    private func perform(_ item: TransferItem, using client: SFTPClient) async throws {
        let id = item.id
        let resume = item.hasPartialData || item.overwritePolicy == .resume

        switch (item.direction, item.isDirectory) {
        case (.download, false):
            try await client.download(remote: item.remotePath, to: item.localURL, progress: { done, total in
                Task { @MainActor [weak self] in
                    self?.updateProgress(id) { $0.bytesDone = done; $0.bytesTotal = total; $0.hasPartialData = done > 0 }
                }
            }, resume: resume)

        case (.download, true):
            try await client.downloadDirectory(remote: item.remotePath, to: item.localURL, progress: { path, done, total in
                Task { @MainActor [weak self] in
                    self?.updateProgress(id) {
                        $0.name = (path as NSString).lastPathComponent
                        $0.bytesDone = done
                        $0.bytesTotal = total
                        $0.hasPartialData = true
                    }
                }
            }, resume: resume)

        case (.upload, false):
            try await client.upload(localURL: item.localURL, to: item.remotePath, progress: { done, total in
                Task { @MainActor [weak self] in
                    self?.updateProgress(id) { $0.bytesDone = done; $0.bytesTotal = total; $0.hasPartialData = done > 0 }
                }
            }, resume: resume)

        case (.upload, true):
            try await client.uploadDirectory(localURL: item.localURL, to: item.remotePath, progress: { path, done, total in
                Task { @MainActor [weak self] in
                    self?.updateProgress(id) {
                        $0.name = (path as NSString).lastPathComponent
                        $0.bytesDone = done
                        $0.bytesTotal = total
                        $0.hasPartialData = true
                    }
                }
            }, resume: resume)
        }
    }

    /// Applies a change unconditionally. Used by the queue itself for state.
    private func update(_ id: UUID, _ mutate: (inout TransferItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }

    /// Applies a progress change only while the item is still running.
    ///
    /// Progress callbacks are dispatched onto the main actor and can therefore
    /// land *after* the transfer has already been cancelled or failed. Without
    /// this guard a late callback would overwrite the final byte counts of an
    /// item the user just cancelled.
    private func updateProgress(_ id: UUID, _ mutate: (inout TransferItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].state == .running else { return }
        mutate(&items[index])
    }
}
