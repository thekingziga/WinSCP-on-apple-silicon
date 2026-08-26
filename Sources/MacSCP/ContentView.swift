import SwiftUI
import AppCore
import CoreKit

/// Identifiable wrapper so `.sheet(item:)` can present the rename dialog.
private struct RenameRequest: Identifiable {
    let id = UUID()
    let side: PaneSide
    let oldName: String
}

/// Same, for the permissions dialog.
private struct PermissionsRequest: Identifiable {
    let id = UUID()
    let side: PaneSide
    let name: String
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var newFolderSide: PaneSide?
    @State private var newFolderName = ""
    @State private var renameRequest: RenameRequest?
    @State private var renameNewName = ""
    @State private var permissionsRequest: PermissionsRequest?
    @State private var permissionsText = ""
    @State private var confirmDelete: PaneSide?

    var body: some View {
        VStack(spacing: 0) {
            panes
            Divider()
            transferBar
            Divider()
            // A plain HStack rather than nesting an HSplitView inside the outer
            // one. Nested split views are fiddly and a fixed-width log reads
            // fine here; the queue takes the remaining space.
            HStack(spacing: 0) {
                TransferQueueView(queue: model.queue) {
                    Task { await model.retryFailedTransfers() }
                }
                .frame(maxWidth: .infinity)

                Divider()

                logView
                    .frame(width: 300)
            }
            .frame(height: 170)
        }
        .frame(minWidth: 980, minHeight: 620)
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.showingConnectSheet) {
            ConnectSheet().environmentObject(model)
        }
        .sheet(item: $newFolderSide) { side in
            newFolderSheet(side)
        }
        .sheet(item: $renameRequest) { req in
            renameSheet(req)
        }
        .sheet(item: $permissionsRequest) { req in
            permissionsSheet(req)
        }
        .alert("Delete selected files?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                guard let side = confirmDelete else { return }
                confirmDelete = nil
                Task { await model.deleteSelected(on: side) }
            }
        } message: {
            if let side = confirmDelete {
                let names = side == .local ? model.localSelection : model.remoteSelection
                Text("This will permanently delete \(names.count) item\(names.count == 1 ? "" : "s").")
            }
        }
    }

    // MARK: - Panes

    private var panes: some View {
        HSplitView {
            FilePaneView(
                title: "Local",
                path: model.localURL.path,
                items: model.localItems,
                selection: $model.localSelection,
                isBusy: model.isBusy,
                side: .local,
                acceptsDrops: model.isConnected,
                onGoUp: { model.localGoUp() },
                onOpen: { model.enterLocal($0) },
                onRefresh: { model.refreshLocal() },
                onDropNames: { names in
                    model.enqueueTransfer(names: names, direction: .download)
                }
            )
            .frame(minWidth: 380)

            FilePaneView(
                title: model.isConnected ? "Remote — \(model.session.sshTarget)" : "Remote",
                path: model.isConnected ? model.remotePath : "Not connected",
                items: model.remoteItems,
                selection: $model.remoteSelection,
                isBusy: model.isBusy,
                side: .remote,
                acceptsDrops: model.isConnected,
                onGoUp: { Task { await model.remoteGoUp() } },
                onOpen: { item in Task { await model.enterRemote(item) } },
                onRefresh: { Task { await model.refreshRemote() } },
                onDropNames: { names in
                    model.enqueueTransfer(names: names, direction: .upload)
                }
            )
            .frame(minWidth: 380)
            .disabled(!model.isConnected)
            .opacity(model.isConnected ? 1 : 0.5)
        }
    }

    // MARK: - Transfer bar

    private var transferBar: some View {
        HStack(spacing: 12) {
            Button {
                model.uploadSelected()
            } label: {
                Label("Upload", systemImage: "arrow.right")
            }
            .disabled(!model.isConnected || model.localSelection.isEmpty)
            .help("Copy the selected local files to the remote directory")

            Button {
                model.downloadSelected()
            } label: {
                Label("Download", systemImage: "arrow.left")
            }
            .disabled(!model.isConnected || model.remoteSelection.isEmpty)
            .help("Copy the selected remote files to the local directory")

            Divider().frame(height: 18)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let active = model.queue.activeItem {
                ProgressView(value: active.fraction)
                    .frame(width: 160)
                Text("\(active.direction.verb)ing \(active.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Toggle("Hidden files", isOn: $model.showHiddenFiles)
                .toggleStyle(.checkbox)
                .onChange(of: model.showHiddenFiles) { _, _ in
                    model.refreshLocal()
                    Task { await model.refreshRemote() }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Log

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.log) { entry in
                        Text(entry.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(entry.isError ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .onChange(of: model.log.count) { _, _ in
                if let last = model.log.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            if model.isConnected {
                Button {
                    Task { await model.disconnect() }
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
            } else {
                Button {
                    model.showingConnectSheet = true
                } label: {
                    Label("Connect", systemImage: "bolt")
                }
            }

            Button {
                newFolderName = ""
                newFolderSide = .local
            } label: {
                Label("New Local Folder", systemImage: "folder.badge.plus")
            }

            Button {
                newFolderName = ""
                newFolderSide = .remote
            } label: {
                Label("New Remote Folder", systemImage: "folder.badge.plus.fill")
            }
            .disabled(!model.isConnected)

            Button {
                startRename()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .disabled(activeSideForSingleSelection == nil)
            .help("Rename selected file")

            Button {
                startPermissions()
            } label: {
                Label("Permissions", systemImage: "lock")
            }
            .disabled(activeSideForSingleSelection == nil)
            .help("Change permissions on the selected file")

            Button {
                startDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(activeSideForAnySelection == nil)
            .help("Delete selected files")
        }
    }

    // MARK: - New folder sheet

    private func newFolderSheet(_ side: PaneSide) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New \(side == .local ? "local" : "remote") folder")
                .font(.headline)

            TextField("Folder name", text: $newFolderName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            HStack {
                Spacer()
                Button("Cancel") { newFolderSide = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    let name = newFolderName
                    newFolderSide = nil
                    Task { await model.createDirectory(on: side, named: name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: - Rename sheet

    private func renameSheet(_ req: RenameRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(req.side == .local ? "local" : "remote") item")
                .font(.headline)

            Text(req.oldName)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("New name", text: $renameNewName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            HStack {
                Spacer()
                Button("Cancel") { renameRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    let old = req.oldName
                    let newName = renameNewName
                    let side = req.side
                    renameRequest = nil
                    Task { await model.renameItem(on: side, oldName: old, newName: newName) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    renameNewName == req.oldName ||
                    renameNewName.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(20)
    }

    // MARK: - Permissions sheet

    private func permissionsSheet(_ req: PermissionsRequest) -> some View {
        // Parsing as the user types drives both the preview and the button, so
        // an unparseable mode can never reach the model.
        let parsed = LocalFileSystem.parsePermissions(permissionsText)

        return VStack(alignment: .leading, spacing: 14) {
            Text("Permissions for \(req.side == .local ? "local" : "remote") item")
                .font(.headline)

            Text(req.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Mode (644 or rw-r--r--)", text: $permissionsText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            Group {
                if let parsed {
                    Text(String(format: "%03o", parsed)
                         + "  " + LocalFileSystem.permissionString(parsed))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Enter an octal mode such as 644, or rw-r--r--.")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(.caption, design: .monospaced))

            HStack {
                Spacer()
                Button("Cancel") { permissionsRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard let mode = parsed else { return }
                    let side = req.side
                    let name = req.name
                    permissionsRequest = nil
                    Task { await model.setPermissions(on: side, name: name, mode: mode) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(parsed == nil)
            }
        }
        .padding(20)
    }

    // MARK: - Selection helpers

    /// The side that has exactly one item selected, preferring whichever pane
    /// has focus (local wins ties since it is always available).
    private var activeSideForSingleSelection: PaneSide? {
        if model.localSelection.count == 1 { return .local }
        if model.remoteSelection.count == 1 { return .remote }
        return nil
    }

    /// The side that has any selection at all.
    private var activeSideForAnySelection: PaneSide? {
        if !model.localSelection.isEmpty { return .local }
        if !model.remoteSelection.isEmpty { return .remote }
        return nil
    }

    private func startRename() {
        guard let side = activeSideForSingleSelection else { return }
        let name = (side == .local ? model.localSelection : model.remoteSelection).first!
        renameNewName = name
        renameRequest = RenameRequest(side: side, oldName: name)
    }

    private func startPermissions() {
        guard let side = activeSideForSingleSelection else { return }
        let selection = side == .local ? model.localSelection : model.remoteSelection
        guard let name = selection.first else { return }
        // Prefill with the mode the pane is already showing, so the dialog opens
        // on the current value rather than an empty field.
        let items = side == .local ? model.localItems : model.remoteItems
        let current = items.first { $0.name == name }?.mode
        permissionsText = current.map { String(format: "%03o", $0) } ?? ""
        permissionsRequest = PermissionsRequest(side: side, name: name)
    }

    private func startDelete() {
        guard let side = activeSideForAnySelection else { return }
        confirmDelete = side
    }
}
