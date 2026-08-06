import SwiftUI
import AppCore

/// The transfer queue panel.
///
/// WinSCP puts this at the bottom of its window with per-item progress and a
/// cancel button; same idea here.
struct TransferQueueView: View {
    @ObservedObject var queue: TransferQueue
    var onRetryFailed: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if queue.items.isEmpty {
                Text("No transfers yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Transfers")
                .font(.headline)

            if queue.pendingCount > 0 {
                Text("\(queue.pendingCount) pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if queue.failedCount > 0 {
                Text("\(queue.failedCount) failed")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button("Retry failed", action: onRetryFailed)
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(queue.failedCount == 0)

            Button("Cancel all") { queue.cancelAll() }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(queue.pendingCount == 0)

            Button("Clear finished") { queue.clearFinished() }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!queue.items.contains { $0.state.isFinished })
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(queue.items) { item in
                    row(item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func row(_ item: TransferItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: item))
                .foregroundStyle(color(for: item))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isDirectory {
                        Text("folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(detail(for: item))
                        .font(.caption2)
                        .foregroundStyle(color(for: item))
                        .lineLimit(1)
                }

                if item.state == .running {
                    ProgressView(value: item.fraction)
                        .controlSize(.small)
                }
            }

            if !item.state.isFinished {
                Button {
                    queue.cancel(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel this transfer")
            }
        }
        .padding(.vertical, 2)
    }

    private func icon(for item: TransferItem) -> String {
        switch item.state {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "slash.circle"
        case .running: return item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
        case .queued: return "clock"
        }
    }

    private func color(for item: TransferItem) -> Color {
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .running, .queued: return .secondary
        }
    }

    private func detail(for item: TransferItem) -> String {
        switch item.state {
        case .queued: return "queued"
        case .running:
            guard item.bytesTotal > 0 else { return "transferring…" }
            return "\(Int(item.fraction * 100))%"
        case .completed: return "done"
        case .cancelled: return "cancelled"
        case .failed(let message): return message
        }
    }
}
