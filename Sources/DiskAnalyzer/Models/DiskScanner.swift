import Foundation

struct ScanProgress: Sendable {
    var bytesScanned: Int64 = 0
    var filesScanned: Int = 0
    var currentPath: String = ""
    var skippedMounts: Int = 0
}

/// Gates concurrent directory I/O. Without this, async recursion at every
/// level would fan out to thousands of simultaneous readdir/stat syscalls,
/// which is actually slower than keeping roughly CPU-core-count worth of
/// them in flight at any moment.
actor ScanLimiter {
    let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            active = max(0, active - 1)
        }
    }
}

final class DiskScanner: @unchecked Sendable {

    private let counter = Counter()
    private var cancelled = false
    /// Identifier of the volume the scan started on. Anything on a different
    /// volume (external drives, SMB/NFS/AFP mounts, Time Machine snapshots)
    /// is skipped so numbers reflect only the boot disk.
    private var rootVolumeID: (any NSObjectProtocol)?

    /// Keys pre-fetched by `contentsOfDirectory(at:includingPropertiesForKeys:)`
    /// so per-child `resourceValues` calls hit the cache instead of doing a
    /// fresh stat().
    ///
    /// `.isPackageKey` is deliberately absent — asking for it triggers a
    /// LaunchServices UTI lookup per URL, which on a million-file scan costs
    /// real wall-clock seconds. Package-ness is determined below by an
    /// extension whitelist, which is how ~all macOS packages declare
    /// themselves anyway.
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .volumeIdentifierKey
    ]

    /// Directory extensions treated as opaque packages: we report their total
    /// size but don't expose their contents in the tree. Curated list of
    /// common Apple bundle types + a few third-party formats; matching on
    /// extension is orders of magnitude cheaper than `.isPackageKey`.
    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "docset",
        "photoslibrary", "musiclibrary", "tvlibrary", "aplibrary",
        "imovielibrary", "theater",
        "rtfd", "pages", "numbers", "key",
        "dsym", "xcarchive", "xcodeproj", "xcworkspace", "playground",
        "pkg", "mpkg",
        "scptd", "wdgt", "qlgenerator", "mdimporter", "component",
        "lbaction", "prefpane"
    ]

    private static func isPackage(_ url: URL) -> Bool {
        packageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Limit simultaneous readdir calls to ~CPU core count. The multiplier
    /// above activeProcessorCount is intentional — I/O-bound tasks benefit
    /// from a little over-subscription.
    private let limiter = ScanLimiter(
        limit: max(4, ProcessInfo.processInfo.activeProcessorCount)
    )

    func cancel() {
        cancelled = true
    }

    func scan(
        at url: URL,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async -> FileNode {
        cancelled = false
        counter.reset()
        rootVolumeID = (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))
            .flatMap { $0.volumeIdentifier }

        let reporter = Task.detached(priority: .utility) { [counter] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                onProgress(counter.snapshot())
            }
        }
        defer {
            reporter.cancel()
            onProgress(counter.snapshot())
        }

        return await scanAsync(url: url) ?? emptyDirNode(for: url)
    }

    private func emptyDirNode(for url: URL) -> FileNode {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        return FileNode(url: url, name: name, isDirectory: true)
    }

    /// Recursive async scan. Files are handled inline (no Task overhead);
    /// subdirectories fan out via TaskGroup. The scanner's limiter caps
    /// concurrent readdir calls so the fan-out stays bounded no matter how
    /// deep the tree goes.
    private func scanAsync(url: URL) async -> FileNode? {
        if cancelled { return nil }

        guard let values = try? url.resourceValues(forKeys: Self.resourceKeys) else {
            return nil
        }

        if values.isSymbolicLink ?? false { return nil }

        if let rootVol = rootVolumeID,
           let vol = values.volumeIdentifier,
           !vol.isEqual(rootVol) {
            counter.noteSkippedMount()
            return nil
        }

        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent

        if !(values.isDirectory ?? false) {
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            return FileNode(url: url, name: name, isDirectory: false, size: size)
        }

        let dirNode = FileNode(url: url, name: name, isDirectory: true)

        // Packages: flat-walk with an enumerator to sum size. Avoids the
        // async fan-out entirely, which matters because packages often hold
        // thousands of tiny files we don't want to expose in the UI anyway.
        if Self.isPackage(url) {
            let (size, fileCount) = Self.packageTotal(at: url)
            dirNode.size = size
            dirNode.children = nil
            if fileCount > 0 {
                counter.addBatch(bytes: size, files: fileCount, currentPath: url.path)
            }
            return dirNode
        }

        // Read this directory under the concurrency gate, release the slot
        // BEFORE awaiting children. Holding it while recursing would serialize
        // the whole tree and defeat the purpose of the pool.
        await limiter.acquire()
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: []
            )
        } catch {
            await limiter.release()
            return dirNode
        }
        await limiter.release()

        // Partition children: files are built inline (cheap), subdirectories
        // are collected for async fan-out.
        var inlineFiles: [FileNode] = []
        var subdirURLs: [URL] = []
        var leafBytes: Int64 = 0

        for child in contents {
            if cancelled { break }
            guard let cv = try? child.resourceValues(forKeys: Self.resourceKeys) else {
                continue
            }
            if cv.isSymbolicLink ?? false { continue }
            if let rootVol = rootVolumeID,
               let vol = cv.volumeIdentifier,
               !vol.isEqual(rootVol) {
                counter.noteSkippedMount()
                continue
            }

            let childName = child.lastPathComponent
            if cv.isDirectory ?? false {
                subdirURLs.append(child)
            } else {
                let size = Int64(cv.totalFileAllocatedSize ?? cv.fileSize ?? 0)
                inlineFiles.append(FileNode(
                    url: child, name: childName, isDirectory: false, size: size
                ))
                leafBytes += size
            }
        }

        // One Task per subdirectory (never per file). For a ~6M-file home
        // scan with ~50K directories, that's ~50K Tasks — manageable.
        var subdirNodes: [FileNode] = []
        if !subdirURLs.isEmpty {
            subdirNodes = await withTaskGroup(of: FileNode?.self) { group in
                for sub in subdirURLs {
                    group.addTask { [self] in await scanAsync(url: sub) }
                }
                var results: [FileNode] = []
                for await node in group {
                    if let node { results.append(node) }
                }
                return results
            }
        }

        // One counter flush per directory, regardless of file count.
        if !inlineFiles.isEmpty {
            counter.addBatch(
                bytes: leafBytes,
                files: inlineFiles.count,
                currentPath: url.path
            )
        }

        let allChildren = inlineFiles + subdirNodes
        var total: Int64 = 0
        for c in allChildren {
            c.parent = dirNode
            total += c.size
        }

        dirNode.size = total
        dirNode.children = allChildren.sorted { $0.size > $1.size }
        return dirNode
    }

    /// Flat walk over a package's contents to sum its total size. We use the
    /// FileManager enumerator here rather than recursing because we throw
    /// away the tree — only the aggregate number matters for a package leaf.
    private static func packageTotal(at url: URL) -> (bytes: Int64, fileCount: Int) {
        var total: Int64 = 0
        var count = 0
        let keys: [URLResourceKey] = [
            .totalFileAllocatedSizeKey, .fileSizeKey,
            .isDirectoryKey, .isSymbolicLinkKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: []
        ) else { return (0, 0) }

        for case let child as URL in enumerator {
            guard let v = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink ?? false { continue }
            if v.isDirectory ?? false { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            count += 1
        }
        return (total, count)
    }

    // MARK: - Thread-safe counter

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64 = 0
        private var files: Int = 0
        private var current: String = ""
        private var skipped: Int = 0

        /// Bulk-apply the leaf-file totals accumulated while scanning one
        /// directory. Keeping this per-directory (not per-file) keeps lock
        /// traffic proportional to directory count, not file count.
        func addBatch(bytes extra: Int64, files extraFiles: Int, currentPath: String) {
            lock.lock()
            bytes += extra
            files += extraFiles
            current = currentPath
            lock.unlock()
        }

        func noteSkippedMount() {
            lock.lock()
            skipped += 1
            lock.unlock()
        }

        func snapshot() -> ScanProgress {
            lock.lock()
            defer { lock.unlock() }
            return ScanProgress(
                bytesScanned: bytes,
                filesScanned: files,
                currentPath: current,
                skippedMounts: skipped
            )
        }

        func reset() {
            lock.lock()
            bytes = 0; files = 0; current = ""; skipped = 0
            lock.unlock()
        }
    }
}
