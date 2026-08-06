import SwiftUI
import UniformTypeIdentifiers
import CoreKit
import AppCore

/// One half of the dual-pane explorer.
///
/// WinSCP builds this from a custom `TCustomDirView` descending through several
/// layers of third-party VCL list controls. On macOS a plain `List` with a
/// selection binding covers it.
struct FilePaneView: View {
    let title: String
    let path: String
    let items: [FileItem]
    @Binding var selection: Set<String>
    let isBusy: Bool
    /// Which pane this is — drags are tagged with it so a drop can tell where
    /// the items came from and ignore drags that started in this same pane.
    let side: PaneSide
    let acceptsDrops: Bool

    var onGoUp: () -> Void
    var onOpen: (FileItem) -> Void
    var onRefresh: () -> Void
    var onDropNames: ([String]) -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.headline)

            Spacer(minLength: 8)

            Button(action: onGoUp) {
                Image(systemName: "arrow.up.doc")
            }
            .help("Go to parent directory")
            .buttonStyle(.borderless)

            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(items) { item in
                row(item)
                    .tag(item.name)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onOpen(item) }
                    .onDrag { dragProvider(for: item) }
            }
        }
        .listStyle(.inset)
        .overlay {
            if items.isEmpty && !isBusy {
                Text("Empty directory")
                    .foregroundStyle(.secondary)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.text], isTargeted: acceptsDrops ? $isDropTargeted : .constant(false)) { providers in
            guard acceptsDrops else { return false }
            return handleDrop(providers)
        }
    }

    /// Dragging a row drags the whole selection when the row is part of it,
    /// which is what a file manager is expected to do.
    private func dragProvider(for item: FileItem) -> NSItemProvider {
        let names = selection.contains(item.name) ? Array(selection) : [item.name]
        let payload = ([side.rawValue] + names).joined(separator: "\n")
        return NSItemProvider(object: payload as NSString)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let payload = object as? String else { return }
                var lines = payload.components(separatedBy: "\n")
                guard let origin = lines.first, !lines.isEmpty else { return }
                lines.removeFirst()
                // Ignore drags that started in this pane — dropping a pane onto
                // itself should do nothing rather than transfer in a loop.
                guard origin != side.rawValue, !lines.isEmpty else { return }
                Task { @MainActor in onDropNames(lines) }
            }
        }
        return true
    }

    private func row(_ item: FileItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: item))
                .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 16)

            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            Text(item.displaySize)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)

            Text(item.permissions)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)

            Text(item.displayModified)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 116, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private func icon(for item: FileItem) -> String {
        if item.isSymlink { return "arrow.turn.up.right" }
        if item.isDirectory { return "folder.fill" }
        return "doc"
    }

    private var footer: some View {
        HStack {
            Text(path)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Spacer()

            Text("\(items.count) items\(selection.isEmpty ? "" : ", \(selection.count) selected")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}
