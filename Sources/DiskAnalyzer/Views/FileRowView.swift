import SwiftUI
import AppKit

/// Quiet row: name left, tabular size right, a short subtle bar between them
/// showing share of parent. Tier color tints the bar, so real outliers pick
/// up the terracotta accent while most rows stay neutral gray.
struct FileRowView: View {
    let node: FileNode
    let parentSize: Int64
    let rank: Int   // 0 = largest in parent

    @State private var isHovering = false

    private var fraction: Double {
        guard parentSize > 0 else { return 0 }
        return min(1, Double(node.size) / Double(parentSize))
    }

    private var tierColor: Color {
        // The #1 row in each parent is always the accent, regardless of size.
        // That gives every folder one clear focal point.
        if rank == 0 && node.size >= 10 * 1024 * 1024 { return DT.accent }
        return DT.tier(forBytes: node.size)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(node.name)
                .font(DT.text(13, weight: rank == 0 ? .medium : .regular))
                .foregroundStyle(DT.fg)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 280, alignment: .leading)

            // Proportional bar. 3pt tall, rounded, tinted by tier.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DT.line)
                    Capsule()
                        .fill(tierColor)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 3)

            Text(percentLabel)
                .font(DT.mono(11))
                .foregroundStyle(DT.fgMuted)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)

            Text(SizeFormatter.string(node.size))
                .font(DT.mono(12, weight: rank == 0 ? .semibold : .regular))
                .foregroundStyle(DT.fg)
                .monospacedDigit()
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, DT.rowVPadding)
        .background(isHovering ? DT.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            Button("Copy Path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(node.url.path, forType: .string)
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                try? FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            }
        }
    }

    private var percentLabel: String {
        guard parentSize > 0 else { return "—" }
        let v = Double(node.size) / Double(parentSize) * 100
        if v >= 10 { return String(format: "%.0f%%", v) }
        if v >= 1  { return String(format: "%.1f%%", v) }
        return String(format: "%.2f%%", v)
    }
}
