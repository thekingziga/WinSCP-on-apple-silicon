import Foundation
import SwiftUI
import SFTPKit
import CoreKit

public enum PaneSide: String, Sendable, Identifiable {
    case local
    case remote

    public var id: String { rawValue }
}

/// One line in the transfer log at the bottom of the window.
public struct LogEntry: Identifiable {
    public let id = UUID()
    public let date = Date()
    public let text: String
    public let isError: Bool
}

/// Application state.
///
/// Stands in for WinSCP's `TTerminal` + `TCustomScpExplorerForm` pairing, minus
/// the VCL event plumbing: SwiftUI observes this object directly, so there is
/// no manual "refresh the listview" code path to keep in sync.
@MainActor
public final class AppModel: ObservableObject {

    // Local pane
    @Published public var localURL: URL = FileManager.default.homeDirectoryForCurrentUser
    @Published public var localItems: [FileItem] = []
    @Published public var localSelection: Set<String> = []

    // Remote pane
    @Published public var remotePath: String = "/"
    @Published public var remoteItems: [FileItem] = []
    @Published public var remoteSelection: Set<String> = []

    // Connection
    @Published public var isConnected = false
    /// True during a blocking session operation such as connecting. Transfers
    /// do not set this — they report through `queue`.
    @Published public var isBusy = false
    @Published public var session = SessionData()
    @Published public var sessions: [SessionData] = []
    @Published public var showingConnectSheet = false
    @Published public var showHiddenFiles = false

    // Transfer feedback. Per-transfer progress lives on `queue`; this is the
    // activity log only.
    @Published public var log: [LogEntry] = []

    /// Pending and finished transfers.
    public let queue = TransferQueue()

    private var client: SFTPClient?
    private let sessionStore: SessionStore
    /// Guards against a reconnect storm when a server is simply down.
    private var isReconnecting = false

    public init(sessionStore: SessionStore = .shared) {
        self.sessionStore = sessionStore
        sessions = sessionStore.load()
        refreshLocal()

        queue.clientProvider = { [weak self] in self?.client }
        queue.onLog = { [weak self] text, isError in
            isError == true ? self?.fail(text) : self?.note(text)
        }
        queue.onItemFinished = { [weak self] item in
            guard let self else { return }
            Task { await self.handleFinishedTransfer(item) }
        }
    }

    /// Refreshes whichever pane the transfer landed in, and notices when a
    /// failure was actually the connection dropping underneath us.
    private func handleFinishedTransfer(_ item: TransferItem) async {
        switch item.direction {
        case .download: refreshLocal()
        case .upload: await refreshRemote()
        }

        guard item.state.isFailed, let client else { return }
        let stillUp = await client.isConnected
        guard !stillUp else { return }

        isConnected = false
        fail("Connection lost.")
        await reconnectAndResume()
    }

    /// Reconnects using the stored session and re-queues failed transfers.
    /// Anything that had moved bytes resumes from its offset rather than
    /// starting over.
    public func reconnectAndResume() async {
        guard !isReconnecting, !isConnected, session.isValid else { return }
        isReconnecting = true
        defer { isReconnecting = false }

        note("Reconnecting to \(session.sshTarget)…")
        await connect(session)
        guard isConnected else { return }

        let retried = queue.retryFailed()
        if retried > 0 {
            note("Resuming \(retried) transfer\(retried == 1 ? "" : "s")")
        }
    }

    // MARK: - Logging

    public func note(_ text: String) {
        log.append(LogEntry(text: text, isError: false))
        trimLog()
    }

    public func fail(_ text: String) {
        log.append(LogEntry(text: text, isError: true))
        trimLog()
    }

