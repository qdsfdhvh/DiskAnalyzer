import XCTest
@testable import DiskAnalyzer

final class CandidateSeedDiscoveryTests: XCTestCase {

    private let MB = Int64(1024 * 1024)
    private let GB = Int64(1024 * 1024 * 1024)
    private let home = URL(fileURLWithPath: "/Users/alice")

    // MARK: Fixture builder

    private func node(_ path: String, isDir: Bool, size: Int64, children: [FileNode] = []) -> FileNode {
        let url = URL(fileURLWithPath: path)
        return FileNode(url: url, name: url.lastPathComponent, isDirectory: isDir, size: size, children: children)
    }

    private func discover(_ root: FileNode, limit: Int = 200) -> SeedDiscoveryResult {
        CandidateSeedDiscovery().discover(root: root, homeURL: home, limit: limit)
    }

    // MARK: DerivedData

    func testDiscoversDerivedDataDirectory() {
        let derived = node("/Users/alice/Library/Developer/Xcode/DerivedData", isDir: true, size: 40 * GB, children: [
            node("/Users/alice/Library/Developer/Xcode/DerivedData/ProjectA", isDir: true, size: 30 * GB),
            node("/Users/alice/Library/Developer/Xcode/DerivedData/ProjectB", isDir: true, size: 10 * GB)
        ])
        let xcode = node("/Users/alice/Library/Developer/Xcode", isDir: true, size: 40 * GB, children: [derived])
        let library = node("/Users/alice/Library", isDir: true, size: 40 * GB, children: [xcode])
        let root = node("/Users/alice", isDir: true, size: 40 * GB, children: [library])

        let result = discover(root)

        XCTAssertEqual(result.seeds.count, 1)
        XCTAssertEqual(result.seeds[0].category, .developerCache)
        XCTAssertEqual(result.seeds[0].treeSize, 40 * GB)
        XCTAssertEqual(result.omittedCount, 0)
    }

    func testDerivedDataDirectChildrenWhenScanningInside() {
        let root = node("/Users/alice/Library/Developer/Xcode/DerivedData", isDir: true, size: 40 * GB, children: [
            node("/Users/alice/Library/Developer/Xcode/DerivedData/ProjectA", isDir: true, size: 30 * GB),
            node("/Users/alice/Library/Developer/Xcode/DerivedData/ProjectB", isDir: true, size: 10 * GB)
        ])

        let result = discover(root)

        XCTAssertEqual(result.seeds.count, 2)
        XCTAssertTrue(result.seeds.allSatisfy { $0.category == .developerCache })
        XCTAssertEqual(result.seeds.map(\.treeSize).sorted(), [10 * GB, 30 * GB])
    }

    func testDerivedDataChildrenNotEmittedWhenScanningHome() {
        let project = node("/Users/alice/Library/Developer/Xcode/DerivedData/ProjectA", isDir: true, size: 30 * GB)
        let derived = node("/Users/alice/Library/Developer/Xcode/DerivedData", isDir: true, size: 30 * GB, children: [project])
        let xcode = node("/Users/alice/Library/Developer/Xcode", isDir: true, size: 30 * GB, children: [derived])
        let library = node("/Users/alice/Library", isDir: true, size: 30 * GB, children: [xcode])
        let root = node("/Users/alice", isDir: true, size: 30 * GB, children: [library])

        let result = discover(root)

        XCTAssertEqual(result.seeds.count, 1)
        XCTAssertEqual(result.seeds[0].url.path, "/Users/alice/Library/Developer/Xcode/DerivedData")
    }

    // MARK: App cache

    func testAppCacheMatchesDirectChildrenOnly() {
        let safari = node("/Users/alice/Library/Caches/com.apple.Safari", isDir: true, size: 600 * MB)
        let nested = node("/Users/alice/Library/Caches/com.apple.Safari/nested", isDir: true, size: 500 * MB)
        let caches = node("/Users/alice/Library/Caches", isDir: true, size: 1100 * MB, children: [safari, nested])
        let library = node("/Users/alice/Library", isDir: true, size: 1100 * MB, children: [caches])
        let root = node("/Users/alice", isDir: true, size: 1100 * MB, children: [library])

        let result = discover(root)

        XCTAssertEqual(result.seeds.count, 1)
        XCTAssertEqual(result.seeds[0].category, .applicationCache)
        XCTAssertEqual(result.seeds[0].url.path, "/Users/alice/Library/Caches/com.apple.Safari")
    }

    // MARK: Installers and downloads

    func testOldInstallerMatchesAnyDepthInDownloads() {
        let installers = node("/Users/alice/Downloads/installers", isDir: true, size: 300 * MB, children: [
            node("/Users/alice/Downloads/installers/old.dmg", isDir: false, size: 300 * MB)
        ])
        let downloads = node("/Users/alice/Downloads", isDir: true, size: 2420 * MB, children: [
            node("/Users/alice/Downloads/Xcode_15.2.dmg", isDir: false, size: 2 * GB),
            node("/Users/alice/Downloads/archive.zip", isDir: false, size: 120 * MB),
            installers
        ])
        let root = node("/Users/alice", isDir: true, size: 2420 * MB, children: [downloads])

        let result = discover(root)

        XCTAssertEqual(result.seeds.count, 3)
        XCTAssertTrue(result.seeds.allSatisfy { $0.category == .oldInstaller })
    }

