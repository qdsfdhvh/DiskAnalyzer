import XCTest
@testable import DiskAnalyzer

final class LocalCleanupPlannerTests: XCTestCase {

    private let MB = Int64(1024 * 1024)
    private let GB = Int64(1024 * 1024 * 1024)

    private func candidate(
        name: String,
        risk: RiskLevel,
        size: Int64,
        defaultSelected: Bool = false
    ) -> CleanupCandidate {
        CleanupCandidate(
            id: CandidateID(rawValue: UUID()),
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            displayPath: name,
            category: .largeFile,
            allocatedSize: size,
            risk: risk,
            defaultSelected: defaultSelected,
            action: .moveToTrash,
            fingerprint: FileFingerprint(deviceID: 1, inode: 1, allocatedSize: size, modificationTime: nil),
            evidence: []
        )
    }

    private func report(_ candidates: [CleanupCandidate]) -> AnalysisReport {
        AnalysisReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            rootURL: URL(fileURLWithPath: "/tmp"),
            candidates: candidates,
            warnings: []
        )
    }

    private func plan(_ candidates: [CleanupCandidate], target: Int64?) async throws -> CleanupPlanDraft {
        let request = PlanningRequest(report: report(candidates), targetBytes: target)
        return try await LocalCleanupPlanner().makeDraft(request: request)
    }

    // MARK: Grouping

    func testGroupsLowMediumHighInOrder() async throws {
        let low = candidate(name: "a", risk: .low, size: 1 * GB, defaultSelected: true)
        let medium = candidate(name: "b", risk: .medium, size: 1 * GB)
        let high = candidate(name: "c", risk: .high, size: 1 * GB)

        let draft = try await plan([high, low, medium], target: nil)

        XCTAssertEqual(draft.groups.map(\.title), [
            "Safe to reclaim",
            "Review recommended",
            "Large items — manual judgment"
        ])
        XCTAssertEqual(draft.groups[0].candidateIDs, [low.id])
        XCTAssertEqual(draft.groups[1].candidateIDs, [medium.id])
        XCTAssertEqual(draft.groups[2].candidateIDs, [high.id])
    }

    func testEmptyGroupsAreOmitted() async throws {
        let draft = try await plan([candidate(name: "a", risk: .low, size: 1 * GB)], target: nil)
        XCTAssertEqual(draft.groups.count, 1)
        XCTAssertEqual(draft.groups[0].title, "Safe to reclaim")
    }

    // MARK: Sorting

    func testSortBySizeDescendingWithinGroup() async throws {
        let small = candidate(name: "small", risk: .low, size: 1 * GB)
        let big = candidate(name: "big", risk: .low, size: 5 * GB)
        let mid = candidate(name: "mid", risk: .low, size: 2 * GB)

        let draft = try await plan([small, mid, big], target: nil)

        XCTAssertEqual(draft.groups[0].candidateIDs, [big.id, mid.id, small.id])
    }

    // MARK: Target behavior

    func testTargetStopsSelectingWhenReached() async throws {
        let a = candidate(name: "a", risk: .low, size: 10 * GB, defaultSelected: true)
        let b = candidate(name: "b", risk: .low, size: 8 * GB, defaultSelected: true)
        let c = candidate(name: "c", risk: .low, size: 5 * GB, defaultSelected: true)

        let draft = try await plan([c, b, a], target: 15 * GB)

        // 10 GB + 8 GB crosses the 15 GB target; 5 GB is left unselected.
        XCTAssertEqual(draft.defaultSelectedIDs, [a.id, b.id])
    }

    func testTargetSmallerThanSmallestItemStillSelectsOne() async throws {
        let a = candidate(name: "a", risk: .low, size: 10 * GB, defaultSelected: true)
        let draft = try await plan([a], target: 1 * GB)
        XCTAssertEqual(draft.defaultSelectedIDs, [a.id])
    }

    func testNoTargetPreservesReportDefaults() async throws {
        let low = candidate(name: "low", risk: .low, size: 1 * GB, defaultSelected: true)
        let medium = candidate(name: "medium", risk: .medium, size: 1 * GB, defaultSelected: false)
        let high = candidate(name: "high", risk: .high, size: 1 * GB, defaultSelected: false)

        let draft = try await plan([low, medium, high], target: nil)

        XCTAssertEqual(draft.defaultSelectedIDs, [low.id])
    }

    // MARK: Safety

    func testHighRiskNeverDefaultSelected() async throws {
        let high = candidate(name: "high", risk: .high, size: 3 * GB)
        let low = candidate(name: "low", risk: .low, size: 10 * GB, defaultSelected: true)

        let draft = try await plan([high, low], target: nil)

        XCTAssertFalse(draft.defaultSelectedIDs.contains(high.id))
        XCTAssertEqual(draft.defaultSelectedIDs, [low.id])
    }

    func testTargetSelectionIgnoresMediumAndHigh() async throws {
        let low = candidate(name: "low", risk: .low, size: 10 * GB, defaultSelected: true)
        let medium = candidate(name: "medium", risk: .medium, size: 20 * GB)
        let high = candidate(name: "high", risk: .high, size: 30 * GB)

        let draft = try await plan([low, medium, high], target: 100 * GB)

        XCTAssertEqual(draft.defaultSelectedIDs, [low.id])
    }

    // MARK: Edge cases

    func testEmptyReportYieldsEmptyPlan() async throws {
        let draft = try await plan([], target: nil)

        XCTAssertTrue(draft.groups.isEmpty)
        XCTAssertTrue(draft.defaultSelectedIDs.isEmpty)
    }

    func testDeterministicOutputForIdenticalRequest() async throws {
        let a = candidate(name: "a", risk: .low, size: 10 * GB, defaultSelected: true)
        let b = candidate(name: "b", risk: .medium, size: 5 * GB)
        let c = candidate(name: "c", risk: .high, size: 3 * GB)
        let request = PlanningRequest(report: report([c, b, a]), targetBytes: 9 * GB)

        let first = try await LocalCleanupPlanner().makeDraft(request: request)
        let second = try await LocalCleanupPlanner().makeDraft(request: request)

        XCTAssertEqual(first, second)
    }

    func testPlannerPerformsNoFilesystemAccess() async throws {
        // Synthetic candidates reference paths that do not exist; the planner
        // must succeed without ever touching the filesystem.
        let a = candidate(name: "ghost", risk: .low, size: 1 * GB)
        let draft = try await plan([a], target: nil)
        XCTAssertEqual(draft.groups.count, 1)
    }
}
