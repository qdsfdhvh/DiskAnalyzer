import XCTest
@testable import DiskAnalyzer

// MARK: - Fakes

private struct TestError: Error {}

private final class FakeAnalyzer: Analyzing, @unchecked Sendable {
    var result: AnalysisReport

    init(result: AnalysisReport) {
        self.result = result
    }

    func analyze(root: FileNode, preferences: AnalysisPreferences) async -> AnalysisReport {
        result
    }
}

/// Analyzer that blocks each call until released, then returns queued reports
/// in order. Used to test cancellation and stale-run protection.
private actor BlockingAnalyzer: Analyzing {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var queue: [AnalysisReport]
    private(set) var callCount = 0

    init(reports: [AnalysisReport]) {
        self.queue = reports
    }

    func analyze(root: FileNode, preferences: AnalysisPreferences) async -> AnalysisReport {
        callCount += 1
        // Claim this call's report up front: continuation resumption order is
        // not guaranteed, so a shared pop-at-resume could hand a stale report
        // to the newest run.
        let report = queue.isEmpty ? AnalysisReport(
            generatedAt: Date(),
            rootURL: URL(fileURLWithPath: "/tmp"),
            candidates: [],
            warnings: []
        ) : queue.removeFirst()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuations.append(cont)
        }
        return report
    }

    func releaseAll() {
        let conts = continuations
        continuations.removeAll()
        conts.forEach { $0.resume() }
    }
}

private final class FakeExecutor: CleanupExecuting, @unchecked Sendable {
    var result: CleanupResult = CleanupResult(outcomes: [])
    var progressSequence: [CleanupProgress] = []
    var receivedItems: [ApprovedCleanupItem] = []
    var blocksUntilReleased = false
    private(set) var executeCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func execute(
        items: [ApprovedCleanupItem],
        progress: @escaping @Sendable (CleanupProgress) -> Void
    ) async -> CleanupResult {
        executeCount += 1
        receivedItems = items
        for p in progressSequence {
            progress(p)
        }
        if blocksUntilReleased {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                continuation = cont
            }
        }
        return result
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Test suite

@MainActor
final class AnalysisFlowViewModelTests: XCTestCase {

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

    private func makeReport(candidates: [CleanupCandidate]) -> AnalysisReport {
        AnalysisReport(
            generatedAt: fixedNow,
            rootURL: URL(fileURLWithPath: "/tmp/Home"),
            candidates: candidates,
            warnings: []
        )
    }

    private func makeRoot() -> FileNode {
        FileNode(url: URL(fileURLWithPath: "/tmp/Home"), name: "Home", isDirectory: true)
    }

    private func makeCoordinator() -> PlanningCoordinator {
        PlanningCoordinator(
            localPlanner: LocalCleanupPlanner(),
            remotePlanner: nil,
            validator: CleanupPlanValidator(now: { [unowned self] in self.fixedNow })
        )
    }

    private func makeVM(
        analyzer: any Analyzing,
        executor: FakeExecutor
    ) -> AnalysisFlowViewModel {
        AnalysisFlowViewModel(
            analyzer: analyzer,
            coordinator: makeCoordinator(),
            makeExecutor: { _ in executor }
        )
    }

    private func waitForTerminal(_ vm: AnalysisFlowViewModel) async {
        for _ in 0..<500 {
            switch vm.state {
            case .reviewing, .failed, .completed, .idle:
                return
            default:
                await Task.yield()
            }
        }
    }

    // MARK: State machine

    func testInitialStateIsIdle() {
        let vm = makeVM(analyzer: FakeAnalyzer(result: makeReport(candidates: [])), executor: FakeExecutor())
        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(vm.selectedCandidateIDs.isEmpty)
    }

    func testScanningThenAnalysisReachesReview() async {
        let id = CandidateID(rawValue: UUID())
        let vm = makeVM(
            analyzer: FakeAnalyzer(result: makeReport(candidates: [makeCandidate(id: id)])),
            executor: FakeExecutor()
        )

        vm.beginScanning()
        XCTAssertEqual(vm.state, .scanning)

        vm.startAnalysis(
            root: makeRoot(),
            preferences: AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7)
        )
        XCTAssertEqual(vm.state, .analyzing)

        await waitForTerminal(vm)

        guard case .reviewing(let plan) = vm.state else {
            return XCTFail("expected reviewing, got \(vm.state)")
        }
        XCTAssertEqual(plan.allCandidates.map(\.id), [id])
        // The local planner default-selects the low-risk candidate.
        XCTAssertEqual(vm.selectedCandidateIDs, [id])
    }

    func testScanFailureSurfacesError() {
        let vm = makeVM(analyzer: FakeAnalyzer(result: makeReport(candidates: [])), executor: FakeExecutor())

        vm.startAnalysis(root: nil, preferences: AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7))

