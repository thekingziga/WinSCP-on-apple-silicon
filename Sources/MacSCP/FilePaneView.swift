import SwiftUI
import CoreKit

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

    var onGoUp: () -> Void
    var onOpen: (FileItem) -> Void
    var onRefresh: () -> Void

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
            }
        }
        .listStyle(.inset)
        .overlay {
            if items.isEmpty && !isBusy {
                Text("Empty directory")
                    .foregroundStyle(.secondary)
            }
        }
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
