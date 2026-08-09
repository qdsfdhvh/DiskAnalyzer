import Foundation

/// Creates a unique temporary directory for a test and removes it on cleanup.
///
/// All fixture operations are confined to the generated root; tests must never
/// touch paths outside this root.
final class TemporaryDirectoryFixture {

    enum FixtureError: Error {
        case creationFailed(URL)
    }

    let root: URL

    /// Absolute path of the fixture root, for use with `FileManager` path APIs.
    var rootPath: String { root.path }

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskAnalyzerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.root = dir
    }

    deinit {
        cleanup()
    }

    /// Creates a file at `relativePath` under the root, creating parents as
    /// needed. Optionally sets the modification date after writing.
    @discardableResult
    func createFile(_ relativePath: String, size: Int = 0, modifiedAt: Date? = nil) throws -> URL {
        let url = url(forRelativePath: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FixtureError.creationFailed(url)
        }
        if size > 0 {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(size))
        }
        if let modifiedAt {
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt],
                ofItemAtPath: url.path
            )
        }
        return url
    }

    /// Creates a directory at `relativePath` under the root, creating parents as needed.
    @discardableResult
    func createDirectory(_ relativePath: String) throws -> URL {
        let url = url(forRelativePath: relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Removes the entire fixture root. Safe to call multiple times.
    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Resolves a slash-separated relative path against the root without
    /// relying on `appendingPathComponent`'s handling of embedded slashes.
    private func url(forRelativePath relativePath: String) -> URL {
        relativePath.split(separator: "/").reduce(root) {
            $0.appendingPathComponent(String($1))
        }
    }
}
