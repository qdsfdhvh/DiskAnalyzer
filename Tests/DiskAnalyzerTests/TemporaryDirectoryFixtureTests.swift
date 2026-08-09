import XCTest
@testable import DiskAnalyzer

final class TemporaryDirectoryFixtureTests: XCTestCase {

    func testCreateFileWritesRequestedBytes() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let url = try fixture.createFile("data.bin", size: 4096)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attrs[.size] as? Int, 4096)
    }

    func testCreateFileCreatesNestedParents() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let url = try fixture.createFile("a/b/c/deep.txt", size: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCreateFileSetsModificationDate() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let url = try fixture.createFile("old.txt", modifiedAt: date)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let modification = attrs[.modificationDate] as? Date
        XCTAssertNotNil(modification)
        XCTAssertEqual(
            modification?.timeIntervalSince1970 ?? 0,
            date.timeIntervalSince1970,
            accuracy: 1.0
        )
    }

    func testCreateDirectoryMakesDirectory() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let url = try fixture.createDirectory("x/y/z")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testCleanupRemovesRoot() throws {
        let fixture = try TemporaryDirectoryFixture()
        try fixture.createFile("gone.txt", size: 1)

        let rootPath = fixture.rootPath
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootPath))

        fixture.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootPath))
    }

    func testRootIsInsideSystemTemporaryDirectory() throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let tempDir = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .path
        XCTAssertTrue(fixture.root.deletingLastPathComponent().path.hasPrefix(tempDir))
    }
}
