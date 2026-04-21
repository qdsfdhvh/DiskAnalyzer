import SwiftUI
import AppKit

// MARK: - View model

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var root: FileNode?
    @Published var selectedURL: URL?
    @Published var isScanning = false
    @Published var progress = ScanProgress()
    @Published var elapsed: TimeInterval = 0
    @Published var volumeTotal: Int64?
    @Published var volumeFree: Int64?

    private var scanner: DiskScanner?
    private var scanTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    func pickAndScan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder or volume to analyze"
        panel.prompt = "Analyze"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        if panel.runModal() == .OK, let url = panel.url {
            scan(url: url)
        }
    }

    func scanHome() {
        scan(url: FileManager.default.homeDirectoryForCurrentUser)
    }

    func scan(url: URL) {
        cancel()

        selectedURL = url
        root = nil
        progress = ScanProgress()
        elapsed = 0
        isScanning = true
        (volumeTotal, volumeFree) = Self.volumeCapacity(for: url)

        let scanner = DiskScanner()
        self.scanner = scanner

        let start = Date()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.elapsed = Date().timeIntervalSince(start)
            }
        }

        scanTask = Task { @MainActor [weak self] in
            let result = await scanner.scan(at: url) { progress in
                Task { @MainActor in
                    self?.progress = progress
                }
            }
            guard let self else { return }
            self.root = result
            self.isScanning = false
            self.timerTask?.cancel()
            self.elapsed = Date().timeIntervalSince(start)
        }
    }

    func cancel() {
        scanner?.cancel()
        scanTask?.cancel()
        timerTask?.cancel()
        scanner = nil
        scanTask = nil
        timerTask = nil
        isScanning = false
    }

    private static func volumeCapacity(for url: URL) -> (Int64?, Int64?) {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else { return (nil, nil) }
        let total = values.volumeTotalCapacity.map { Int64($0) }
        let free = values.volumeAvailableCapacityForImportantUsage
        return (total, free)
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var viewModel = ScanViewModel()

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(DT.line).frame(height: 1)

                if let root = viewModel.root {
                    HeroPanelView(
                        root: root,
                        volumeTotal: viewModel.volumeTotal,
                        volumeFree: viewModel.volumeFree
                    )
                    Rectangle().fill(DT.line).frame(height: 1)
                    listBody(root: root)
                } else if viewModel.isScanning {
                    scanningState
                } else {
                    emptyState
                }

                statusBar
            }
        }
        .frame(minWidth: 880, minHeight: 600)
        .preferredColorScheme(.light)
    }

    // MARK: Toolbar

    /// The custom toolbar. Deliberately does NOT repeat the app name — the
    /// native window title bar already shows "Disk Analyzer". We only surface
    /// the current path (or an empty-state hint) + action buttons.
    private var toolbar: some View {
        HStack(spacing: 12) {
            // Left: path or hint. Flexes + truncates so the buttons always fit.
            Group {
                if let url = viewModel.selectedURL {
                    Text(url.path)
                        .font(DT.mono(11))
                        .foregroundStyle(DT.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No folder scanned yet")
                        .font(DT.text(12))
                        .foregroundStyle(DT.fgSubtle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)

            // Right: action buttons. fixedSize + layoutPriority(1) guarantees
            // they always render at natural width, regardless of window size.
            HStack(spacing: 8) {
                if viewModel.isScanning {
                    Button("Cancel") { viewModel.cancel() }
                        .buttonStyle(QuietButtonStyle(variant: .secondary))
                } else {
                    if viewModel.selectedURL != nil {
                        Button("Rescan") {
                            if let url = viewModel.selectedURL { viewModel.scan(url: url) }
                        }
                        .buttonStyle(QuietButtonStyle(variant: .ghost))
                        .keyboardShortcut("r", modifiers: .command)
                    }
                    Button("Choose Folder") { viewModel.pickAndScan() }
                        .buttonStyle(QuietButtonStyle(variant: .secondary))
                        .keyboardShortcut("o", modifiers: .command)
                    Button("Scan Home") { viewModel.scanHome() }
                        .buttonStyle(QuietButtonStyle(variant: .primary))
                        .keyboardShortcut("h", modifiers: .command)
                }
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(DT.bg)
    }

    // MARK: List

    private func listBody(root: FileNode) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let children = root.children {
                    ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                        FileNodeRow(
                            node: child,
                            parentSize: root.size,
                            rank: idx,
                            depth: 0
                        )
                    }
                }
            }
            .padding(.horizontal, DT.gutter - 8)
            .padding(.vertical, 10)
        }
        .background(DT.bg)
    }

    // MARK: Scanning state

    private var scanningState: some View {
        VStack(alignment: .center, spacing: 18) {
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                let parts = SizeFormatter.split(viewModel.progress.bytesScanned)
                Text(parts.number)
                    .font(DT.text(44, weight: .light))
                    .foregroundStyle(DT.fg)
                    .monospacedDigit()
                Text(parts.unit.isEmpty ? "bytes" : parts.unit)
                    .font(DT.text(16))
                    .foregroundStyle(DT.fgMuted)
            }
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.25), value: viewModel.progress.bytesScanned)

            VStack(spacing: 3) {
                Text("\(viewModel.progress.filesScanned.formatted()) items · \(String(format: "%.1fs", viewModel.elapsed))")
                    .font(DT.mono(11))
                    .foregroundStyle(DT.fgMuted)
                Text(viewModel.progress.currentPath)
                    .font(DT.mono(10))
                    .foregroundStyle(DT.fgSubtle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DT.bg)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 0) {
            Spacer()

            VStack(spacing: 10) {
                Text("See what's using your disk")
                    .font(DT.text(22, weight: .semibold))
                    .foregroundStyle(DT.fg)
                Text("Pick a folder. Cross-volume mounts — NAS, externals — are skipped automatically.")
                    .font(DT.text(13))
                    .foregroundStyle(DT.fgMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .padding(.bottom, 24)

            HStack(spacing: 10) {
                Button("Scan Home") { viewModel.scanHome() }
                    .buttonStyle(QuietButtonStyle(variant: .primary))
                Button("Choose Folder") { viewModel.pickAndScan() }
                    .buttonStyle(QuietButtonStyle(variant: .secondary))
            }

            Spacer()

            VStack(spacing: 14) {
                Text("Quick scan")
                    .font(DT.text(11, weight: .medium))
                    .foregroundStyle(DT.fgMuted)
                HStack(spacing: 6) {
                    QuickChip(label: "DerivedData") {
                        viewModel.scan(url: URL(fileURLWithPath: ("~/Library/Developer/Xcode/DerivedData" as NSString).expandingTildeInPath))
                    }
                    QuickChip(label: "Simulators") {
                        viewModel.scan(url: URL(fileURLWithPath: ("~/Library/Developer/CoreSimulator" as NSString).expandingTildeInPath))
                    }
                    QuickChip(label: "Caches") {
                        viewModel.scan(url: URL(fileURLWithPath: ("~/Library/Caches" as NSString).expandingTildeInPath))
                    }
                    QuickChip(label: "Containers") {
                        viewModel.scan(url: URL(fileURLWithPath: ("~/Library/Containers" as NSString).expandingTildeInPath))
                    }
                    QuickChip(label: "Downloads") {
                        viewModel.scan(url: URL(fileURLWithPath: ("~/Downloads" as NSString).expandingTildeInPath))
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DT.bg)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            if viewModel.isScanning || viewModel.elapsed > 0 {
                statusPair(label: "Files", value: viewModel.progress.filesScanned.formatted())
                statusPair(label: "Size", value: SizeFormatter.string(viewModel.progress.bytesScanned))
                statusPair(label: "Time", value: String(format: "%.1fs", viewModel.elapsed))
                if viewModel.progress.skippedMounts > 0 {
                    statusPair(
                        label: "Skipped",
                        value: "\(viewModel.progress.skippedMounts) off-volume",
                        valueColor: DT.accent
                    )
                }
            }
            Spacer()
            if let root = viewModel.root {
                statusPair(label: "Total", value: SizeFormatter.string(root.size), valueColor: DT.fg)
            }
        }
        .padding(.horizontal, DT.gutter)
        .padding(.vertical, 8)
        .background(DT.bg)
        .overlay(Rectangle().fill(DT.line).frame(height: 1), alignment: .top)
    }

    private func statusPair(label: String, value: String, valueColor: Color = DT.fgMuted) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(DT.text(10))
                .foregroundStyle(DT.fgSubtle)
            Text(value)
                .font(DT.mono(11))
                .foregroundStyle(valueColor)
                .monospacedDigit()
        }
    }
}

// MARK: - Support views

private struct QuickChip: View {
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DT.text(11, weight: .medium))
                .foregroundStyle(hover ? DT.accent : DT.fg)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(hover ? DT.accentSoft : DT.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .stroke(hover ? DT.accent.opacity(0.3) : DT.lineStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Recursive outline

/// Hand-rolled disclosure so the chevron matches the quiet palette.
struct FileNodeRow: View {
    let node: FileNode
    let parentSize: Int64
    let rank: Int
    let depth: Int

    @State private var isExpanded = false

    private var hasChildren: Bool { node.children?.isEmpty == false }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if hasChildren {
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DT.fgMuted)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }

                FileRowView(node: node, parentSize: parentSize, rank: rank)
            }
            .padding(.leading, CGFloat(depth) * 18)

            if isExpanded, let children = node.children {
                ForEach(Array(children.enumerated()), id: \.element.id) { idx, child in
                    FileNodeRow(
                        node: child,
                        parentSize: node.size,
                        rank: idx,
                        depth: depth + 1
                    )
                }
            }
        }
    }
}
