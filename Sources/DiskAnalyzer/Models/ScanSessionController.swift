import SwiftUI

// MARK: - Per-session state + scan lifecycle

@MainActor
final class ScanSessionController: ObservableObject, Identifiable {
    let id: UUID
    let url: URL
    let scanDate: Date

    @Published var displayName: String
    @Published var root: FileNode?
    @Published var isScanning = false
    @Published var progress = ScanProgress()
    @Published var elapsed: TimeInterval = 0
    @Published var volumeTotal: Int64?
    @Published var volumeFree: Int64?
    @Published var scanningPaths: Set<URL> = []

    private var scanner: DiskScanner?
    private var scanTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.displayName = url.lastPathComponent
        self.scanDate = Date()
    }

    func startScan() {
        cancel()
        root = nil
        progress = ScanProgress()
        scanningPaths = []
        elapsed = 0
        isScanning = true
        (volumeTotal, volumeFree) = Self.volumeCapacity(for: url)

        let scanner = DiskScanner()
        self.scanner = scanner

        let targetURL = url
        let start = Date()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self?.elapsed = Date().timeIntervalSince(start)
            }
        }

        scanTask = Task { @MainActor [weak self] in
            let result = await scanner.scan(
                at: targetURL,
                onProgress: { progress in
                    Task { @MainActor in
                        // Unstructured Task does NOT inherit parent cancellation,
                        // so Task.isCancelled is always false here. Use isScanning
                        // as the gate: cancel() sets it false immediately, and any
                        // progress arriving after that is stale.
                        guard self?.isScanning ?? false else { return }
                        self?.progress = progress
                    }
                },
                onNodeCreated: { url, node in
                    // No objectWillChange.send() here — let the 100ms progress
                    // reporter pick up scanningPaths changes naturally. This
                    // avoids flooding the main actor with 100K+ invalidation
                    // tasks during a large scan.
                    Task { @MainActor in
                        guard let self else { return }
                        if self.root == nil {
                            self.root = node
                        }
                        self.scanningPaths.insert(url)
                    }
                },
                onNodeUpdated: { url, node in
                    // Deliberately silent. SwiftUI will re-evaluate via the
                    // progress timer's objectWillChange.send() every 100ms,
                    // which batches hundreds of intermediate tree mutations
                    // into a single update pass.
                },
                onScanCompleted: { url, node in
                    Task { @MainActor in
                        guard let self else { return }
                        self.scanningPaths.remove(url)
                    }
                }
            )
            guard let self, !Task.isCancelled else { return }
            self.root = result
            self.isScanning = false
            self.timerTask?.cancel()
            self.timerTask = nil
            self.scanner = nil
            self.scanTask = nil
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

    deinit {
        scanner?.cancel()
        scanTask?.cancel()
        timerTask?.cancel()
    }
}
