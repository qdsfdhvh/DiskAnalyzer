import Darwin
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
    /// FSID of the volume the scan started on. Every child entry returned
    /// by `getattrlistbulk` carries its own FSID, so cross-mount filtering
    /// is just a scalar compare — no Foundation roundtrip.
    private var rootFSID: fsid_t?

    /// Directory extensions treated as opaque packages: we report their total
    /// size but don't expose their contents in the tree. Curated list of
    /// common Apple bundle types + a few third-party formats; matching on
    /// extension is orders of magnitude cheaper than `.isPackageKey`, which
    /// triggers a LaunchServices UTI lookup per URL.
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

    private static func isPackage(name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        return packageExtensions.contains(ext)
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

        let rootPath = url.path
        guard let rootEntry = BulkScan.stat(path: rootPath) else {
            return emptyDirNode(for: url)
        }
        rootFSID = rootEntry.fsid

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

        let rootName = url.lastPathComponent.isEmpty ? rootPath : url.lastPathComponent
        if rootEntry.isSymlink {
            return emptyDirNode(for: url)
        }
        if !rootEntry.isDir {
            return FileNode(
                url: url, name: rootName, isDirectory: false, size: rootEntry.allocSize
            )
        }
        return await scanDir(url: url, path: rootPath, name: rootName)
    }

    private func emptyDirNode(for url: URL) -> FileNode {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        return FileNode(url: url, name: name, isDirectory: true)
    }

    /// Recursive async scan of one directory. Files are built inline (no
    /// Task overhead); subdirectories fan out via TaskGroup. The scanner's
    /// limiter caps concurrent readdir calls so the fan-out stays bounded
    /// no matter how deep the tree goes.
    private func scanDir(url: URL, path: String, name: String) async -> FileNode {
        if cancelled {
            return FileNode(url: url, name: name, isDirectory: true)
        }

        // Packages: flat-walk with an explicit stack to sum size. Avoids the
        // async fan-out entirely, which matters because packages often hold
        // thousands of tiny files we don't want to expose in the UI.
        if Self.isPackage(name: name) {
            let (bytes, count) = BulkScan.packageTotal(path: path)
            let node = FileNode(url: url, name: name, isDirectory: true, size: bytes)
            if count > 0 {
                counter.addBatch(bytes: bytes, files: count, currentPath: path)
            }
            return node
        }

        // Read this directory under the concurrency gate, release the slot
        // BEFORE awaiting children. Holding it while recursing would serialize
        // the whole tree and defeat the purpose of the pool.
        await limiter.acquire()
        let entries = BulkScan.readDirectory(path: path) ?? []
        await limiter.release()

        let prefix = path.hasSuffix("/") ? path : path + "/"

        // Partition children: files are built inline (cheap), subdirectories
        // are collected for async fan-out.
        var inlineFiles: [FileNode] = []
        var subdirs: [(URL, String, String)] = []  // (url, path, name)
        var leafBytes: Int64 = 0

        for e in entries {
            if cancelled { break }
            if e.isSymlink { continue }
            if let rf = rootFSID, !BulkScan.sameFSID(rf, e.fsid) {
                counter.noteSkippedMount()
                continue
            }

            let childPath = prefix + e.name
            if e.isDir {
                let childURL = URL(fileURLWithPath: childPath, isDirectory: true)
                subdirs.append((childURL, childPath, e.name))
            } else {
                let childURL = URL(fileURLWithPath: childPath, isDirectory: false)
                inlineFiles.append(FileNode(
                    url: childURL, name: e.name, isDirectory: false, size: e.allocSize
                ))
                leafBytes += e.allocSize
            }
        }

        // One Task per subdirectory (never per file). For a ~6M-file home
        // scan with ~50K directories, that's ~50K Tasks — manageable.
        //
        // Skip the fan-out entirely on cancel: each child would early-return
        // anyway, but on a wide tree with thousands of pending subdirs the
        // per-Task spawn + teardown cost shows up as a multi-second tail
        // between "user clicks Cancel" and the scan actually unwinding.
        var subdirNodes: [FileNode] = []
        if !subdirs.isEmpty && !cancelled {
            subdirNodes = await withTaskGroup(of: FileNode.self) { group in
                for (subURL, subPath, subName) in subdirs {
                    group.addTask { [self] in
                        await scanDir(url: subURL, path: subPath, name: subName)
                    }
                }
                var results: [FileNode] = []
                results.reserveCapacity(subdirs.count)
                for await node in group { results.append(node) }
                return results
            }
        }

        // One counter flush per directory, regardless of file count. Keeps
        // lock traffic proportional to directory count, not file count.
        if !inlineFiles.isEmpty {
            counter.addBatch(
                bytes: leafBytes,
                files: inlineFiles.count,
                currentPath: path
            )
        }

        let dirNode = FileNode(url: url, name: name, isDirectory: true)
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
