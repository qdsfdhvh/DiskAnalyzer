import Foundation

// MARK: - Discovery result

struct SeedDiscoveryResult: Sendable, Equatable {
    let seeds: [CandidateSeed]
    /// Candidates dropped because `limit` was exceeded, after ordering.
    let omittedCount: Int
}

// MARK: - Discovery

/// Single-pass in-memory traversal of a completed scan tree that emits bounded
/// `CandidateSeed` values using only node URL, size, type, and tree position.
///
/// No filesystem metadata calls. Age-dependent predicates (old installers,
/// old downloads) are deliberately deferred to enrichment, which is the only
/// stage allowed to touch the filesystem.
struct CandidateSeedDiscovery: Sendable {

    // Size thresholds from Architecture section 5.
    static let appCacheMinBytes: Int64 = 250 * 1024 * 1024
    static let installerMinBytes: Int64 = 100 * 1024 * 1024
    static let downloadMinBytes: Int64 = 500 * 1024 * 1024
    static let simulatorMinBytes: Int64 = 1024 * 1024 * 1024
    static let largeFileMinBytes: Int64 = 1024 * 1024 * 1024

    private static let installerExtensions: Set<String> = ["dmg", "pkg", "xip", "zip"]

    /// Traverses `root` once (excluding the root node itself) and returns
    /// bounded, ordered candidate seeds.
    func discover(root: FileNode, homeURL: URL, limit: Int = 200) -> SeedDiscoveryResult {
        let home = standardizedPath(homeURL)
        let rootPath = standardizedPath(root.url)

        var seeds: [CandidateSeed] = []
        var seen: Set<String> = []
        var stack: [FileNode] = root.children

        while let node = stack.popLast() {
            if node.isDirectory {
                stack.append(contentsOf: node.children)
            }
            guard let seed = classify(node, home: home, rootPath: rootPath) else { continue }
            if seen.insert(seed.url.path).inserted {
                seeds.append(seed)
            }
        }

        // Specific rules outrank generic large files; within each group,
        // larger items come first. Cap applies after ordering.
        let ordered = seeds.sorted { a, b in
            let aGeneric = a.category == .largeFile
            let bGeneric = b.category == .largeFile
            if aGeneric != bGeneric { return !aGeneric }
            return a.treeSize > b.treeSize
        }

        guard ordered.count > limit else {
            return SeedDiscoveryResult(seeds: ordered, omittedCount: 0)
        }
        return SeedDiscoveryResult(
            seeds: Array(ordered.prefix(limit)),
            omittedCount: ordered.count - limit
        )
    }

    // MARK: Classification

    private func classify(_ node: FileNode, home: String, rootPath: String) -> CandidateSeed? {
        let path = standardizedPath(node.url)
        let size = node.size

        // 1. DerivedData — the directory itself, or direct children when the
        //    scan root IS the DerivedData directory.
        if node.isDirectory, isDerivedData(path: path, home: home, rootPath: rootPath) {
            return seed(path: path, category: .developerCache, treeSize: size)
        }

        // 2. App cache — direct child of ~/Library/Caches, >= 250 MB.
        if size >= Self.appCacheMinBytes, parentPath(of: path) == cachesPath(home) {
            return seed(path: path, category: .applicationCache, treeSize: size)
        }

        // 3. Old installer — installer extension anywhere under ~/Downloads,
        //    >= 100 MB. Age predicate applied during enrichment.
        if size >= Self.installerMinBytes, isInstaller(path: path), isUnderDownloads(path, home: home) {
            return seed(path: path, category: .oldInstaller, treeSize: size)
        }

        // 4. Old download — direct child of ~/Downloads, >= 500 MB.
        //    Age predicate applied during enrichment.
        if size >= Self.downloadMinBytes, parentPath(of: path) == downloadsPath(home) {
            return seed(path: path, category: .oldDownload, treeSize: size)
        }

        // 5. Simulator data — direct child of ~/Library/Developer/CoreSimulator/Devices,
        //    directory, >= 1 GB.
        if size >= Self.simulatorMinBytes, node.isDirectory,
           parentPath(of: path) == simulatorDevicesPath(home) {
            return seed(path: path, category: .simulatorData, treeSize: size)
        }

        // 6. Large file — regular file >= 1 GB not matched above.
        if size >= Self.largeFileMinBytes, !node.isDirectory {
            return seed(path: path, category: .largeFile, treeSize: size)
        }

        return nil
    }

    private func seed(path: String, category: CleanupCategory, treeSize: Int64) -> CandidateSeed {
        CandidateSeed(url: URL(fileURLWithPath: path), category: category, treeSize: treeSize)
    }

    // MARK: Path helpers

    private func standardizedPath(_ url: URL) -> String {
        (url.path as NSString).standardizingPath
    }

    private func parentPath(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private func cachesPath(_ home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Caches")
    }

    private func downloadsPath(_ home: String) -> String {
        (home as NSString).appendingPathComponent("Downloads")
    }

    private func simulatorDevicesPath(_ home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Developer/CoreSimulator/Devices")
    }

    private func derivedDataPath(_ home: String) -> String {
        (home as NSString).appendingPathComponent("Library/Developer/Xcode/DerivedData")
    }

    private func isUnderDownloads(_ path: String, home: String) -> Bool {
        let downloads = downloadsPath(home)
        return path == downloads || path.hasPrefix(downloads + "/")
    }

    private func isDerivedData(path: String, home: String, rootPath: String) -> Bool {
        let derived = derivedDataPath(home)
        if path == derived { return true }
        // When scanning inside DerivedData itself, emit its direct children.
        if rootPath == derived {
            return parentPath(of: path) == derived
        }
        return false
    }

    private func isInstaller(path: String) -> Bool {
        Self.installerExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}
