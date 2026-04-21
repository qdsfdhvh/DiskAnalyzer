import SwiftUI
import AppKit

struct FileRowView: View {
    let node: FileNode
    let parentSize: Int64
    let rootSize: Int64

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 18, height: 18)

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            // Percentage of parent as a subtle bar.
            GeometryReader { geo in
                let pct = parentSize > 0 ? Double(node.size) / Double(parentSize) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(pct: pct))
                        .frame(width: max(2, geo.size.width * pct))
                }
            }
            .frame(width: 120, height: 8)

            Text(SizeFormatter.percent(node.size, of: parentSize))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)

            Text(SizeFormatter.string(node.size))
                .font(.system(.body, design: .monospaced))
                .frame(width: 90, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .background(isHovering ? Color.accentColor.opacity(0.06) : Color.clear)
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

    private var icon: NSImage {
        NSWorkspace.shared.icon(forFile: node.url.path)
    }

    private func barColor(pct: Double) -> Color {
        switch pct {
        case 0.5...: return .red
        case 0.25..<0.5: return .orange
        case 0.1..<0.25: return .yellow
        default: return .accentColor
        }
    }
}
