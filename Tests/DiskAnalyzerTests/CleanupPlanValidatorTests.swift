import XCTest
@testable import DiskAnalyzer

final class CleanupPlanValidatorTests: XCTestCase {

    private let GB = Int64(1024 * 1024 * 1024)
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(
        id: CandidateID,
        name: String,
        risk: RiskLevel,
        defaultSelected: Bool = false,
        url: URL = URL(fileURLWithPath: "/tmp/Home")
    ) -> CleanupCandidate {
        CleanupCandidate(
            id: id,
            url: url.appendingPathComponent(name),
            displayPath: "~/\(name)",
            category: .largeFile,
            allocatedSize: 2 * GB,
            risk: risk,
            defaultSelected: defaultSelected,
            action: .moveToTrash,
            fingerprint: FileFingerprint(deviceID: 1, inode: 42, allocatedSize: 2 * GB, modificationTime: nil),
            evidence: [CandidateEvidence(kind: .allocatedSize, summary: "Large regular file")]
        )
    }

    private func report(_ candidates: [CleanupCandidate]) -> AnalysisReport {
        AnalysisReport(
            generatedAt: Date(timeIntervalSince1970: 1_600_000_000),
            rootURL: URL(fileURLWithPath: "/tmp/Home"),
            candidates: candidates,
            warnings: []
        )
    }

    private func validator() -> CleanupPlanValidator {
        CleanupPlanValidator(now: { [unowned self] in self.fixedNow })
    }

    private func makeIDs(_ count: Int) -> [CandidateID] {
        (0..<count).map { _ in CandidateID(rawValue: UUID()) }
    }

    // MARK: Success paths

    func testValidDraftProducesPlan() throws {
        let ids = makeIDs(3)
        let low = candidate(id: ids[0], name: "a", risk: .low, defaultSelected: true)
        let high = candidate(id: ids[1], name: "b", risk: .high)
        let medium = candidate(id: ids[2], name: "c", risk: .medium)
        let rep = report([low, high, medium])

        let draft = CleanupPlanDraft(
            groups: [
                CleanupPlanGroupDraft(
                    title: "Safe to reclaim",
                    candidateIDs: [low.id],
                    explanation: "Regenerable or re-downloadable"
                ),
                CleanupPlanGroupDraft(
                    title: "Large items",
                    candidateIDs: [high.id, medium.id],
                    explanation: "Manual judgment"
                )
            ],
            defaultSelectedIDs: [low.id]
        )

        let plan = try validator().validate(draft: draft, against: rep)

        XCTAssertEqual(plan.reportGeneratedAt, rep.generatedAt)
        XCTAssertEqual(plan.createdAt, fixedNow)
        XCTAssertEqual(plan.groups.count, 2)
        XCTAssertEqual(plan.groups[0].title, "Safe to reclaim")
        XCTAssertEqual(plan.groups[0].candidates.map(\.id), [low.id])
        XCTAssertEqual(plan.groups[1].candidates.map(\.id), [high.id, medium.id])
        XCTAssertEqual(plan.defaultSelectedIDs, [low.id])
    }

    func testCandidateFieldsCopiedVerbatimFromReport() throws {
        let ids = makeIDs(1)
        let low = candidate(id: ids[0], name: "a", risk: .low, defaultSelected: true)
        let rep = report([low])
        let draft = CleanupPlanDraft(
            groups: [CleanupPlanGroupDraft(title: "G", candidateIDs: [low.id], explanation: "")],
            defaultSelectedIDs: []
        )

        let plan = try validator().validate(draft: draft, against: rep)

        // Full equality proves no draft text can override any candidate field.
        XCTAssertEqual(plan.groups[0].candidates[0], low)
    }

    func testEmptyDraftYieldsEmptyPlan() throws {
        let rep = report([])
        let plan = try validator().validate(
            draft: CleanupPlanDraft(groups: [], defaultSelectedIDs: []),
            against: rep
        )
        XCTAssertTrue(plan.groups.isEmpty)
        XCTAssertTrue(plan.defaultSelectedIDs.isEmpty)
    }

    func testExplanationIsTrimmedAndCapped() throws {
        let ids = makeIDs(1)
        let low = candidate(id: ids[0], name: "a", risk: .low)
        let rep = report([low])
        let longText = String(repeating: "x", count: 500)
        let draft = CleanupPlanDraft(
            groups: [CleanupPlanGroupDraft(
                title: "  Group  ",
                candidateIDs: [low.id],
                explanation: "  \(longText)  "
            )],
            defaultSelectedIDs: []
        )

        let plan = try validator().validate(draft: draft, against: rep)

        XCTAssertEqual(plan.groups[0].title, "Group")
        XCTAssertEqual(plan.groups[0].explanation.count, CleanupPlanValidator.maxExplanationLength)
    }

    // MARK: Rejections

