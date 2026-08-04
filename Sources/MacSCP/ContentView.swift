import SwiftUI
import AppCore
import CoreKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var newFolderSide: PaneSide?
    @State private var newFolderName = ""

    var body: some View {
        VStack(spacing: 0) {
            panes
            Divider()
            transferBar
            Divider()
            logView
        }
        .frame(minWidth: 980, minHeight: 620)
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.showingConnectSheet) {
            ConnectSheet().environmentObject(model)
        }
        .sheet(item: $newFolderSide) { side in
            newFolderSheet(side)
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
                onGoUp: { model.localGoUp() },
                onOpen: { model.enterLocal($0) },
                onRefresh: { model.refreshLocal() }
            )
            .frame(minWidth: 380)

            FilePaneView(
                title: model.isConnected ? "Remote — \(model.session.sshTarget)" : "Remote",
                path: model.isConnected ? model.remotePath : "Not connected",
                items: model.remoteItems,
                selection: $model.remoteSelection,
                isBusy: model.isBusy,
                onGoUp: { Task { await model.remoteGoUp() } },
                onOpen: { item in Task { await model.enterRemote(item) } },
                onRefresh: { Task { await model.refreshRemote() } }
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
                Task { await model.uploadSelected() }
            } label: {
                Label("Upload", systemImage: "arrow.right")
            }
            .disabled(!model.isConnected || model.localSelection.isEmpty || model.isBusy)
            .help("Copy the selected local files to the remote directory")

            Button {
                Task { await model.downloadSelected() }
            } label: {
                Label("Download", systemImage: "arrow.left")
            }
            .disabled(!model.isConnected || model.remoteSelection.isEmpty || model.isBusy)
            .help("Copy the selected remote files to the local directory")

            Divider().frame(height: 18)

            if model.isBusy {
                ProgressView(value: model.progressFraction)
                    .frame(width: 180)
                Text(model.progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
            .frame(height: 110)
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
}
