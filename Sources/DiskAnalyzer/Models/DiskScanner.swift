import Foundation

struct ScanProgress: Sendable {
    var bytesScanned: Int64 = 0
    var filesScanned: Int = 0
    var currentPath: String = ""
    var skippedMounts: Int = 0
}

final class DiskScanner: @unchecked Sendable {

    private let counter = Counter()
    private var cancelled = false
    /// Identifier of the volume the scan started on. Anything on a different
    /// volume (external drives, SMB/NFS/AFP mounts, Time Machine snapshots,
    /// Photos/Aperture libraries that live elsewhere) is skipped so the numbers
    /// reflect what's actually taking space on the boot disk.
    /// Compared via `isEqual(_:)` — the underlying type is NSObject-derived.
    private var rootVolumeID: (any NSObjectProtocol)?

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .isPackageKey,
        .volumeIdentifierKey
    ]

    /// Minimum child count at which it's worth paying Task/TaskGroup overhead
    /// to parallelize a directory's children. Below this, serial is faster.
    private static let parallelThreshold = 8

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

        // Periodic progress reporter on a background task.
        let reporter = Task.detached(priority: .utility) { [counter] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                onProgress(counter.snapshot())
            }
        }
        defer {
            reporter.cancel()
            // Final report
            onProgress(counter.snapshot())
        }

        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let root = FileNode(url: url, name: name, isDirectory: true)

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: []
            )
        } catch {
            return root
        }

        let scanner = self
        let children: [FileNode] = await withTaskGroup(of: FileNode?.self) { group in
            for child in contents {
                group.addTask { [scanner] in
                    if scanner.cancelled { return nil }
                    // Top-level TaskGroup already gives 1 layer of parallelism;
                    // allow up to 2 more layers inside scanParallel before
                    // falling through to the synchronous scanRecursively.
                    return await scanner.scanParallel(url: child, parallelDepth: 2)
                }
            }
            var results: [FileNode] = []
            for await node in group {
                if let node { results.append(node) }
            }
            return results
        }

        var total: Int64 = 0
        var leafBytes: Int64 = 0
        var leafFiles = 0
        for c in children {
            c.parent = root
            total += c.size
            if !c.isDirectory {
                leafBytes += c.size
                leafFiles += 1
            }
        }
        if leafFiles > 0 {
            counter.addBatch(bytes: leafBytes, files: leafFiles, currentPath: url.path)
        }
        root.children = children.sorted { $0.size > $1.size }
        root.size = total
        return root
    }

    /// Recursive, synchronous scan run on a background thread.
    private func scanRecursively(url: URL) -> FileNode? {
        if cancelled { return nil }

        let values = try? url.resourceValues(forKeys: Self.resourceKeys)

        // Skip symlinks to avoid cycles and double-counting.
        if values?.isSymbolicLink ?? false { return nil }

        // Skip anything on a different volume (NAS, external drives, etc.).
        // Network mounts under ~/Library/Containers/.../ServerConn/smb are a
        // common offender: they look like local paths but live on SMB.
        if let root = rootVolumeID,
           let vol = values?.volumeIdentifier,
           !vol.isEqual(root) {
            counter.noteSkippedMount()
            return nil
        }

        let isDir = values?.isDirectory ?? false
        let name = url.lastPathComponent

        if !isDir {
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            // Counter update is batched into the parent directory's flush.
            return FileNode(url: url, name: name, isDirectory: false, size: size)
        }

        // Treat app bundles (.app, .photoslibrary, etc.) as opaque for a cleaner tree,
        // but still sum their contents so size is accurate.
        let isPackage = values?.isPackage ?? false

        let dirNode = FileNode(url: url, name: name, isDirectory: true)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: []
        ) else {
            // Permission denied or unreadable directory.
            return dirNode
        }

        var childNodes: [FileNode] = []
        var total: Int64 = 0
        var leafBytes: Int64 = 0
        var leafFiles = 0

        for child in contents {
            if cancelled { break }
            if let sub = scanRecursively(url: child) {
                sub.parent = dirNode
                total += sub.size
                childNodes.append(sub)
                if !sub.isDirectory {
                    leafBytes += sub.size
                    leafFiles += 1
                }
            }
        }

        if leafFiles > 0 {
            counter.addBatch(bytes: leafBytes, files: leafFiles, currentPath: url.path)
        }

        dirNode.size = total
        // Packages are leaves in the UI but still report correct total.
        dirNode.children = isPackage ? nil : childNodes.sorted { $0.size > $1.size }
        return dirNode
    }

    /// Async variant of `scanRecursively` that keeps a small parallelism
    /// budget. At each directory level, if the budget is non-zero and the
    /// directory has enough children to justify Task overhead, it fans out
    /// via a TaskGroup. Otherwise it falls through to the fully synchronous
    /// `scanRecursively` path. This keeps the hot deep-recursion path free
    /// of async machinery, which measured slower when applied uniformly.
    private func scanParallel(url: URL, parallelDepth: Int) async -> FileNode? {
        if cancelled { return nil }

        let values = try? url.resourceValues(forKeys: Self.resourceKeys)

        if values?.isSymbolicLink ?? false { return nil }

        if let root = rootVolumeID,
           let vol = values?.volumeIdentifier,
           !vol.isEqual(root) {
            counter.noteSkippedMount()
            return nil
        }

        let isDir = values?.isDirectory ?? false
        let name = url.lastPathComponent

        if !isDir {
            let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            return FileNode(url: url, name: name, isDirectory: false, size: size)
        }

        let isPackage = values?.isPackage ?? false
        let dirNode = FileNode(url: url, name: name, isDirectory: true)

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(Self.resourceKeys),
            options: []
        ) else {
            return dirNode
        }

        var childNodes: [FileNode] = []
        var total: Int64 = 0
        var leafBytes: Int64 = 0
        var leafFiles = 0

        if parallelDepth > 0 && contents.count >= Self.parallelThreshold {
            let scanner = self
            let nextDepth = parallelDepth - 1
            let subs: [FileNode] = await withTaskGroup(of: FileNode?.self) { group in
                for child in contents {
                    group.addTask { [scanner] in
                        if scanner.cancelled { return nil }
                        if nextDepth > 0 {
                            return await scanner.scanParallel(url: child, parallelDepth: nextDepth)
                        } else {
                            return scanner.scanRecursively(url: child)
                        }
                    }
                }
                var results: [FileNode] = []
                for await node in group {
                    if let node { results.append(node) }
                }
                return results
            }
            for sub in subs {
                sub.parent = dirNode
                total += sub.size
                childNodes.append(sub)
                if !sub.isDirectory {
                    leafBytes += sub.size
                    leafFiles += 1
                }
            }
        } else {
            for child in contents {
                if cancelled { break }
                if let sub = scanRecursively(url: child) {
                    sub.parent = dirNode
                    total += sub.size
                    childNodes.append(sub)
                    if !sub.isDirectory {
                        leafBytes += sub.size
                        leafFiles += 1
                    }
                }
            }
        }

        if leafFiles > 0 {
            counter.addBatch(bytes: leafBytes, files: leafFiles, currentPath: url.path)
        }

        dirNode.size = total
        dirNode.children = isPackage ? nil : childNodes.sorted { $0.size > $1.size }
        return dirNode
    }

    // MARK: - Thread-safe counter

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64 = 0
        private var files: Int = 0
        private var current: String = ""
        private var skipped: Int = 0

        /// Bulk-apply the leaf-file totals accumulated while scanning one
        /// directory. Keeping this per-directory (instead of per-file) keeps
        /// lock traffic proportional to directory count, not file count —
        /// a big win on trees with hundreds of thousands of files.
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