    func testUnknownCandidateIDRejected() throws {
        let rep = report([candidate(id: makeIDs(1)[0], name: "a", risk: .low)])
        let ghost = makeIDs(1)[0]
        let draft = CleanupPlanDraft(
            groups: [CleanupPlanGroupDraft(title: "G", candidateIDs: [ghost], explanation: "")],
            defaultSelectedIDs: []
        )

        XCTAssertThrowsError(try validator().validate(draft: draft, against: rep)) { error in
            XCTAssertEqual(error as? CleanupPlanValidationError, .unknownCandidateID(ghost))
        }
    }

    func testDuplicateCandidateIDRejectedAcrossGroups() throws {
        let ids = makeIDs(1)
        let low = candidate(id: ids[0], name: "a", risk: .low)
        let rep = report([low])
        let draft = CleanupPlanDraft(
            groups: [
                CleanupPlanGroupDraft(title: "G1", candidateIDs: [low.id], explanation: ""),
                CleanupPlanGroupDraft(title: "G2", candidateIDs: [low.id], explanation: "")
            ],
            defaultSelectedIDs: []
        )

        XCTAssertThrowsError(try validator().validate(draft: draft, against: rep)) { error in
            XCTAssertEqual(error as? CleanupPlanValidationError, .duplicateCandidateID(low.id))
        }
    }

    func testHighRiskDefaultSelectionRejected() throws {
        let ids = makeIDs(1)
        let high = candidate(id: ids[0], name: "b", risk: .high)
        let rep = report([high])
        let draft = CleanupPlanDraft(
            groups: [CleanupPlanGroupDraft(title: "G", candidateIDs: [high.id], explanation: "")],
            defaultSelectedIDs: [high.id]
        )

        XCTAssertThrowsError(try validator().validate(draft: draft, against: rep)) { error in
            XCTAssertEqual(error as? CleanupPlanValidationError, .highRiskDefaultSelection(high.id))
        }
    }

    func testDefaultSelectionUnknownIDRejected() throws {
        let ids = makeIDs(1)
        let low = candidate(id: ids[0], name: "a", risk: .low)
        let rep = report([low])
        let ghost = makeIDs(1)[0]
        let draft = CleanupPlanDraft(
            groups: [CleanupPlanGroupDraft(title: "G", candidateIDs: [low.id], explanation: "")],
            defaultSelectedIDs: [ghost]
        )

        XCTAssertThrowsError(try validator().validate(draft: draft, against: rep)) { error in
            XCTAssertEqual(error as? CleanupPlanValidationError, .unknownCandidateID(ghost))
        }
    }

    func testOutsideRootCandidateRejected() throws {
        let id = CandidateID(rawValue: UUID())
        let outside = candidate(
            id: id,
            name: "x",
            risk: .low,
            url: URL(fileURLWithPath: "/tmp/Other")
        )
        let rep = report([outside])
        let draft = CleanupPlanDraft(
            groups: [CleanupPlanGroupDraft(title: "G", candidateIDs: [id], explanation: "")],
            defaultSelectedIDs: []
        )

        XCTAssertThrowsError(try validator().validate(draft: draft, against: rep)) { error in
            XCTAssertEqual(error as? CleanupPlanValidationError, .outsideRoot(id))
        }
    }

    func testEmptyGroupTitleRejected() throws {
        let ids = makeIDs(1)
        let low = candidate(id: ids[0], name: "a", risk: .low)
        let rep = report([low])
        let draft = CleanupPlanDraft(
            groups: [CleanupPlanGroupDraft(title: "   ", candidateIDs: [low.id], explanation: "")],
            defaultSelectedIDs: []
        )

        XCTAssertThrowsError(try validator().validate(draft: draft, against: rep)) { error in
            XCTAssertEqual(error as? CleanupPlanValidationError, .emptyGroupTitle)
        }
    }

    // MARK: Guarantee

    func testDraftCannotCarryExecutableFields() throws {
        // A draft's only fields are title/IDs/explanation; there is no field
        // for path, size, risk, action, or evidence. This test encodes that
        // invariant so a model-generated draft can never smuggle them in.
        let ids = makeIDs(1)
        let low = candidate(id: ids[0], name: "a", risk: .low)
        let rep = report([low])
        let draft = CleanupPlanDraft(
            groups: [CleanupPlanGroupDraft(title: "G", candidateIDs: [low.id], explanation: "")],
            defaultSelectedIDs: []
        )

        let plan = try validator().validate(draft: draft, against: rep)
        XCTAssertEqual(plan.groups[0].candidates[0].url, low.url)
        XCTAssertEqual(plan.groups[0].candidates[0].allocatedSize, low.allocatedSize)
        XCTAssertEqual(plan.groups[0].candidates[0].risk, low.risk)
        XCTAssertEqual(plan.groups[0].candidates[0].action, .moveToTrash)
        XCTAssertEqual(plan.groups[0].candidates[0].evidence, low.evidence)
    }
}