        guard case .failed(let error) = vm.state else {
            return XCTFail("expected failed, got \(vm.state)")
        }
        XCTAssertTrue(error.message.contains("scan"))
    }

    // MARK: Selection

    func testSelectionRequiresReviewState() async {
        let id = CandidateID(rawValue: UUID())
        let vm = makeVM(
            analyzer: FakeAnalyzer(result: makeReport(candidates: [makeCandidate(id: id)])),
            executor: FakeExecutor()
        )
        let plan = CleanupPlan(
            id: UUID(),
            createdAt: fixedNow,
            reportGeneratedAt: fixedNow,
            groups: [],
            defaultSelectedIDs: []
        )

        // Not reviewing yet: selection is ignored.
        vm.setSelection(id, isSelected: true, plan: plan)
        XCTAssertTrue(vm.selectedCandidateIDs.isEmpty)
    }

    func testSelectionAndDeselectionDuringReview() async {
        let id = CandidateID(rawValue: UUID())
        let vm = makeVM(
            analyzer: FakeAnalyzer(result: makeReport(candidates: [makeCandidate(id: id)])),
            executor: FakeExecutor()
        )
        vm.startAnalysis(root: makeRoot(), preferences: AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7))
        await waitForTerminal(vm)
        guard case .reviewing(let plan) = vm.state else { return XCTFail() }

        vm.setSelection(id, isSelected: true, plan: plan)
        XCTAssertTrue(vm.selectedCandidateIDs.contains(id))

        vm.setSelection(id, isSelected: false, plan: plan)
        XCTAssertFalse(vm.selectedCandidateIDs.contains(id))
    }

    func testHighRiskRequiresExplicitApproval() async {
        let id = CandidateID(rawValue: UUID())
        let vm = makeVM(
            analyzer: FakeAnalyzer(result: makeReport(candidates: [makeCandidate(id: id, risk: .high)])),
            executor: FakeExecutor()
        )
        vm.startAnalysis(root: makeRoot(), preferences: AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7))
        await waitForTerminal(vm)
        guard case .reviewing(let plan) = vm.state else { return XCTFail() }

        // Without approval the selection is refused.
        vm.setSelection(id, isSelected: true, plan: plan)
        XCTAssertFalse(vm.selectedCandidateIDs.contains(id))

        vm.approveHighRisk(id)
        vm.setSelection(id, isSelected: true, plan: plan)
        XCTAssertTrue(vm.selectedCandidateIDs.contains(id))
    }

    // MARK: Cleanup

    func testCleanupPartialResult() async {
        let id = CandidateID(rawValue: UUID())
        let executor = FakeExecutor()
        let vm = makeVM(
            analyzer: FakeAnalyzer(result: makeReport(candidates: [makeCandidate(id: id)])),
            executor: executor
        )
        vm.startAnalysis(root: makeRoot(), preferences: AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7))
        await waitForTerminal(vm)

        executor.result = CleanupResult(outcomes: [
            .movedToTrash(originalURL: URL(fileURLWithPath: "/tmp/Home/a"), trashURL: nil),
            .skipped(displayPath: "b", reason: .rejected(.changed(displayPath: "b"))),
            .failed(displayPath: "c", message: "boom")
        ])
        executor.progressSequence = [
            CleanupProgress(completedItems: 1, totalItems: 3, currentDisplayPath: "x")
        ]

        vm.executeCleanup()
        await waitForTerminal(vm)

        guard case .completed(let result) = vm.state else {
            return XCTFail("expected completed, got \(vm.state)")
        }
        XCTAssertEqual(result.movedCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.failedCount, 1)
    }

    func testCleanupIgnoresEmptySelection() async {
        let id = CandidateID(rawValue: UUID())
        let vm = makeVM(
            analyzer: FakeAnalyzer(result: makeReport(candidates: [makeCandidate(id: id, risk: .high)])),
            executor: FakeExecutor()
        )
        vm.startAnalysis(root: makeRoot(), preferences: AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7))
        await waitForTerminal(vm)
        guard case .reviewing = vm.state else { return XCTFail() }

        vm.executeCleanup()

        guard case .reviewing = vm.state else {
            return XCTFail("expected still reviewing, got \(vm.state)")
        }
    }

    func testExecuteCleanupIgnoredOutsideReview() {
        let executor = FakeExecutor()
        let vm = makeVM(analyzer: FakeAnalyzer(result: makeReport(candidates: [])), executor: executor)

        vm.executeCleanup()

        XCTAssertEqual(vm.state, .idle)
        XCTAssertTrue(executor.receivedItems.isEmpty)
    }

    func testDuplicateSubmitSuppressedWhileExecuting() async {
        let id = CandidateID(rawValue: UUID())
        let executor = FakeExecutor()
        executor.blocksUntilReleased = true
        let vm = makeVM(
            analyzer: FakeAnalyzer(result: makeReport(candidates: [makeCandidate(id: id)])),
            executor: executor
        )
        vm.startAnalysis(root: makeRoot(), preferences: AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7))
        await waitForTerminal(vm)

        vm.executeCleanup()
        for _ in 0..<100 {
            if executor.executeCount >= 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(vm.state, .preflighting)
        XCTAssertEqual(executor.executeCount, 1)

        // A second submission while executing must be ignored.
        vm.executeCleanup()
        XCTAssertEqual(executor.executeCount, 1)

        executor.release()
        await waitForTerminal(vm)
        XCTAssertEqual(executor.executeCount, 1)
    }

    func testResultResetOnNewAnalysis() async {
        let id = CandidateID(rawValue: UUID())
        let executor = FakeExecutor()
        executor.result = CleanupResult(outcomes: [
            .movedToTrash(originalURL: URL(fileURLWithPath: "/tmp/Home/a"), trashURL: nil)
        ])
        let vm = makeVM(
            analyzer: FakeAnalyzer(result: makeReport(candidates: [makeCandidate(id: id)])),
            executor: executor
        )
        let preferences = AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7)
        vm.startAnalysis(root: makeRoot(), preferences: preferences)
        await waitForTerminal(vm)
        vm.executeCleanup()
        await waitForTerminal(vm)
        guard case .completed = vm.state else { return XCTFail("expected completed") }

        // A fresh analysis resets state and selection.
        vm.startAnalysis(root: makeRoot(), preferences: preferences)
        await waitForTerminal(vm)

        guard case .reviewing(let plan) = vm.state else {
            return XCTFail("expected reviewing, got \(vm.state)")
        }
        XCTAssertEqual(plan.allCandidates.map(\.id), [id])
        XCTAssertEqual(vm.selectedCandidateIDs, [id])
        XCTAssertEqual(vm.lastExecutedBytes, 2 * GB)
    }

    func testReturnToPlanClearsSelection() async {
        let id = CandidateID(rawValue: UUID())
        let executor = FakeExecutor()
        executor.result = CleanupResult(outcomes: [
            .movedToTrash(originalURL: URL(fileURLWithPath: "/tmp/Home/a"), trashURL: nil)
        ])
        let vm = makeVM(
            analyzer: FakeAnalyzer(result: makeReport(candidates: [makeCandidate(id: id)])),
            executor: executor
        )
        let preferences = AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7)
        vm.startAnalysis(root: makeRoot(), preferences: preferences)
        await waitForTerminal(vm)
        vm.executeCleanup()
        await waitForTerminal(vm)
        guard case .completed = vm.state else { return XCTFail("expected completed") }

        vm.returnToPlan()

        guard case .reviewing = vm.state else {
            return XCTFail("expected reviewing, got \(vm.state)")
        }
        XCTAssertTrue(vm.selectedCandidateIDs.isEmpty)
    }

    // MARK: Cancellation and stale runs

    func testCancelDuringAnalysis() async {
        let blocking = BlockingAnalyzer(reports: [])
        let vm = makeVM(analyzer: blocking, executor: FakeExecutor())

        vm.startAnalysis(root: makeRoot(), preferences: AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7))
        await Task.yield()  // pipeline runs and blocks in the analyzer
        XCTAssertEqual(vm.state, .analyzing)

        vm.cancel()
        XCTAssertEqual(vm.state, .idle)

        await blocking.releaseAll()
        await Task.yield()

        XCTAssertEqual(vm.state, .idle)
    }

    func testStaleRunCannotOverwriteNewerRun() async {
        let staleID = CandidateID(rawValue: UUID())
        let freshID = CandidateID(rawValue: UUID())
        let blocking = BlockingAnalyzer(reports: [
            makeReport(candidates: [makeCandidate(id: staleID)]),
            makeReport(candidates: [makeCandidate(id: freshID)])
        ])
        let vm = makeVM(analyzer: blocking, executor: FakeExecutor())
        let preferences = AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7)

        vm.startAnalysis(root: makeRoot(), preferences: preferences)   // run 1
        for _ in 0..<100 {
            if await blocking.callCount >= 1 { break }
            await Task.yield()
        }
        vm.startAnalysis(root: makeRoot(), preferences: preferences)   // run 2 supersedes run 1
        for _ in 0..<100 {
            if await blocking.callCount >= 2 { break }
            await Task.yield()
        }

        await blocking.releaseAll()
        await waitForTerminal(vm)

        guard case .reviewing(let plan) = vm.state else {
            return XCTFail("expected reviewing, got \(vm.state)")
        }
        XCTAssertEqual(plan.allCandidates.map(\.id), [freshID])
        XCTAssertEqual(vm.selectedCandidateIDs, [freshID])
    }

    func testCancelDuringCleaningStaysCancelled() async {
        let id = CandidateID(rawValue: UUID())
        let executor = FakeExecutor()
        executor.blocksUntilReleased = true
        let vm = makeVM(
            analyzer: FakeAnalyzer(result: makeReport(candidates: [makeCandidate(id: id)])),
            executor: executor
        )
        vm.startAnalysis(root: makeRoot(), preferences: AnalysisPreferences(targetBytes: nil, preserveRecentDays: 7))
        await waitForTerminal(vm)

        vm.executeCleanup()
        await Task.yield()
        XCTAssertEqual(vm.state, .preflighting)

        vm.cancel()
        XCTAssertEqual(vm.state, .idle)

        executor.release()
        await Task.yield()

        XCTAssertEqual(vm.state, .idle)
    }
}
