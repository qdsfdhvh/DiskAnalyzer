import Foundation

/// Runs immediately before each cleanup action to verify the item is still
/// the same filesystem object that was analyzed, is inside the analyzed root,
/// uses a supported action, and (for high-risk items) has explicit approval.
struct PreflightValidator: Sendable {

    let rootURL: URL
    let fingerprinter: FileFingerprinting

    init(rootURL: URL, fingerprinter: FileFingerprinting = LstatFileFingerprinter()) {
        self.rootURL = rootURL
        self.fingerprinter = fingerprinter
    }

    /// Removes items whose ancestor is also selected: selecting a parent
    /// subsumes its children, so children are never executed separately.
    func normalize(_ items: [ApprovedCleanupItem]) -> [ApprovedCleanupItem] {
        let paths = Set(items.map { Self.std($0.candidate.url.path) })
        return items.filter { item in
            let path = Self.std(item.candidate.url.path)
            let subsumed = paths.contains { candidate in
                candidate != path && path.hasPrefix(candidate + "/")
            }
            return !subsumed
        }
    }

    /// Verifies one item. Throws a `PreflightRejection` when the item cannot
    /// be safely executed.
    func validate(_ item: ApprovedCleanupItem) throws {
        let root = Self.std(rootURL.resolvingSymlinksInPath().path)

        // Containment must hold on the symlink-RESOLVED path, not just the
        // string form: an ancestor symlink inside the analyzed root could
        // otherwise point at an object outside it (same inode/device/size
        // would still match the fingerprint).
        let resolvedPath = Self.std(item.candidate.url.resolvingSymlinksInPath().path)
        guard resolvedPath.hasPrefix(root + "/") else {
            throw PreflightRejection.outsideRoot(displayPath: item.candidate.displayPath)
        }
        guard item.candidate.action == .moveToTrash else {
            throw PreflightRejection.unsupportedAction(item.candidate.action)
        }
        if item.candidate.risk == .high && !item.explicitlyApproved {
            throw PreflightRejection.highRiskRequiresApproval(displayPath: item.candidate.displayPath)
        }

        // lstat-based re-verification: identity and state must match the
        // fingerprint recorded during analysis.
        let current: FileFingerprint
        do {
            current = try fingerprinter.fingerprint(url: item.candidate.url)
        } catch FingerprintError.symlink {
            throw PreflightRejection.symlink(displayPath: item.candidate.displayPath)
        } catch {
            throw PreflightRejection.missingFile(displayPath: item.candidate.displayPath)
        }

        guard current.deviceID == item.candidate.fingerprint.deviceID,
              current.inode == item.candidate.fingerprint.inode else {
            throw PreflightRejection.changed(displayPath: item.candidate.displayPath)
        }
        if let recordedMtime = item.candidate.fingerprint.modificationTime {
            // A recorded date demands a matching current date; a missing
            // current date is itself a change.
            guard let currentMtime = current.modificationTime,
                  currentMtime == recordedMtime else {
                throw PreflightRejection.changed(displayPath: item.candidate.displayPath)
            }
        }
        if current.allocatedSize != item.candidate.fingerprint.allocatedSize {
            throw PreflightRejection.changed(displayPath: item.candidate.displayPath)
        }
    }

    private static func std(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
