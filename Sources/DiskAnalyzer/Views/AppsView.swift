import SwiftUI
import AppKit

// MARK: - App management view

struct AppsView: View {
    @ObservedObject var app: AppViewModel
    @State private var apps: [AppInfo] = []
    @State private var isScanning = false

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Rectangle().fill(DT.line).frame(height: 1)

                if apps.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Applications")
                .font(DT.text(13, weight: .medium))
                .foregroundStyle(DT.fg)
            Spacer()
            if isScanning {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                Text("Scanning…")
                    .font(DT.mono(10))
                    .foregroundStyle(DT.fgSubtle)
            } else {
                Button("Scan Apps") { scanApps() }
                    .buttonStyle(QuietButtonStyle(variant: .secondary))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(DT.bg)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 0) {
            Spacer()
            VStack(spacing: 10) {
                Text("Installed Applications")
                    .font(DT.text(22, weight: .semibold))
                    .foregroundStyle(DT.fg)
                Text("See which apps take up the most space on your disk.")
                    .font(DT.text(13))
                    .foregroundStyle(DT.fgMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .padding(.bottom, 24)
            Button("Scan Apps") { scanApps() }
                .buttonStyle(QuietButtonStyle(variant: .primary))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DT.bg)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(apps.enumerated()), id: \.element.id) { idx, entry in
                    AppRow(appInfo: entry, rank: idx)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(DT.bg)
    }

    // MARK: Scan

    private func scanApps() {
        isScanning = true
        apps = []
        Task.detached(priority: .userInitiated) {
            let found = Self.collectApps()
            await MainActor.run {
                apps = found.sorted { $0.size > $1.size }
                isScanning = false
            }
        }
    }

    private nonisolated static func collectApps() -> [AppInfo] {
        var results: [AppInfo] = []
        let dirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Applications"),
        ]

        for dir in dirs {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension == "app" else { continue }
                enumerator.skipDescendants()

                guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .localizedNameKey]),
                      let size = values.totalFileAllocatedSize
                else { continue }

                results.append(AppInfo(
                    url: fileURL,
                    name: values.localizedName ?? fileURL.deletingPathExtension().lastPathComponent,
                    size: Int64(size),
                    icon: NSWorkspace.shared.icon(forFile: fileURL.path)
                ))
            }
        }
        return results
    }
}

// MARK: - Models

struct AppInfo: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    let icon: NSImage
}

// MARK: - Row

private struct AppRow: View {
    let appInfo: AppInfo
    let rank: Int
    @State private var isHovering = false

    private var tierColor: Color {
        if rank == 0 && appInfo.size >= 100 * 1024 * 1024 { return DT.accent }
        return DT.tier(forBytes: appInfo.size)
    }

    private var fraction: Double {
        // Use 10 GB as reference for the bar
        min(1, Double(appInfo.size) / 10_000_000_000)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: appInfo.icon)
                .resizable()
                .frame(width: 28, height: 28)

            Text(appInfo.name)
                .font(DT.text(13, weight: rank == 0 ? .medium : .regular))
                .foregroundStyle(DT.fg)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Proportional bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DT.line)
                    Capsule()
                        .fill(tierColor)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(width: 120, height: 3)

            Text(SizeFormatter.string(appInfo.size))
                .font(DT.mono(12, weight: rank == 0 ? .semibold : .regular))
                .foregroundStyle(DT.fg)
                .monospacedDigit()
                .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(isHovering ? DT.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([appInfo.url])
            }
            Button("Copy Path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(appInfo.url.path, forType: .string)
            }
        }
    }
}
