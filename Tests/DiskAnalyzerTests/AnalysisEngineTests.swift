import XCTest
@testable import DiskAnalyzer

// MARK: - Local fake

private final class EngineFakeFingerprinter: FileFingerprinting, @unchecked Sendable {
    var resultByPath: [String: Result<FileFingerprint, Error>] = [:]

    func fingerprint(url: URL) throws -> FileFingerprint {
        guard let result = resultByPath[url.path] else {
            throw FingerprintError.statFailed(path: url.path)
        }
        return try result.get()
    }
}

// MARK: - Tests

final class AnalysisEngineTests: XCTestCase {

    private let MB = Int64(1024 * 1024)
    private let GB = Int64(1024 * 1024 * 1024)
    private let home = URL(fileURLWithPath: "/Users/alice")
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private var fake: EngineFakeFingerprinter!

    override func setUp() {
        super.setUp()
        fake = EngineFakeFingerprinter()
    }

    private func makeEngine() -> AnalysisEngine {
        let enricher = CandidateEnricher(
            fingerprinter: fake,
            now: { [unowned self] in self.fixedNow }
        )
        return AnalysisEngine(homeURL: home, enricher: enricher, now: { [unowned self] in self.fixedNow })
    }

    private func node(_ path: String, isDir: Bool, size: Int64, children: [FileNode] = []) -> FileNode {
        let url = URL(fileURLWithPath: path)
        return FileNode(url: url, name: url.lastPathComponent, isDirectory: isDir, size: size, children: children)
    }

    private func stub(_ path: String) {
        fake.resultByPath[path] = .success(FileFingerprint(
            deviceID: 1,
            inode: 7,
            allocatedSize: 1000,
            modificationTime: fixedNow.addingTimeInterval(-100 * 86_400)
        ))
    }

    private var defaultPreferences: AnalysisPreferences {
        AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7)
    }

    func testGeneratedAtUsesClock() async {
        let engine = makeEngine()
        let report = await engine.analyze(
            root: node("/Users/alice", isDir: true, size: 0),
            preferences: defaultPreferences
        )
        XCTAssertEqual(report.generatedAt, fixedNow)
    }

    func testEmptyReport() async {
        let engine = makeEngine()
        let report = await engine.analyze(
            root: node("/Users/alice", isDir: true, size: 0),
            preferences: defaultPreferences
        )
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertTrue(report.warnings.isEmpty)
        XCTAssertEqual(report.rootURL.path, "/Users/alice")
    }

    func testCandidateOrderingSpecificBeforeGeneric() async {
        stub("/Users/alice/Library/Developer/Xcode/DerivedData")
        stub("/Users/alice/Library/Caches/com.apple.Safari")
        stub("/Users/alice/Movies/three.mov")
        stub("/Users/alice/Movies/two.mov")
        stub("/Users/alice/Movies/one.mov")

        let derived = node("/Users/alice/Library/Developer/Xcode/DerivedData", isDir: true, size: 5 * GB)
        let xcode = node("/Users/alice/Library/Developer/Xcode", isDir: true, size: 5 * GB, children: [derived])
        let safari = node("/Users/alice/Library/Caches/com.apple.Safari", isDir: true, size: 600 * MB)
        let caches = node("/Users/alice/Library/Caches", isDir: true, size: 600 * MB, children: [safari])
        let library = node("/Users/alice/Library", isDir: true, size: 5600 * MB, children: [xcode, caches])
        let movies = node("/Users/alice/Movies", isDir: true, size: 6 * GB, children: [
            node("/Users/alice/Movies/three.mov", isDir: false, size: 3 * GB),
            node("/Users/alice/Movies/two.mov", isDir: false, size: 2 * GB),
            node("/Users/alice/Movies/one.mov", isDir: false, size: 1 * GB)
        ])
        let root = node("/Users/alice", isDir: true, size: 11600 * MB, children: [library, movies])

        let report = await makeEngine().analyze(root: root, preferences: defaultPreferences)

        XCTAssertEqual(report.candidates.map(\.category), [
            .developerCache, .applicationCache,
            .largeFile, .largeFile, .largeFile
        ])
        XCTAssertEqual(report.candidates.map(\.allocatedSize), [
            5 * GB, 600 * MB,
            3 * GB, 2 * GB, 1 * GB
        ])
    }

    func testLimitCapsAt200Candidates() async {
        var files: [FileNode] = []
        for i in 0..<250 {
            let path = String(format: "/Users/alice/Movies/f%03d.mov", i)
            stub(path)
            files.append(node(path, isDir: false, size: 1 * GB))
        }
        let movies = node("/Users/alice/Movies", isDir: true, size: 250 * GB, children: files)
        let root = node("/Users/alice", isDir: true, size: 250 * GB, children: [movies])

        let report = await makeEngine().analyze(root: root, preferences: defaultPreferences)

        XCTAssertEqual(report.candidates.count, 200)
        XCTAssertEqual(report.warnings, [.candidateLimitReached(omittedCount: 50)])
    }

    func testWarningCompositionCombinesMetadataAndLimit() async {
        var files: [FileNode] = []
        for i in 0..<210 {
            let path = String(format: "/Users/alice/Movies/f%03d.mov", i)
            if i % 2 == 0 {
                stub(path)
            } else {
                fake.resultByPath[path] = .failure(FingerprintError.statFailed(path: path))
            }
            files.append(node(path, isDir: false, size: 1 * GB))
        }
        let movies = node("/Users/alice/Movies", isDir: true, size: 210 * GB, children: files)
        let root = node("/Users/alice", isDir: true, size: 210 * GB, children: [movies])

        let report = await makeEngine().analyze(root: root, preferences: defaultPreferences)

        // Discovery caps at 200 seeds (10 omitted); of those, the even-index
        // stubs enrich and the odd-index ones fail with metadata warnings.
        XCTAssertEqual(report.candidates.count, 100)

        let limitWarnings = report.warnings.filter {
            if case .candidateLimitReached = $0 { return true }
            return false
        }
        XCTAssertEqual(limitWarnings.count, 1)
        XCTAssertEqual(limitWarnings, [.candidateLimitReached(omittedCount: 10)])

        let metadataWarnings = report.warnings.filter {
            if case .metadataUnavailable = $0 { return true }
            return false
        }
        XCTAssertEqual(metadataWarnings.count, 100)
    }

    func testPreserveRecentDaysDelegatedToEnricher() async {
        // An old installer that the user wants preserved must not surface as
        // an old installer (falls back to largeFile when >= 1 GB).
        let path = "/Users/alice/Downloads/preserved.dmg"
        fake.resultByPath[path] = .success(FileFingerprint(
            deviceID: 1,
            inode: 7,
            allocatedSize: 1000,
            modificationTime: fixedNow.addingTimeInterval(-60 * 86_400)
        ))
        let downloads = node("/Users/alice/Downloads", isDir: true, size: 2 * GB, children: [
            node(path, isDir: false, size: 2 * GB)
        ])
        let root = node("/Users/alice", isDir: true, size: 2 * GB, children: [downloads])

        let report = await makeEngine().analyze(
            root: root,
            preferences: AnalysisPreferences(targetBytes: nil, preserveRecentDays: 90)
        )

        XCTAssertEqual(report.candidates.count, 1)
        XCTAssertEqual(report.candidates[0].category, .largeFile)
    }
}