    func testInstallerOutsideDownloadsIsNotInstaller() {
        let downloads = node("/Users/alice/Downloads", isDir: true, size: 0, children: [])
        let movies = node("/Users/alice/Movies", isDir: true, size: 2 * GB, children: [
            node("/Users/alice/Movies/big.dmg", isDir: false, size: 2 * GB)
        ])
        let root = node("/Users/alice", isDir: true, size: 2 * GB, children: [downloads, movies])

        let result = discover(root)

        // Not an installer; still a large regular file.
        XCTAssertEqual(result.seeds.count, 1)
        XCTAssertEqual(result.seeds[0].category, .largeFile)
    }

    func testOldDownloadMatchesDirectChildrenOnly() {
        let downloads = node("/Users/alice/Downloads", isDir: true, size: 1301 * MB, children: [
            node("/Users/alice/Downloads/report.csv", isDir: false, size: 700 * MB),
            node("/Users/alice/Downloads/subfolder", isDir: true, size: 1 * MB, children: [
                node("/Users/alice/Downloads/subfolder/file.bin", isDir: false, size: 600 * MB)
            ])
        ])
        let root = node("/Users/alice", isDir: true, size: 1301 * MB, children: [downloads])

        let result = discover(root)

        XCTAssertEqual(result.seeds.count, 1)
        XCTAssertEqual(result.seeds[0].category, .oldDownload)
        XCTAssertEqual(result.seeds[0].url.path, "/Users/alice/Downloads/report.csv")
    }

    // MARK: Simulator data

    func testSimulatorDataMatchesDeviceDirectories() {
        let device = node("/Users/alice/Library/Developer/CoreSimulator/Devices/ABC-123", isDir: true, size: 1500 * MB, children: [
            node("/Users/alice/Library/Developer/CoreSimulator/Devices/ABC-123/data", isDir: true, size: 1500 * MB)
        ])
        let devices = node("/Users/alice/Library/Developer/CoreSimulator/Devices", isDir: true, size: 1500 * MB, children: [device])
        let developer = node("/Users/alice/Library/Developer", isDir: true, size: 1500 * MB, children: [devices])
        let library = node("/Users/alice/Library", isDir: true, size: 1500 * MB, children: [developer])
        let root = node("/Users/alice", isDir: true, size: 1500 * MB, children: [library])

        let result = discover(root)

        XCTAssertEqual(result.seeds.count, 1)
        XCTAssertEqual(result.seeds[0].category, .simulatorData)
        XCTAssertEqual(result.seeds[0].url.path, "/Users/alice/Library/Developer/CoreSimulator/Devices/ABC-123")
    }

    // MARK: Large files

    func testLargeFileMatchesRegularFilesOnly() {
        let root = node("/Users/alice", isDir: true, size: 3 * GB, children: [
            node("/Users/alice/Documents", isDir: true, size: 5 * GB, children: [
                node("/Users/alice/Documents/BigProject", isDir: true, size: 5 * GB)
            ]),
            node("/Users/alice/Movies", isDir: true, size: 3 * GB, children: [
                node("/Users/alice/Movies/big.mov", isDir: false, size: 3 * GB),
                node("/Users/alice/Movies/small.mov", isDir: false, size: 500 * MB)
            ])
        ])

        let result = discover(root)

        XCTAssertEqual(result.seeds.count, 1)
        XCTAssertEqual(result.seeds[0].category, .largeFile)
        XCTAssertEqual(result.seeds[0].url.path, "/Users/alice/Movies/big.mov")
    }

    // MARK: Rule precedence

    func testSpecificRuleBeatsLargeFile() {
        let downloads = node("/Users/alice/Downloads", isDir: true, size: 1500 * MB, children: [
            node("/Users/alice/Downloads/big.dmg", isDir: false, size: 1500 * MB)
        ])
        let caches = node("/Users/alice/Library/Caches", isDir: true, size: 600 * MB, children: [
            node("/Users/alice/Library/Caches/com.example.cache", isDir: false, size: 600 * MB)
        ])
        let library = node("/Users/alice/Library", isDir: true, size: 600 * MB, children: [caches])
        let root = node("/Users/alice", isDir: true, size: 2100 * MB, children: [downloads, library])

        let result = discover(root)

        let categories = result.seeds.map(\.category)
        XCTAssertEqual(categories, [.oldInstaller, .applicationCache])
    }

    // MARK: Threshold edges

