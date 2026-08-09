import Darwin
import Foundation

// MARK: - Fingerprinting seam

/// Returns a stable identity plus size/date snapshot for a URL. Must not
/// follow symlinks. Used both to enrich candidates and to verify an item is
/// unchanged immediately before cleanup.
protocol FileFingerprinting: Sendable {
    func fingerprint(url: URL) throws -> FileFingerprint
}

enum FingerprintError: Error, Equatable {
    case statFailed(path: String)
    case symlink(path: String)
}

// MARK: - Real implementation

/// `lstat(2)`-based fingerprinter. `lstat` deliberately does not follow
/// symlinks; symlinks are rejected with `FingerprintError.symlink`.
struct LstatFileFingerprinter: FileFingerprinting, Sendable {
    func fingerprint(url: URL) throws -> FileFingerprint {
        var st = Darwin.stat()
        let rc = url.path.withCString { lstat($0, &st) }
        guard rc == 0 else {
            throw FingerprintError.statFailed(path: url.path)
        }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            throw FingerprintError.symlink(path: url.path)
        }
        return FileFingerprint(
            deviceID: UInt64(st.st_dev),
            inode: UInt64(st.st_ino),
            allocatedSize: Int64(st.st_blocks) * 512,
            modificationTime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        )
    }
}
