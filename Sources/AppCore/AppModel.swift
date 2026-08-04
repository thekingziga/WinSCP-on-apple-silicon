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
    @Published public var isBusy = false
    @Published public var session = SessionData()
    @Published public var sessions: [SessionData] = []
    @Published public var showingConnectSheet = false
    @Published public var showHiddenFiles = false

    // Transfer feedback
    @Published public var log: [LogEntry] = []
    @Published public var progressLabel: String = ""
    @Published public var progressFraction: Double = 0

    private var client: SFTPClient?
    private let sessionStore: SessionStore

    public init(sessionStore: SessionStore = .shared) {
        self.sessionStore = sessionStore
        sessions = sessionStore.load()
        refreshLocal()
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

    public func downloadSelected() async {
        guard let client, !remoteSelection.isEmpty else { return }
        let targets = remoteItems.filter { remoteSelection.contains($0.name) }
        guard !targets.isEmpty else { return }

        isBusy = true
        defer { isBusy = false; progressLabel = ""; progressFraction = 0 }

        for item in targets {
            let remote = joinRemote(remotePath, item.name)
            let destination = localURL.appendingPathComponent(item.name)
            do {
                if item.isDirectory {
                    progressLabel = "Downloading folder \(item.name)"
                    try await client.downloadDirectory(remote: remote, to: destination) { path, done, total in
                        Task { @MainActor in
                            self.progressLabel = "Downloading \((path as NSString).lastPathComponent)"
                            self.progressFraction = total > 0 ? Double(done) / Double(total) : 0
                        }
                    }
                    note("Downloaded folder \(item.name) → \(destination.path)")
                } else {
                    progressLabel = "Downloading \(item.name)"
                    try await client.download(remote: remote, to: destination) { done, total in
                        Task { @MainActor in
                            self.progressFraction = total > 0 ? Double(done) / Double(total) : 0
                        }
                    }
                    note("Downloaded \(item.name) → \(destination.path)")
                }
            } catch {
                fail("Download \(item.name): \(errorText(error))")
            }
        }
        refreshLocal()
    }

    public func uploadSelected() async {
        guard let client, !localSelection.isEmpty else { return }
        let targets = localItems.filter { localSelection.contains($0.name) }
        guard !targets.isEmpty else { return }

        isBusy = true
        defer { isBusy = false; progressLabel = ""; progressFraction = 0 }

        for item in targets {
            let source = localURL.appendingPathComponent(item.name)
            let remote = joinRemote(remotePath, item.name)
            do {
                if item.isDirectory {
                    progressLabel = "Uploading folder \(item.name)"
                    try await client.uploadDirectory(localURL: source, to: remote) { path, done, total in
                        Task { @MainActor in
                            self.progressLabel = "Uploading \((path as NSString).lastPathComponent)"
                            self.progressFraction = total > 0 ? Double(done) / Double(total) : 0
                        }
                    }
                    note("Uploaded folder \(item.name) → \(remote)")
                } else {
                    progressLabel = "Uploading \(item.name)"
                    try await client.upload(localURL: source, to: remote) { done, total in
                        Task { @MainActor in
                            self.progressFraction = total > 0 ? Double(done) / Double(total) : 0
                        }
                    }
                    note("Uploaded \(item.name) → \(remote)")
                }
            } catch {
                fail("Upload \(item.name): \(errorText(error))")
            }
        }
        await refreshRemote()
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
