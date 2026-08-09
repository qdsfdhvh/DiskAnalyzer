import XCTest
@testable import DiskAnalyzer

// MARK: - Fake fingerprinter

private final class FakeFingerprinter: FileFingerprinting, @unchecked Sendable {
    var resultByPath: [String: Result<FileFingerprint, Error>] = [:]
    var callCount = 0

    func fingerprint(url: URL) throws -> FileFingerprint {
        callCount += 1
        guard let result = resultByPath[url.path] else {
            throw FingerprintError.statFailed(path: url.path)
        }
        return try result.get()
    }
}

// MARK: - Enricher tests

final class CandidateEnricherTests: XCTestCase {

    private let MB = Int64(1024 * 1024)
    private let GB = Int64(1024 * 1024 * 1024)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var fake: FakeFingerprinter!
    private var enricher: CandidateEnricher!

    override func setUp() {
        super.setUp()
        fake = FakeFingerprinter()
        enricher = CandidateEnricher(fingerprinter: fake, now: { [unowned self] in self.now })
    }

    private func seed(_ path: String, category: CleanupCategory, treeSize: Int64) -> CandidateSeed {
        CandidateSeed(url: URL(fileURLWithPath: path), category: category, treeSize: treeSize)
    }

    private func fp(ageDays: Int? = nil) -> FileFingerprint {
        let mtime = ageDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        return FileFingerprint(deviceID: 1, inode: 7, allocatedSize: 1000, modificationTime: mtime)
    }

    private func stub(_ path: String, _ result: Result<FileFingerprint, Error>) {
        fake.resultByPath[path] = result
    }

    // MARK: Profiles

    func testDeveloperCacheProfile() {
        let path = "/Users/alice/Library/Developer/Xcode/DerivedData"
        stub(path, .success(fp()))
        let result = enricher.enrich(
            seeds: [seed(path, category: .developerCache, treeSize: 40 * GB)],
            preserveRecentDays: 7
        )

        XCTAssertEqual(result.candidates.count, 1)
        let c = result.candidates[0]
        XCTAssertEqual(c.category, .developerCache)
        XCTAssertEqual(c.risk, .low)
        XCTAssertEqual(c.defaultSelected, true)
        XCTAssertEqual(c.action, .moveToTrash)
        XCTAssertEqual(c.allocatedSize, 40 * GB)
        XCTAssertEqual(c.evidence.first?.kind, .knownRebuildablePath)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testApplicationCacheProfile() {
        let path = "/Users/alice/Library/Caches/com.apple.Safari"
        stub(path, .success(fp()))
        let result = enricher.enrich(
            seeds: [seed(path, category: .applicationCache, treeSize: 600 * MB)],
            preserveRecentDays: 7
        )

        XCTAssertEqual(result.candidates[0].risk, .medium)
        XCTAssertEqual(result.candidates[0].defaultSelected, false)
    }

    func testOldDownloadProfile() {
        let path = "/Users/alice/Downloads/report.csv"
        stub(path, .success(fp(ageDays: 100)))
        let result = enricher.enrich(
            seeds: [seed(path, category: .oldDownload, treeSize: 700 * MB)],
            preserveRecentDays: 7
        )

        XCTAssertEqual(result.candidates[0].category, .oldDownload)
        XCTAssertEqual(result.candidates[0].risk, .medium)
        XCTAssertEqual(result.candidates[0].defaultSelected, false)
    }

    func testSimulatorDataProfile() {
        let path = "/Users/alice/Library/Developer/CoreSimulator/Devices/ABC-123"
        stub(path, .success(fp()))
        let result = enricher.enrich(
            seeds: [seed(path, category: .simulatorData, treeSize: 1500 * MB)],
            preserveRecentDays: 7
        )

        XCTAssertEqual(result.candidates[0].risk, .medium)
        XCTAssertEqual(result.candidates[0].defaultSelected, false)
    }

    func testLargeFileProfile() {
        let path = "/Users/alice/Movies/big.mov"
        stub(path, .success(fp()))
        let result = enricher.enrich(
            seeds: [seed(path, category: .largeFile, treeSize: 3 * GB)],
            preserveRecentDays: 7
        )

        XCTAssertEqual(result.candidates[0].risk, .high)
        XCTAssertEqual(result.candidates[0].defaultSelected, false)
    }

    // MARK: Age predicates

    func testOldInstallerRequires30Days() {
        let path = "/Users/alice/Downloads/Xcode_15.2.dmg"
        stub(path, .success(fp(ageDays: 60)))
        let result = enricher.enrich(
            seeds: [seed(path, category: .oldInstaller, treeSize: 2 * GB)],
            preserveRecentDays: 7
        )

        XCTAssertEqual(result.candidates[0].category, .oldInstaller)
        XCTAssertEqual(result.candidates[0].risk, .low)
        XCTAssertEqual(result.candidates[0].defaultSelected, true)
        XCTAssertTrue(result.candidates[0].evidence.contains { $0.kind == .ageInDays })
    }

    func testRecentInstallerIsNotOld() {
        // 5 days old — fails the 30-day predicate. As a 2 GB file it falls
        // through to largeFile (high risk, not selected).
        let path = "/Users/alice/Downloads/recent.dmg"
        stub(path, .success(fp(ageDays: 5)))
        let result = enricher.enrich(
            seeds: [seed(path, category: .oldInstaller, treeSize: 2 * GB)],
            preserveRecentDays: 7
        )

        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.candidates[0].category, .largeFile)
        XCTAssertEqual(result.candidates[0].risk, .high)
        XCTAssertEqual(result.candidates[0].defaultSelected, false)
    }

