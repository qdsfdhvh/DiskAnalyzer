import XCTest
@testable import DiskAnalyzer

// MARK: - Fakes

private struct TestError: Error {}

private final class FakePlanner: CleanupPlanning, @unchecked Sendable {
    var result: Result<CleanupPlanDraft, Error> = .failure(TestError())
    var callCount = 0

    func makeDraft(request: PlanningRequest) async throws -> CleanupPlanDraft {
        callCount += 1
        return try result.get()
    }
}

// MARK: - Tests

final class PlanningCoordinatorTests: XCTestCase {

    private let GB = Int64(1024 * 1024 * 1024)
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCandidate(id: CandidateID, risk: RiskLevel = .low) -> CleanupCandidate {
        CleanupCandidate(
            id: id,
            url: URL(fileURLWithPath: "/tmp/Home/\(id.rawValue)"),
            displayPath: "~/candidate",
            category: .largeFile,
            allocatedSize: 2 * GB,
            risk: risk,
            defaultSelected: risk == .low,
            action: .moveToTrash,
            fingerprint: FileFingerprint(deviceID: 1, inode: 1, allocatedSize: 2 * GB, modificationTime: nil),
            evidence: []
        )
    }

    private func makeRequest() -> PlanningRequest {
        let candidate = makeCandidate(id: CandidateID(rawValue: UUID()))
        let report = AnalysisReport(
            generatedAt: fixedNow,
            rootURL: URL(fileURLWithPath: "/tmp/Home"),
            candidates: [candidate],
            warnings: []
        )
        return PlanningRequest(report: report, targetBytes: nil)
    }

    private func coordinator(
        local: (any CleanupPlanning)? = nil,
        remote: (any CleanupPlanning)? = nil
    ) -> PlanningCoordinator {
        let validator = CleanupPlanValidator(now: { [unowned self] in self.fixedNow })
        return PlanningCoordinator(
            localPlanner: local ?? LocalCleanupPlanner(),
            remotePlanner: remote,
            validator: validator
        )
    }

    private func remoteDraft(id: CandidateID, title: String = "AI Group") -> CleanupPlanDraft {
        CleanupPlanDraft(
            groups: [CleanupPlanGroupDraft(title: title, candidateIDs: [id], explanation: "AI explanation")],
            defaultSelectedIDs: []
        )
    }

    // MARK: Local success

    func testLocalSuccessWhenRemoteNotPreferred() async {
        let remote = FakePlanner()
        remote.result = .failure(TestError())
        let coordinator = coordinator(remote: remote)

        let outcome = await coordinator.makePlan(request: makeRequest(), preferRemote: false)

        guard case let .plan(plan, notice) = outcome else {
            return XCTFail("expected plan")
        }
        XCTAssertNil(notice)
        XCTAssertEqual(plan.groups.first?.title, "Safe to reclaim")
        XCTAssertEqual(remote.callCount, 0)
    }

    func testLocalSuccessWhenNoRemoteConfigured() async {
        let coordinator = coordinator(remote: nil)

        let outcome = await coordinator.makePlan(request: makeRequest(), preferRemote: true)

        guard case let .plan(plan, notice) = outcome else {
            return XCTFail("expected plan")
        }
        XCTAssertNil(notice)
        XCTAssertEqual(plan.groups.first?.title, "Safe to reclaim")
    }

    // MARK: Remote success

    func testRemoteSuccessUsesRemotePlan() async {
        let id = CandidateID(rawValue: UUID())
        let report = AnalysisReport(
            generatedAt: fixedNow,
            rootURL: URL(fileURLWithPath: "/tmp/Home"),
            candidates: [makeCandidate(id: id)],
            warnings: []
        )
        let request = PlanningRequest(report: report, targetBytes: nil)
        let remote = FakePlanner()
        remote.result = .success(remoteDraft(id: id, title: "AI Group"))

        let coordinator = coordinator(remote: remote)
        let outcome = await coordinator.makePlan(request: request, preferRemote: true)

        guard case let .plan(plan, notice) = outcome else {
            return XCTFail("expected plan")
        }
        XCTAssertNil(notice)
        XCTAssertEqual(plan.groups.first?.title, "AI Group")
        XCTAssertEqual(remote.callCount, 1)
    }

    // MARK: Remote failures fall back

    func testRemoteThrowFallsBackToLocal() async {
        let remote = FakePlanner()
        remote.result = .failure(TestError())
        let coordinator = coordinator(remote: remote)

        let outcome = await coordinator.makePlan(request: makeRequest(), preferRemote: true)

        guard case let .plan(plan, notice) = outcome else {
            return XCTFail("expected plan")
        }
        XCTAssertEqual(plan.groups.first?.title, "Safe to reclaim")
        XCTAssertNotNil(notice)
    }

    func testRemoteInvalidOutputFallsBackToLocal() async {
        let ghost = CandidateID(rawValue: UUID())
        let remote = FakePlanner()
        remote.result = .success(remoteDraft(id: ghost))
        let coordinator = coordinator(remote: remote)

        let outcome = await coordinator.makePlan(request: makeRequest(), preferRemote: true)

        guard case let .plan(plan, notice) = outcome else {
            return XCTFail("expected plan")
        }
        XCTAssertEqual(plan.groups.first?.title, "Safe to reclaim")
        XCTAssertNotNil(notice)
    }

    func testRemoteHighRiskSelectionFallsBackToLocal() async {
        let id = CandidateID(rawValue: UUID())
        let report = AnalysisReport(
            generatedAt: fixedNow,
            rootURL: URL(fileURLWithPath: "/tmp/Home"),
            candidates: [makeCandidate(id: id, risk: .high)],
            warnings: []
        )
        let request = PlanningRequest(report: report, targetBytes: nil)
        let remote = FakePlanner()
        remote.result = .success(CleanupPlanDraft(
            groups: [CleanupPlanGroupDraft(title: "AI", candidateIDs: [id], explanation: "")],
            defaultSelectedIDs: [id]  // invalid: high-risk default selection
        ))
        let coordinator = coordinator(remote: remote)

        let outcome = await coordinator.makePlan(request: request, preferRemote: true)

        guard case let .plan(plan, notice) = outcome else {
            return XCTFail("expected plan")
        }
        // Local fallback groups the high-risk candidate under manual judgment.
        XCTAssertEqual(plan.groups.first?.title, "Large items — manual judgment")
        XCTAssertNotNil(notice)
    }

    // MARK: Local failures surface

    func testLocalFailureSurfaced() async {
        let local = FakePlanner()
        local.result = .failure(TestError())
        let coordinator = coordinator(local: local, remote: nil)

        let outcome = await coordinator.makePlan(request: makeRequest(), preferRemote: false)

        XCTAssertEqual(outcome, .failed(.localPlanningFailed))
    }

    func testLocalValidationFailureSurfaced() async {
        let ghost = CandidateID(rawValue: UUID())
        let local = FakePlanner()
        local.result = .success(remoteDraft(id: ghost))
        let coordinator = coordinator(local: local, remote: nil)

        let outcome = await coordinator.makePlan(request: makeRequest(), preferRemote: false)

        guard case let .failed(failure) = outcome else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(failure, .validationFailed(.unknownCandidateID(ghost)))
    }
}
