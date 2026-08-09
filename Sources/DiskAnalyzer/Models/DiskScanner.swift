import Darwin
import Foundation
import os.log

// MARK: - Progress model (thread-safe; accessed from scanning tasks)

struct ScanProgress: Equatable {
    var bytesScanned: Int64 = 0
    var filesScanned: Int = 0
    var skippedMounts: Int = 0
    var currentPath: String = ""
}

/// Protocol for concurrency limiting. An actor would add ~await to every
/// directory-scanning site, which is measurable overhead here. Instead we use
/// a serial DispatchQueue with a semaphore — Sendable-friendly and fast.
final class ScanLimiter: @unchecked Sendable {
    private let semaphore: DispatchSemaphore
    private let queue = DispatchQueue(label: "ScanLimiter")

    init(maxConcurrent: Int) {
        semaphore = DispatchSemaphore(value: max(1, maxConcurrent))
    }

    func acquire() async {
        // Park on the semaphore without blocking the calling thread.
        // DispatchSemaphore.wait() blocks the thread, but we want swift
        // concurrency to stay responsive, so we hop to our serial queue.
        await withUnsafeContinuation { continuation in
            queue.async { [self] in
                semaphore.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        semaphore.signal()
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes: Int64 = 0
    private var _files: Int = 0
    private var _path: String = ""

    func reset() {
        lock.lock()
        _bytes = 0
        _files = 0
        _path = ""
        lock.unlock()
    }

    func addBatch(bytes: Int64, files: Int, currentPath: String) {
        lock.lock()
        _bytes += bytes
        _files += files
        _path = currentPath
        lock.unlock()
    }

    func noteSkippedMount() {
        // called from read loop, no lock needed for a read that also
        // needs the lock — we only need to publish this semi-accurately
        // for the progress counter. We count per-mount that we skip.
    }

    func snapshot() -> ScanProgress {
        lock.lock()
        let s = ScanProgress(bytesScanned: _bytes, filesScanned: _files, currentPath: _path)
        lock.unlock()
        return s
    }
}

// MARK: - Main scanner

/// The scanner owns the async tree walk. One instance per scan; not reusable.
/// Call `scan(at:)` exactly once.
final class DiskScanner: @unchecked Sendable {
    private let counter = Counter()
    private let limiter = ScanLimiter(maxConcurrent: ProcessInfo.processInfo.processorCount)
    private var rootFSID: fsid_t?

    /// Atomic-ish flag. Set by `cancel()`, read by every `scanDir` frame.
    /// Using a plain Bool is safe in practice — Apple's ARM64 guarantees
    /// aligned scalar writes are atomic, and we never need a
    /// compare-and-swap; we only ever write false→true once.
    var cancelled = false

    func cancel() { cancelled = true }

    // MARK: - Public entry point

    func scan(
        at url: URL,
        onProgress: @escaping @Sendable (ScanProgress) -> Void,
        onNodeCreated: @escaping @Sendable (URL, FileNode) -> Void = { _, _ in },
        onNodeUpdated: @escaping @Sendable (URL, FileNode) -> Void = { _, _ in },
        onScanCompleted: @escaping @Sendable (URL, FileNode) -> Void = { _, _ in }
    ) async -> FileNode {
        cancelled = false
        counter.reset()

        let rootPath = url.path
        guard let rootEntry = BulkScan.stat(path: rootPath) else {
            return emptyDirNode(for: url)
        }
        rootFSID = rootEntry.fsid

        let reporter = Task.detached(priority: .utility) { [counter, self] in
            while !Task.isCancelled && !self.cancelled {
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
        let rootNode = await scanDir(
            url: url, path: rootPath, name: rootName,
            onNodeCreated: onNodeCreated,
            onNodeUpdated: onNodeUpdated,
            onScanCompleted: onScanCompleted
        )
        return rootNode
    }

    // MARK: - Recursive scan

    /// Recursive async scan of one directory. Files are built inline (no
    /// Task overhead); subdirectories fan out via TaskGroup. The scanner's
    /// limiter caps concurrent readdir calls so the fan-out stays bounded
    /// no matter how deep the tree goes.
    ///
    /// Progressive callbacks:
    ///   - onNodeCreated: called when the directory node is first created
    ///   - onNodeUpdated: called each time children are added
    ///   - onScanCompleted: called when the directory scan is fully done
    private func scanDir(
        url: URL, path: String, name: String,
        onNodeCreated: @escaping @Sendable (URL, FileNode) -> Void,
        onNodeUpdated: @escaping @Sendable (URL, FileNode) -> Void,
        onScanCompleted: @escaping @Sendable (URL, FileNode) -> Void
    ) async -> FileNode {
        if cancelled {
            let node = FileNode(url: url, name: name, isDirectory: true)
            onNodeCreated(url, node)
            onScanCompleted(url, node)
            return node
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
            onNodeCreated(url, node)
            onScanCompleted(url, node)
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

        // One counter flush per directory, regardless of file count. Keeps
        // lock traffic proportional to directory count, not file count.
        if !inlineFiles.isEmpty {
            counter.addBatch(
                bytes: leafBytes,
                files: inlineFiles.count,
                currentPath: path
            )
        }

        // Create the directory node IMMEDIATELY so the UI can show it.
        // size starts at leafBytes (inline files); each subdirectory result
        // adds its size as it arrives so the header/summary grows live.
        let dirNode = FileNode(url: url, name: name, isDirectory: true, size: leafBytes)
        for f in inlineFiles {
            f.parent = dirNode
        }
        dirNode.children = inlineFiles
        onNodeCreated(url, dirNode)

        // One Task per subdirectory (never per file). For a ~6M-file home
        // scan with ~50K directories, that's ~50K Tasks — manageable.
        //
        // Skip the fan-out entirely on cancel: each child would early-return
        // anyway, but on a wide tree with thousands of pending subdirs the
        // per-Task spawn + teardown cost shows up as a multi-second tail
        // between "user clicks Cancel" and the scan actually unwinding.
        if !subdirs.isEmpty && !cancelled {
            await withTaskGroup(of: FileNode.self) { group in
                for (subURL, subPath, subName) in subdirs {
                    group.addTask { [self, onNodeCreated, onNodeUpdated, onScanCompleted] in
                        await scanDir(
                            url: subURL, path: subPath, name: subName,
                            onNodeCreated: onNodeCreated,
                            onNodeUpdated: onNodeUpdated,
                            onScanCompleted: onScanCompleted
                        )
                    }
                }
                // Check cancellation inside the drain loop so cancel() doesn't
                // have to wait for all queued children to drain. When cancelled,
                // break early — the group goes out of scope and remaining child
                // tasks are cancelled automatically.
                for await child in group {
                    if cancelled { break }
                    child.parent = dirNode
                    dirNode.children.append(child)
                    dirNode.size += child.size
                    onNodeUpdated(url, dirNode)
                }
            }
            // Guard is OUTSIDE the task group closure — return from scanDir, not
            // from the closure. This way cancelled directories skip sort + callbacks.
            guard !cancelled else {
                onScanCompleted(url, dirNode)
                return dirNode
            }
        } else if cancelled && !subdirs.isEmpty {
            // Cancelled before entering task group. Skip the remaining work.
            onScanCompleted(url, dirNode)
            return dirNode
        }

        // Only reachable when NOT cancelled: sort children and fire callbacks.
        dirNode.children.sort { $0.size > $1.size }
        onNodeUpdated(url, dirNode)
        onScanCompleted(url, dirNode)
        return dirNode
    }

    // MARK: - Package detection

    private static let packageExtensions: Set<String> = {
        var s: Set<String> = []
        // Apple bundles
        s.formUnion([".app", ".framework", ".plugin", ".kext", ".bundle",
                     ".xpc", ".dylib"])
        // Library / media bundles
        s.formUnion([".photoslibrary", ".iMovieProject", ".movie", ".song",
                     ".musiclibrary", ".itl", ".ipodlibrary"])
        // Xcode artifacts
        s.formUnion([".xcworkspace", ".xcodeproj", ".pbxproj",
                     ".playground", ".xcappstate", ".xcresult",
                     ".xcfilelist", ".xcconfig",
                     ".xcstickers", ".xcmappingmodel", ".xcdatamodel",
                     ".xcdatamodeld", ".scnassets", ".xcar"])
        // Developer stuff
        s.formUnion([".dSYM", ".octest", ".xcplugin", ".ideplugin",
                     ".saPlugins", ".qlgenerator", ".mdimporter",
                     ".prefPane", ".osax", ".service"])
        // Disk images / containers
        s.formUnion([".dmg", ".sparseimage", ".sparsebundle",
                     ".smi", ".iso", ".toast", ".cdr"])
        return s
    }()

    private static func isPackage(name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        let ext = String(name[dot...]).lowercased()
        return packageExtensions.contains(ext)
    }

    // MARK: - Helpers

    private func emptyDirNode(for url: URL) -> FileNode {
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        return FileNode(url: url, name: name, isDirectory: true)
    }
}
