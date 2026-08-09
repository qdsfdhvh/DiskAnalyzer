import XCTest
@testable import DiskAnalyzer

// MARK: - Fake trash mover

private final class FakeTrashMover: TrashMoving, @unchecked Sendable {
    var movedPaths: [String] = []
    var failures: [String: Error] = [:]
    /// When set, cancels the running task once this many moves have happened.
    var cancelAfterMoveCount: Int?
    private(set) var moveCount = 0

    func moveToTrash(url: URL) throws -> URL? {
        moveCount += 1
        if let cap = cancelAfterMoveCount, moveCount >= cap {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if let error = failures[url.path] {
            throw error
        }
        movedPaths.append(url.path)
        return url
    }
}

private struct FakeError: Error {}

// MARK: - Sendable snapshot box

private final class ProgressBox: @unchecked Sendable {
    var values: [CleanupProgress] = []
}

// MARK: - Tests

final class TrashCleanupExecutorTests: XCTestCase {

    private func approvedItem(url: URL) throws -> ApprovedCleanupItem {
        let fp = try LstatFileFingerprinter().fingerprint(url: url)
        let candidate = CleanupCandidate(
            id: CandidateID(rawValue: UUID()),
            url: url,
            displayPath: url.path,
            category: .largeFile,
            allocatedSize: fp.allocatedSize,
            risk: .low,
            defaultSelected: false,
            action: .moveToTrash,
            fingerprint: fp,
            evidence: []
        )
        return ApprovedCleanupItem(candidate: candidate, explicitlyApproved: false)
    }

    private func makeItems(fixture: TemporaryDirectoryFixture, names: [String]) throws -> [ApprovedCleanupItem] {
        try names.map { name in
            let url = try fixture.createFile(name, size: 0)
            try Data(repeating: 0x5A, count: 4096).write(to: url)
            return try approvedItem(url: url)
        }
    }

    private func makeExecutor(
        fixture: TemporaryDirectoryFixture,
        mover: FakeTrashMover
    ) -> TrashCleanupExecutor {
        TrashCleanupExecutor(rootURL: fixture.root, trashMover: mover)
    }

    func testAllSuccess() async throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }
        let items = try makeItems(fixture: fixture, names: ["a.bin", "b.bin", "c.bin"])
        let mover = FakeTrashMover()
        let executor = makeExecutor(fixture: fixture, mover: mover)

        let result = await executor.execute(items: items) { _ in }

        XCTAssertEqual(result.movedCount, 3)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(mover.movedPaths, items.map { $0.candidate.url.path })
        XCTAssertEqual(result.outcomes.count, 3)
    }

    func testPreflightSkipThenContinue() async throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }
        let items = try makeItems(fixture: fixture, names: ["a.bin", "b.bin", "c.bin"])

        // Mutate item 2 after fingerprinting: it must fail preflight and be
        // skipped while the others proceed.
        let bURL = items[1].candidate.url
        try FileManager.default.removeItem(at: bURL)
        try Data(repeating: 0x5A, count: 4096).write(to: bURL)

        let mover = FakeTrashMover()
        let executor = makeExecutor(fixture: fixture, mover: mover)

        let result = await executor.execute(items: items) { _ in }

        XCTAssertEqual(result.outcomes.count, 3)
        guard case .movedToTrash = result.outcomes[0] else {
            return XCTFail("expected moved")
        }
        guard case let .skipped(_, reason) = result.outcomes[1], case .rejected = reason else {
            return XCTFail("expected preflight skip")
        }
        guard case .movedToTrash = result.outcomes[2] else {
            return XCTFail("expected moved")
        }
        XCTAssertEqual(mover.movedPaths, [
            items[0].candidate.url.path,
            items[2].candidate.url.path
        ])
    }

    func testMoveFailureThenContinue() async throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }
        let items = try makeItems(fixture: fixture, names: ["a.bin", "b.bin", "c.bin"])
        let mover = FakeTrashMover()
        mover.failures[items[1].candidate.url.path] = FakeError()

        let executor = makeExecutor(fixture: fixture, mover: mover)
        let result = await executor.execute(items: items) { _ in }

        XCTAssertEqual(result.failedCount, 1)
        guard case .failed = result.outcomes[1] else {
            return XCTFail("expected failure at index 1")
        }
        XCTAssertEqual(mover.movedPaths, [
            items[0].candidate.url.path,
            items[2].candidate.url.path
        ])
    }

    func testCancellationStopsNewMoves() async throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }
        let items = try makeItems(fixture: fixture, names: ["a.bin", "b.bin", "c.bin", "d.bin", "e.bin"])
        let mover = FakeTrashMover()
        mover.cancelAfterMoveCount = 2
        let executor = makeExecutor(fixture: fixture, mover: mover)

        let result = await executor.execute(items: items) { _ in }

        XCTAssertEqual(mover.movedPaths.count, 2)
        XCTAssertEqual(result.movedCount, 2)
        XCTAssertEqual(result.skippedCount, 3)
        XCTAssertTrue(result.outcomes.suffix(3).allSatisfy {
            if case let .skipped(_, reason) = $0, reason == .cancelled { return true }
            return false
        })
    }

    func testProgressIsMonotonicAndComplete() async throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }
        let items = try makeItems(fixture: fixture, names: ["a.bin", "b.bin", "c.bin"])
        let mover = FakeTrashMover()
        let executor = makeExecutor(fixture: fixture, mover: mover)

        let snapshots = ProgressBox()
        let result = await executor.execute(items: items) { snapshots.values.append($0) }

        XCTAssertEqual(snapshots.values.last?.completedItems, items.count)
        XCTAssertEqual(snapshots.values.last?.totalItems, items.count)
        let completed = snapshots.values.map(\.completedItems)
        XCTAssertEqual(completed, completed.sorted())
        XCTAssertEqual(result.outcomes.count, 3)
    }

    func testOutputOrderMatchesInputOrder() async throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }
        let items = try makeItems(fixture: fixture, names: ["a.bin", "b.bin", "c.bin"])
        let mover = FakeTrashMover()
        let executor = makeExecutor(fixture: fixture, mover: mover)

        let result = await executor.execute(items: items) { _ in }

        let moved = result.outcomes.map { outcome -> String? in
            if case let .movedToTrash(originalURL, _) = outcome { return originalURL.path }
            return nil
        }
        XCTAssertEqual(moved, items.map { $0.candidate.url.path })
    }

    func testParentSelectionSubsumesChild() async throws {
        let fixture = try TemporaryDirectoryFixture()
        defer { fixture.cleanup() }

        let parentURL = try fixture.createDirectory("parent")
        let childURL = try fixture.createFile("parent/child.bin", size: 0)
        try Data(repeating: 0x5A, count: 4096).write(to: childURL)

        let parentItem = try approvedItem(url: parentURL)
        let childItem = try approvedItem(url: childURL)
        let mover = FakeTrashMover()
        let executor = makeExecutor(fixture: fixture, mover: mover)

        let result = await executor.execute(items: [parentItem, childItem]) { _ in }

        // Child is normalized away; only the parent executes.
        XCTAssertEqual(result.outcomes.count, 1)
        XCTAssertEqual(mover.movedPaths, [parentURL.path])
    }
}
