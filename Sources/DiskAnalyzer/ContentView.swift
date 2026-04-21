import SwiftUI
import AppKit

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var root: FileNode?
    @Published var selectedURL: URL?
    @Published var isScanning = false
    @Published var progress = ScanProgress()
    @Published var elapsed: TimeInterval = 0

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
}

struct ContentView: View {
    @StateObject private var viewModel = ScanViewModel()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.pickAndScan()
            } label: {
                Label("Choose Folder…", systemImage: "folder")
            }

            Button {
                viewModel.scanHome()
            } label: {
                Label("Scan Home", systemImage: "house")
            }

            if let url = viewModel.selectedURL, !viewModel.isScanning {
                Button {
                    viewModel.scan(url: url)
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }

            if viewModel.isScanning {
                Button(role: .destructive) {
                    viewModel.cancel()
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
                ProgressView().controlSize(.small)
            }

            Spacer()

            if let url = viewModel.selectedURL {
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let root = viewModel.root {
            treeView(root: root)
        } else if viewModel.isScanning {
            VStack(spacing: 12) {
                ProgressView()
                Text("Scanning…").font(.headline)
                Text(viewModel.progress.currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 600)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            emptyState
        }
    }

    private func treeView(root: FileNode) -> some View {
        List {
            FileNodeRow(node: root, parentSize: root.size, rootSize: root.size, isRoot: true)
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Disk Analyzer")
                .font(.title2).bold()
            Text("Choose a folder or volume to see what's using your space.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Scan Home Folder") { viewModel.scanHome() }
                    .buttonStyle(.borderedProminent)
                Button("Choose Folder…") { viewModel.pickAndScan() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            if viewModel.isScanning || viewModel.elapsed > 0 {
                Text("Files: \(viewModel.progress.filesScanned)")
                Text("Size: \(SizeFormatter.string(viewModel.progress.bytesScanned))")
                Text(String(format: "%.1fs", viewModel.elapsed))
                    .foregroundStyle(.secondary)
                if viewModel.progress.skippedMounts > 0 {
                    Text("Skipped \(viewModel.progress.skippedMounts) off-volume entries")
                        .foregroundStyle(.orange)
                        .help("External drives, NAS mounts, and other volumes are excluded so sizes reflect only the boot disk.")
                }
            }
            Spacer()
            if let root = viewModel.root {
                Text("Total: \(SizeFormatter.string(root.size))")
                    .font(.system(.caption, design: .monospaced))
                    .bold()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Recursive row with its own expansion state. Lazy: children aren't rendered
/// until the user expands the row, so huge trees stay responsive.
struct FileNodeRow: View {
    let node: FileNode
    let parentSize: Int64
    let rootSize: Int64
    var isRoot: Bool = false

    @State private var isExpanded: Bool

    init(node: FileNode, parentSize: Int64, rootSize: Int64, isRoot: Bool = false) {
        self.node = node
        self.parentSize = parentSize
        self.rootSize = rootSize
        self.isRoot = isRoot
        _isExpanded = State(initialValue: isRoot)
    }

    var body: some View {
        if let children = node.children, !children.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(children) { child in
                    FileNodeRow(node: child, parentSize: node.size, rootSize: rootSize)
                }
            } label: {
                FileRowView(node: node, parentSize: parentSize, rootSize: rootSize)
            }
        } else {
            FileRowView(node: node, parentSize: parentSize, rootSize: rootSize)
        }
    }
}