    func testRecentSmallInstallerIsDropped() {
        // 500 MB recent installer — fails age and is below the 1 GB
        // large-file threshold, so it disappears entirely.
        let path = "/Users/alice/Downloads/recent-small.pkg"
        stub(path, .success(fp(ageDays: 5)))
        let result = enricher.enrich(
            seeds: [seed(path, category: .oldInstaller, treeSize: 500 * MB)],
            preserveRecentDays: 7
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testOldDownloadRequires90Days() {
        let path = "/Users/alice/Downloads/report.csv"
        stub(path, .success(fp(ageDays: 89)))
        let result = enricher.enrich(
            seeds: [seed(path, category: .oldDownload, treeSize: 700 * MB)],
            preserveRecentDays: 7
        )

        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testPreserveRecentDaysExcludesAgeBasedCategory() {
        // 60 days old, but the user wants 90 recent days preserved.
        let path = "/Users/alice/Downloads/old-but-preserved.dmg"
        stub(path, .success(fp(ageDays: 60)))
        let result = enricher.enrich(
            seeds: [seed(path, category: .oldInstaller, treeSize: 2 * GB)],
            preserveRecentDays: 90
        )

        XCTAssertEqual(result.candidates[0].category, .largeFile)
    }

    func testNilModificationDateFailsAgePredicate() {
        let path = "/Users/alice/Downloads/nomtime.dmg"
        stub(path, .success(fp(ageDays: nil)))
        let result = enricher.enrich(
            seeds: [seed(path, category: .oldInstaller, treeSize: 2 * GB)],
            preserveRecentDays: 7
        )

        XCTAssertEqual(result.candidates[0].category, .largeFile)
    }

    // MARK: Failures

    func testMetadataFailureEmitsWarning() {
        let path = "/Users/alice/Movies/missing.mov"
        stub(path, .failure(FingerprintError.statFailed(path: path)))
        let result = enricher.enrich(
            seeds: [seed(path, category: .largeFile, treeSize: 3 * GB)],
            preserveRecentDays: 7
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.warnings, [.metadataUnavailable(displayPath: path)])
    }

    func testSymlinkSeedOmittedSilently() {
        let path = "/Users/alice/Movies/link.mov"
        stub(path, .failure(FingerprintError.symlink(path: path)))
        let result = enricher.enrich(
            seeds: [seed(path, category: .largeFile, treeSize: 3 * GB)],
            preserveRecentDays: 7
        )

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testFingerprintCallsBoundedBySeedCount() {
        for i in 0..<5 {
            stub("/Users/alice/Movies/f\(i).mov", .success(fp()))
        }
        let seeds = (0..<5).map {
            seed("/Users/alice/Movies/f\($0).mov", category: .largeFile, treeSize: 2 * GB)
        }

        _ = enricher.enrich(seeds: seeds, preserveRecentDays: 7)

        XCTAssertEqual(fake.callCount, 5)
    }

    func testCandidateIDsAreUnique() {
        stub("/Users/alice/Movies/a.mov", .success(fp()))
        stub("/Users/alice/Movies/b.mov", .success(fp()))
        let seeds = [
            seed("/Users/alice/Movies/a.mov", category: .largeFile, treeSize: 2 * GB),
            seed("/Users/alice/Movies/b.mov", category: .largeFile, treeSize: 2 * GB)
        ]

        let result = enricher.enrich(seeds: seeds, preserveRecentDays: 7)

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertNotEqual(result.candidates[0].id, result.candidates[1].id)
    }

    func testEnrichmentPreservesSeedOrder() {
        stub("/Users/alice/Movies/a.mov", .success(fp()))
        stub("/Users/alice/Movies/b.mov", .success(fp()))
        let seeds = [
            seed("/Users/alice/Movies/a.mov", category: .largeFile, treeSize: 2 * GB),
            seed("/Users/alice/Movies/b.mov", category: .largeFile, treeSize: 2 * GB)
        ]

        let result = enricher.enrich(seeds: seeds, preserveRecentDays: 7)

        XCTAssertEqual(result.candidates.map(\.url.path), [
            "/Users/alice/Movies/a.mov",
            "/Users/alice/Movies/b.mov"
        ])
    }
}

// MARK: - Real fingerprinter tests

final class LstatFileFingerprinterTests: XCTestCase {

    func testFingerprintMatchesWrittenFile() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try fixture.createFile("data.bin", size: 0)
        try Data(repeating: 0x5A, count: 4096).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )

        let fp = try LstatFileFingerprinter().fingerprint(url: url)

        XCTAssertNotEqual(fp.deviceID, 0)
        XCTAssertNotEqual(fp.inode, 0)
        XCTAssertEqual(fp.allocatedSize, 4096)
        XCTAssertEqual(
            fp.modificationTime?.timeIntervalSince1970 ?? 0,
            date.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func testSymlinkThrows() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let target = try fixture.createFile("target.bin", size: 10)
        let link = fixture.root.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try LstatFileFingerprinter().fingerprint(url: link)) { error in
            XCTAssertEqual(error as? FingerprintError, .symlink(path: link.path))
        }
    }

    func testMissingFileThrowsStatFailed() {
        let url = URL(fileURLWithPath: "/nonexistent/DiskAnalyzerTests/missing.bin")
        XCTAssertThrowsError(try LstatFileFingerprinter().fingerprint(url: url)) { error in
            XCTAssertEqual(error as? FingerprintError, .statFailed(path: url.path))
        }
    }
}
