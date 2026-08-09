import XCTest
@testable import DiskAnalyzer

final class PreflightValidatorTests: XCTestCase {

    private func makeCandidate(
        url: URL,
        risk: RiskLevel = .low,
        action: CleanupAction = .moveToTrash,
        fingerprint: FileFingerprint
    ) -> CleanupCandidate {
        CleanupCandidate(
            id: CandidateID(rawValue: UUID()),
            url: url,
            displayPath: url.path,
            category: .largeFile,
            allocatedSize: fingerprint.allocatedSize,
            risk: risk,
            defaultSelected: false,
            action: action,
            fingerprint: fingerprint,
            evidence: []
        )
    }

    private func item(_ candidate: CleanupCandidate, approved: Bool = false) -> ApprovedCleanupItem {
        ApprovedCleanupItem(candidate: candidate, explicitlyApproved: approved)
    }

    // MARK: Success

    func testUnchangedFilePasses() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let url = try fixture.createFile("data.bin", size: 0)
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        let fp = try LstatFileFingerprinter().fingerprint(url: url)
        let candidate = makeCandidate(url: url, fingerprint: fp)

        let validator = PreflightValidator(rootURL: fixture.root)
        XCTAssertNoThrow(try validator.validate(item(candidate)))
    }

    func testHighRiskWithExplicitApprovalPasses() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let url = try fixture.createFile("data.bin", size: 0)
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        let fp = try LstatFileFingerprinter().fingerprint(url: url)
        let candidate = makeCandidate(url: url, risk: .high, fingerprint: fp)

        let validator = PreflightValidator(rootURL: fixture.root)
        XCTAssertNoThrow(try validator.validate(item(candidate, approved: true)))
    }

    // MARK: Changed state

    func testReplacedInodeRejected() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let url = try fixture.createFile("data.bin", size: 0)
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        let fp = try LstatFileFingerprinter().fingerprint(url: url)
        let candidate = makeCandidate(url: url, fingerprint: fp)

        // Replace the file entirely (new inode).
        try FileManager.default.removeItem(at: url)
        try Data(repeating: 0x5A, count: 4096).write(to: url)

        let validator = PreflightValidator(rootURL: fixture.root)
        XCTAssertThrowsError(try validator.validate(item(candidate))) { error in
            XCTAssertEqual(error as? PreflightRejection, .changed(displayPath: url.path))
        }
    }

    func testChangedSizeRejected() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let url = try fixture.createFile("data.bin", size: 0)
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        let fp = try LstatFileFingerprinter().fingerprint(url: url)
        let candidate = makeCandidate(url: url, fingerprint: fp)

        // Append more data — allocation size changes.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x5A, count: 4096))
        try handle.close()

        let validator = PreflightValidator(rootURL: fixture.root)
        XCTAssertThrowsError(try validator.validate(item(candidate))) { error in
            XCTAssertEqual(error as? PreflightRejection, .changed(displayPath: url.path))
        }
    }

    func testChangedModificationDateRejected() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let url = try fixture.createFile("data.bin", size: 0)
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        let fp = try LstatFileFingerprinter().fingerprint(url: url)
        let candidate = makeCandidate(url: url, fingerprint: fp)

        let later = Date(timeIntervalSinceNow: 3600)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)

        let validator = PreflightValidator(rootURL: fixture.root)
        XCTAssertThrowsError(try validator.validate(item(candidate))) { error in
            XCTAssertEqual(error as? PreflightRejection, .changed(displayPath: url.path))
        }
    }

    // MARK: Safety boundaries

    func testOutsideRootRejected() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        // Create a sibling directory NOT under the analyzed root.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("Outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let url = try fixture.createFile("data.bin", size: 10)
        let fp = try LstatFileFingerprinter().fingerprint(url: url)
        let candidate = makeCandidate(url: url, fingerprint: fp)

        let validator = PreflightValidator(rootURL: outside)
        XCTAssertThrowsError(try validator.validate(item(candidate))) { error in
            XCTAssertEqual(error as? PreflightRejection, .outsideRoot(displayPath: url.path))
        }
    }

    func testSymlinkRejected() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let target = try fixture.createFile("target.bin", size: 10)
        let link = fixture.root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let candidate = makeCandidate(
            url: link,
            fingerprint: FileFingerprint(deviceID: 1, inode: 1, allocatedSize: 10, modificationTime: nil)
        )

        let validator = PreflightValidator(rootURL: fixture.root)
        XCTAssertThrowsError(try validator.validate(item(candidate))) { error in
            XCTAssertEqual(error as? PreflightRejection, .symlink(displayPath: link.path))
        }
    }

    func testAncestorSymlinkEscapeRejected() throws {
        // An analyzed directory is moved outside the root and a symlink is
        // placed at its old location: the candidate path resolves outside the
        // root even though the string form still starts with the root.
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("Outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        // Real file inside the outside dir.
        let realFile = outside.appendingPathComponent("data.bin")
        try Data(repeating: 0x5A, count: 4096).write(to: realFile)

        // Symlink inside the analyzed root pointing at the outside dir.
        let linkDir = fixture.root.appendingPathComponent("subdir")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: outside)

        // The candidate URL goes THROUGH the symlink; lstat follows ancestor
        // symlinks, so the fingerprint matches the real outside file.
        let candidateURL = linkDir.appendingPathComponent("data.bin")
        let fp = try LstatFileFingerprinter().fingerprint(url: candidateURL)
        let candidate = makeCandidate(url: candidateURL, fingerprint: fp)

        let validator = PreflightValidator(rootURL: fixture.root)
        XCTAssertThrowsError(try validator.validate(item(candidate))) { error in
            XCTAssertEqual(error as? PreflightRejection, .outsideRoot(displayPath: candidateURL.path))
        }
    }

    func testMissingFileRejected() throws {
        let missing = URL(fileURLWithPath: "/tmp/DefinitelyMissing-\(UUID().uuidString).bin")
        let candidate = makeCandidate(
            url: missing,
            fingerprint: FileFingerprint(deviceID: 1, inode: 1, allocatedSize: 10, modificationTime: nil)
        )

        let validator = PreflightValidator(rootURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertThrowsError(try validator.validate(item(candidate))) { error in
            XCTAssertEqual(error as? PreflightRejection, .missingFile(displayPath: missing.path))
        }
    }

    func testHighRiskWithoutApprovalRejected() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let url = try fixture.createFile("data.bin", size: 0)
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        let fp = try LstatFileFingerprinter().fingerprint(url: url)
        let candidate = makeCandidate(url: url, risk: .high, fingerprint: fp)

        let validator = PreflightValidator(rootURL: fixture.root)
        XCTAssertThrowsError(try validator.validate(item(candidate))) { error in
            XCTAssertEqual(error as? PreflightRejection, .highRiskRequiresApproval(displayPath: url.path))
        }
    }

    // MARK: Parent/child normalization

    func testSelectedParentSubsumesSelectedChild() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let parentURL = try fixture.createDirectory("parent")
        let childURL = try fixture.createFile("parent/child.bin", size: 10)
        let grandchildURL = try fixture.createFile("parent/child/grand.txt", size: 10)

        func candidate(_ url: URL) -> CleanupCandidate {
            CleanupCandidate(
                id: CandidateID(rawValue: UUID()),
                url: url,
                displayPath: url.path,
                category: .largeFile,
                allocatedSize: 10,
                risk: .low,
                defaultSelected: false,
                action: .moveToTrash,
                fingerprint: FileFingerprint(deviceID: 1, inode: 1, allocatedSize: 10, modificationTime: nil),
                evidence: []
            )
        }

        let validator = PreflightValidator(rootURL: fixture.root)
        let normalized = validator.normalize([
            item(candidate(parentURL)),
            item(candidate(childURL)),
            item(candidate(grandchildURL))
        ])

        XCTAssertEqual(normalized.map { $0.candidate.url.path }, [parentURL.path])
    }

    func testUnrelatedItemsBothKept() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let aURL = try fixture.createFile("a.bin", size: 10)
        let bURL = try fixture.createFile("b.bin", size: 10)

        func candidate(_ url: URL) -> CleanupCandidate {
            CleanupCandidate(
                id: CandidateID(rawValue: UUID()),
                url: url,
                displayPath: url.path,
                category: .largeFile,
                allocatedSize: 10,
                risk: .low,
                defaultSelected: false,
                action: .moveToTrash,
                fingerprint: FileFingerprint(deviceID: 1, inode: 1, allocatedSize: 10, modificationTime: nil),
                evidence: []
            )
        }

        let validator = PreflightValidator(rootURL: fixture.root)
        let normalized = validator.normalize([
            item(candidate(aURL)),
            item(candidate(bURL))
        ])

        XCTAssertEqual(normalized.count, 2)
    }

    func testSiblingNotSubsumedByParentPath() throws {
        // A path that merely shares a prefix must not be treated as a child.
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let parentURL = try fixture.createDirectory("parent")
        let siblingURL = try fixture.createFile("parent2.bin", size: 10)

        func candidate(_ url: URL) -> CleanupCandidate {
            CleanupCandidate(
                id: CandidateID(rawValue: UUID()),
                url: url,
                displayPath: url.path,
                category: .largeFile,
                allocatedSize: 10,
                risk: .low,
                defaultSelected: false,
                action: .moveToTrash,
                fingerprint: FileFingerprint(deviceID: 1, inode: 1, allocatedSize: 10, modificationTime: nil),
                evidence: []
            )
        }

        let validator = PreflightValidator(rootURL: fixture.root)
        let normalized = validator.normalize([
            item(candidate(parentURL)),
            item(candidate(siblingURL))
        ])

        XCTAssertEqual(normalized.count, 2)
    }
}