    func testThresholdEdges() {
        // App cache: exactly 250 MB matches; 249 MB does not.
        let caches = node("/Users/alice/Library/Caches", isDir: true, size: 500 * MB, children: [
            node("/Users/alice/Library/Caches/exact.bin", isDir: false, size: 250 * MB),
            node("/Users/alice/Library/Caches/short.bin", isDir: false, size: 250 * MB - 1)
        ])
        let library = node("/Users/alice/Library", isDir: true, size: 500 * MB, children: [caches])

        let cacheResult = discover(node("/Users/alice", isDir: true, size: 500 * MB, children: [library]))
        XCTAssertEqual(cacheResult.seeds.map(\.url.path), ["/Users/alice/Library/Caches/exact.bin"])

        // Large file: exactly 1 GB matches; 1 GB - 1 does not.
        let movies = node("/Users/alice/Movies", isDir: true, size: 2 * GB, children: [
            node("/Users/alice/Movies/exact.mov", isDir: false, size: 1 * GB),
            node("/Users/alice/Movies/short.mov", isDir: false, size: 1 * GB - 1)
        ])
        let root2 = node("/Users/alice", isDir: true, size: 2 * GB, children: [movies])

        let largeResult = discover(root2)
        XCTAssertEqual(largeResult.seeds.map(\.url.path), ["/Users/alice/Movies/exact.mov"])

        // Installer: exactly 100 MB matches; 100 MB - 1 does not.
        let downloads = node("/Users/alice/Downloads", isDir: true, size: 200 * MB, children: [
            node("/Users/alice/Downloads/exact.pkg", isDir: false, size: 100 * MB),
            node("/Users/alice/Downloads/short.pkg", isDir: false, size: 100 * MB - 1)
        ])
        let root3 = node("/Users/alice", isDir: true, size: 200 * MB, children: [downloads])

        let installerResult = discover(root3)
        XCTAssertEqual(installerResult.seeds.map(\.url.path), ["/Users/alice/Downloads/exact.pkg"])
    }

    // MARK: Dedupe and normalization

    func testURLDedupeAcrossDistinctNodes() {
        let downloads = node("/Users/alice/Downloads", isDir: true, size: 2 * GB, children: [
            node("/Users/alice/Downloads/dup.dmg", isDir: false, size: 1 * GB),
            node("/Users/alice/Downloads/dup.dmg", isDir: false, size: 1 * GB)
        ])
        let root = node("/Users/alice", isDir: true, size: 2 * GB, children: [downloads])

        let result = discover(root)

        XCTAssertEqual(result.seeds.count, 1)
    }

    func testSeedsUseStandardizedPaths() {
        let downloads = node("/Users/alice/Downloads", isDir: true, size: 2 * GB, children: [
            node("/Users/alice/Downloads/../Downloads/big.dmg", isDir: false, size: 2 * GB)
        ])
        let root = node("/Users/alice", isDir: true, size: 2 * GB, children: [downloads])

        let result = discover(root)

        XCTAssertEqual(result.seeds.count, 1)
        XCTAssertEqual(result.seeds[0].url.path, "/Users/alice/Downloads/big.dmg")
        XCTAssertEqual(result.seeds[0].category, .oldInstaller)
    }

    // MARK: Limit and ordering

    func testLimitCapsSeedsAndReportsOmitted() {
        var files: [FileNode] = []
        for i in 0..<250 {
            files.append(node(String(format: "/Users/alice/Movies/f%03d.mov", i), isDir: false, size: 1 * GB))
        }
        let movies = node("/Users/alice/Movies", isDir: true, size: 250 * GB, children: files)
        let root = node("/Users/alice", isDir: true, size: 250 * GB, children: [movies])

        let result = discover(root, limit: 200)

        XCTAssertEqual(result.seeds.count, 200)
        XCTAssertEqual(result.omittedCount, 50)
    }

    func testSpecificBeforeGenericOrdering() {
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

        let result = discover(root)

        XCTAssertEqual(result.seeds.map(\.category), [
            .developerCache, .applicationCache,
            .largeFile, .largeFile, .largeFile
        ])
        XCTAssertEqual(result.seeds.map(\.treeSize), [
            5 * GB, 600 * MB,
            3 * GB, 2 * GB, 1 * GB
        ])
    }

    // MARK: Edge cases

    func testEmptyRootYieldsNoSeeds() {
        let root = node("/Users/alice", isDir: true, size: 0)
        let result = discover(root)
        XCTAssertTrue(result.seeds.isEmpty)
        XCTAssertEqual(result.omittedCount, 0)
    }

    func testDiscoveryDoesNotRequireFilesToExistOnDisk() {
        // All fixture paths are synthetic; discovery must not touch the
        // filesystem, so this must succeed with no stat calls involved.
        let downloads = node("/Users/alice/Downloads", isDir: true, size: 1500 * MB, children: [
            node("/Users/alice/Downloads/nonexistent.pkg", isDir: false, size: 1500 * MB)
        ])
        let root = node("/Users/alice", isDir: true, size: 1500 * MB, children: [downloads])

        let result = discover(root)

        XCTAssertEqual(result.seeds.count, 1)
        XCTAssertEqual(result.seeds[0].category, .oldInstaller)
    }
}
