import SwiftUI

// MARK: - Right content panel — one session's scan detail

struct ScanDetailView: View {
    @ObservedObject var session: ScanSessionController
    let app: AppViewModel

    @State private var showCloseAlert = false
    @State private var showRecommendations = true
    @StateObject private var analysisViewModel = AnalysisFlowViewModel(
        analyzer: AnalysisEngine(homeURL: FileManager.default.homeDirectoryForCurrentUser),
        coordinator: PlanningCoordinator()
    )

    private var analysisPreferences: AnalysisPreferences {
        AnalysisPreferences(targetBytes: app.targetBytes, preserveRecentDays: 7)
    }

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                toolbar
                Rectangle().fill(DT.line).frame(height: 1)

                if let root = session.root {
                    segmentedControl
                    Rectangle().fill(DT.line).frame(height: 1)

                    if showRecommendations {
                        AnalysisFlowView(viewModel: analysisViewModel)
                    } else {
                        HeroPanelView(
                            root: root,
                            volumeTotal: session.volumeTotal,
                            volumeFree: session.volumeFree
                        )
                        Rectangle().fill(DT.line).frame(height: 1)
                        listBody(root: root)
                    }
                } else if session.isScanning {
                    scanningState
                } else {
                    detailEmptyState
                }

                statusBar
            }
        }
        .onAppear { syncAnalysis() }
        .onChange(of: session.isScanning) { _ in syncAnalysis() }
        .alert("Close scan", isPresented: $showCloseAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Close", role: .destructive) { app.removeSession(session) }
        } message: {
            Text("Close the scan of \(session.displayName)?")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Path — left
            Group {
                Text(session.url.path)
                    .font(DT.mono(11))
                    .foregroundStyle(DT.fgMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(0)

            // Actions — right
            HStack(spacing: 8) {
                if session.isScanning {
                    Button("Cancel") { session.cancel() }
                        .buttonStyle(QuietButtonStyle(variant: .secondary))
                } else {
                    if session.root != nil {
                        Button("Rescan") { session.startScan() }
                            .buttonStyle(QuietButtonStyle(variant: .ghost))
                            .keyboardShortcut("r", modifiers: .command)
                    }
                    newScanMenu
                }
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(DT.bg)
    }

    private var newScanMenu: some View {
        Menu {
            Button("Choose Folder…") { app.pickAndAdd() }
            Button("Scan Home")      { app.addHome() }

            Divider()

            Text("Quick scan")

            ForEach(AppViewModel.quickLocations, id: \.label) { loc in
                Button(loc.label) {
                    let path = (loc.path as NSString).expandingTildeInPath
                    app.addSession(url: URL(fileURLWithPath: path))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text("New Scan")
                    .font(DT.text(12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(DT.hover)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DT.lineStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
    }

    // MARK: Recommendations / Files toggle

    private var segmentedControl: some View {
        HStack(spacing: 6) {
            segment("Recommendations", selected: showRecommendations) {
                showRecommendations = true
            }
            segment("Files", selected: !showRecommendations) {
                showRecommendations = false
            }
            Spacer()
        }
        .padding(.horizontal, DT.gutter)
        .padding(.vertical, 8)
        .background(DT.bg)
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DT.text(12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? DT.fg : DT.fgMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? DT.surface : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(selected ? DT.lineStrong : Color.clear, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Keeps the analysis flow in step with the scan session: scanning while
    /// the scan runs, analysis when it completes (and on fresh/failed states).
    private func syncAnalysis() {
        if session.isScanning {
            analysisViewModel.beginScanning()
        } else if let root = session.root {
            switch analysisViewModel.state {
            case .idle, .scanning, .failed:
                analysisViewModel.startAnalysis(root: root, preferences: analysisPreferences)
            default:
                break
            }
        }
    }

    // MARK: List

    private func listBody(root: FileNode) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(root.children.enumerated()), id: \.element.id) { idx, child in
                    FileNodeRow(
                        node: child,
                        parentSize: root.size,
                        rank: idx,
                        depth: 0,
                        scanningPaths: session.scanningPaths,
                        onMoveToTrash: { app.moveToTrash(url: $0) }
                    )
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
                let parts = SizeFormatter.split(session.progress.bytesScanned)
                Text(parts.number)
                    .font(DT.text(44, weight: .light))
                    .foregroundStyle(DT.fg)
                    .monospacedDigit()
                Text(parts.unit.isEmpty ? "bytes" : parts.unit)
                    .font(DT.text(16))
                    .foregroundStyle(DT.fgMuted)
            }
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.25), value: session.progress.bytesScanned)

            VStack(spacing: 3) {
                Text("\(session.progress.filesScanned.formatted()) items · \(String(format: "%.1fs", session.elapsed))")
                    .font(DT.mono(11))
                    .foregroundStyle(DT.fgMuted)
                Text(session.progress.currentPath)
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

    // MARK: Empty state (detail panel, no scan yet)

    private var detailEmptyState: some View {
        VStack(alignment: .center, spacing: 0) {
            Spacer()

            VStack(spacing: 10) {
                Text("Scan this folder")
                    .font(DT.text(22, weight: .semibold))
                    .foregroundStyle(DT.fg)
                Text("The scan results will appear here once complete.")
                    .font(DT.text(13))
                    .foregroundStyle(DT.fgMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .padding(.bottom, 24)

            Button("Start Scan") { session.startScan() }
                .buttonStyle(QuietButtonStyle(variant: .primary))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DT.bg)
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            if session.isScanning || session.elapsed > 0 {
                statusPair(label: "Files", value: session.progress.filesScanned.formatted())
                statusPair(label: "Size", value: SizeFormatter.string(session.progress.bytesScanned))
                statusPair(label: "Time", value: String(format: "%.1fs", session.elapsed))
                if session.progress.skippedMounts > 0 {
                    statusPair(
                        label: "Skipped",
                        value: "\(session.progress.skippedMounts) off-volume",
                        valueColor: DT.accent
                    )
                }
            }
            Spacer()
            if let root = session.root {
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

// MARK: - FileNodeRow (moved from ContentView)

struct FileNodeRow: View {
    let node: FileNode
    let parentSize: Int64
    let rank: Int
    let depth: Int
    let scanningPaths: Set<URL>
    var onMoveToTrash: ((URL) -> Void)? = nil

    @State private var isExpanded = false

    private var isScanning: Bool { scanningPaths.contains(node.url) }
    private var hasChildren: Bool { !node.children.isEmpty }

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
                } else if node.isDirectory && isScanning {
                    // Directory that hasn't finished scanning yet — show spinner
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }

                FileRowView(node: node, parentSize: parentSize, rank: rank, isScanning: isScanning, onMoveToTrash: onMoveToTrash)
            }
            .padding(.leading, CGFloat(depth) * 18)

            if isExpanded {
                ForEach(Array(node.children.enumerated()), id: \.element.id) { idx, child in
                    FileNodeRow(
                        node: child,
                        parentSize: node.size,
                        rank: idx,
                        depth: depth + 1,
                        scanningPaths: scanningPaths,
                        onMoveToTrash: onMoveToTrash
                    )
                }
            }
        }
    }
}