    private func trimLog() {
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: - Local pane

    public func refreshLocal() {
        do {
            localItems = try LocalFileSystem.list(localURL, showHidden: showHiddenFiles)
        } catch {
            localItems = []
            fail("Local: \(error.localizedDescription)")
        }
    }

    public func enterLocal(_ item: FileItem) {
        guard item.isDirectory else { return }
        localURL = localURL.appendingPathComponent(item.name)
        localSelection = []
        refreshLocal()
    }

    public func localGoUp() {
        let parent = localURL.deletingLastPathComponent()
        guard parent.path != localURL.path else { return }
        localURL = parent
        localSelection = []
        refreshLocal()
    }

    // MARK: - Connection

    public func connect(_ data: SessionData) async {
        guard data.isValid else {
            fail("A host name is required.")
            return
        }
        isBusy = true
        defer { isBusy = false }

        let client = SFTPClient()
        note("Connecting to \(data.sshTarget)…")

        do {
            try await client.connect(
                target: data.sshTarget,
                port: data.portNumber == 22 ? nil : data.portNumber,
                extraOptions: data.sshOptions
            )
            self.client = client
            self.session = data
            isConnected = true

            let version = await client.serverVersion
            note("Connected. SFTP protocol version \(version).")

            let start = data.remoteDirectory.isEmpty ? "." : data.remoteDirectory
            remotePath = try await client.realPath(start)
            await refreshRemote()

            if !data.localDirectory.isEmpty {
                localURL = URL(fileURLWithPath: data.localDirectory)
                refreshLocal()
            }
        } catch {
            self.client = nil
            isConnected = false
            fail(errorText(error))
        }
    }

    public func disconnect() async {
        guard let client else { return }
        await client.disconnect()
        self.client = nil
        isConnected = false
        remoteItems = []
        remoteSelection = []
        note("Disconnected.")
    }

    /// ssh's own stderr is usually the informative part of a failure, and the
    /// engine already folds it into `transportFailed`.
    private func errorText(_ error: Error) -> String {
        if let sftp = error as? SFTPError { return sftp.message }
        return error.localizedDescription
    }

    // MARK: - Remote pane

    public func refreshRemote() async {
        guard let client else { return }
        do {
            let names = try await client.listDirectory(remotePath)
            remoteItems = names
                .map(FileItem.init(remote:))
                .filter { showHiddenFiles || !$0.name.hasPrefix(".") }
                .sorted(by: FileItem.defaultSort)
        } catch {
            remoteItems = []
            fail("Remote: \(errorText(error))")
        }
    }

    public func enterRemote(_ item: FileItem) async {
        guard item.isDirectory else { return }
        remotePath = joinRemote(remotePath, item.name)
        remoteSelection = []
        await refreshRemote()
    }

    public func remoteGoUp() async {
        guard remotePath != "/" else { return }
        var components = remotePath.split(separator: "/").map(String.init)
        components.removeLast()
        remotePath = components.isEmpty ? "/" : "/" + components.joined(separator: "/")
        remoteSelection = []
        await refreshRemote()
    }

    public func joinRemote(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    // MARK: - Transfers

    public func downloadSelected() {
        guard isConnected, !remoteSelection.isEmpty else { return }
        let targets = remoteItems.filter { remoteSelection.contains($0.name) }
        guard !targets.isEmpty else { return }

        queue.enqueue(targets.map { item in
            TransferItem(
                name: item.name,
                direction: .download,
                localURL: localURL.appendingPathComponent(item.name),
                remotePath: joinRemote(remotePath, item.name),
                isDirectory: item.isDirectory
            )
        })
    }

    public func uploadSelected() {
        guard isConnected, !localSelection.isEmpty else { return }
        let targets = localItems.filter { localSelection.contains($0.name) }
        guard !targets.isEmpty else { return }

        queue.enqueue(targets.map { item in
            TransferItem(
                name: item.name,
                direction: .upload,
                localURL: localURL.appendingPathComponent(item.name),
                remotePath: joinRemote(remotePath, item.name),
                isDirectory: item.isDirectory
            )
        })
    }

    /// Retry everything that failed. If the connection dropped, reconnect
    /// first — otherwise every retry would fail again immediately.
    public func retryFailedTransfers() async {
        if !isConnected {
            await reconnectAndResume()
        } else {
            let retried = queue.retryFailed()
            if retried > 0 {
                note("Retrying \(retried) transfer\(retried == 1 ? "" : "s")")
            }
        }
    }

    /// Drag-and-drop entry point: transfer named items in a given direction
    /// regardless of what is currently selected.
    public func enqueueTransfer(names: [String], direction: TransferDirection) {
        guard isConnected else { return }
        let source = direction == .upload ? localItems : remoteItems
        let matched = source.filter { names.contains($0.name) }
        guard !matched.isEmpty else { return }

        queue.enqueue(matched.map { item in
            TransferItem(
                name: item.name,
                direction: direction,
                localURL: localURL.appendingPathComponent(item.name),
                remotePath: joinRemote(remotePath, item.name),
                isDirectory: item.isDirectory
            )
        })
    }

    // MARK: - Mutations

    public func createDirectory(on side: PaneSide, named name: String) async {
        guard !name.isEmpty else { return }
        switch side {
        case .local:
            do {
                try LocalFileSystem.createDirectory(at: localURL.appendingPathComponent(name))
                refreshLocal()
                note("Created local directory \(name)")
            } catch {
                fail("Create directory: \(error.localizedDescription)")
            }
        case .remote:
            guard let client else { return }
            do {
                try await client.makeDirectory(joinRemote(remotePath, name))
                await refreshRemote()
                note("Created remote directory \(name)")
            } catch {
                fail("Create directory: \(errorText(error))")
            }
        }
    }

    /// Renames a single item. Both sides get the same treatment so the UI
    /// does not need to know whether the rename is local or remote.
    public func renameItem(on side: PaneSide, oldName: String, newName: String) async {
        guard !newName.isEmpty, newName != oldName else { return }
        switch side {
        case .local:
            do {
                try LocalFileSystem.rename(at: localURL.appendingPathComponent(oldName),
                                           to: newName)
                note("Renamed local \(oldName) → \(newName)")
            } catch {
                fail("Rename \(oldName): \(error.localizedDescription)")
            }
            refreshLocal()
        case .remote:
            guard let client else { return }
            do {
                try await client.rename(from: joinRemote(remotePath, oldName),
                                        to: joinRemote(remotePath, newName))
                note("Renamed remote \(oldName) → \(newName)")
            } catch {
                fail("Rename \(oldName): \(errorText(error))")
            }
            await refreshRemote()
        }
    }

    public func deleteSelected(on side: PaneSide) async {
        switch side {
        case .local:
            for name in localSelection {
                do {
                    try LocalFileSystem.remove(at: localURL.appendingPathComponent(name))
                    note("Deleted local \(name)")
                } catch {
                    fail("Delete \(name): \(error.localizedDescription)")
                }
            }
            localSelection = []
            refreshLocal()
        case .remote:
            guard let client else { return }
            for name in remoteSelection {
                let path = joinRemote(remotePath, name)
                let isDir = remoteItems.first { $0.name == name }?.isDirectory ?? false
                do {
                    if isDir {
                        try await client.removeDirectoryRecursively(path)
                    } else {
                        try await client.removeFile(path)
                    }
                    note("Deleted remote \(name)")
                } catch {
                    fail("Delete \(name): \(errorText(error))")
                }
            }
            remoteSelection = []
            await refreshRemote()
        }
    }

    // MARK: - Session persistence

    public func saveSession(_ data: SessionData) {
        if let index = sessions.firstIndex(where: { $0.id == data.id }) {
            sessions[index] = data
        } else {
            sessions.append(data)
        }
        sessionStore.save(sessions)
    }

    public func deleteSession(_ data: SessionData) {
        sessions.removeAll { $0.id == data.id }
        sessionStore.save(sessions)
    }
}
