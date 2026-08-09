import Foundation
import SwiftUI

// MARK: - User-facing error

struct UserFacingError: Sendable, Equatable {
    let message: String
}

// MARK: - Flow state

enum AnalysisFlowState: Equatable {
    case idle
    case scanning
    case analyzing
    case reviewing(CleanupPlan)
    case preflighting
    case cleaning(CleanupProgress)
    case completed(CleanupResult)
    case failed(UserFacingError)
}

// MARK: - View model

/// Centralizes the analysis product flow. Owns the state machine, selection,
/// and orchestration; performs no filesystem mutation, no networking, and no
/// candidate rules itself — all three are injected.
@MainActor
final class AnalysisFlowViewModel: ObservableObject {

    @Published private(set) var state: AnalysisFlowState = .idle
    @Published private(set) var selectedCandidateIDs: Set<CandidateID> = []
    @Published private(set) var explicitlyApprovedIDs: Set<CandidateID> = []
    @Published private(set) var notice: String?
    @Published private(set) var lastExecutedBytes: Int64 = 0

    private let analyzer: any Analyzing
    private let coordinator: PlanningCoordinator
    private let makeExecutor: @Sendable (URL) -> any CleanupExecuting

    private var pipeline: Task<Void, Never>?
    private var generation = 0
    private var analysisRootURL: URL?
    private var lastPlan: CleanupPlan?

    init(
        analyzer: any Analyzing,
        coordinator: PlanningCoordinator,
        makeExecutor: @escaping @Sendable (URL) -> any CleanupExecuting = {
            TrashCleanupExecutor(rootURL: $0)
        }
    ) {
        self.analyzer = analyzer
        self.coordinator = coordinator
        self.makeExecutor = makeExecutor
    }

    // MARK: Intents

    func beginScanning() {
        state = .scanning
    }

    /// Runs analysis + planning for a completed scan tree.
    func startAnalysis(root: FileNode?, preferences: AnalysisPreferences, preferRemote: Bool = false) {
        guard let root else {
            state = .failed(UserFacingError(message: "The scan did not complete. Try rescanning."))
            return
        }

        pipeline?.cancel()
        generation += 1
        let gen = generation

        state = .analyzing
        notice = nil
        selectedCandidateIDs = []
        explicitlyApprovedIDs = []
        analysisRootURL = nil

        pipeline = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let report = await self.analyzer.analyze(root: root, preferences: preferences)
                try Task.checkCancellation()
                guard gen == self.generation else { return }

                self.analysisRootURL = report.rootURL

                let outcome = await self.coordinator.makePlan(
                    request: PlanningRequest(report: report, targetBytes: preferences.targetBytes),
                    preferRemote: preferRemote
                )
                try Task.checkCancellation()
                guard gen == self.generation else { return }

                switch outcome {
                case .plan(let plan, let planNotice):
                    self.notice = planNotice
                    self.selectedCandidateIDs = Set(plan.defaultSelectedIDs)
                    self.state = .reviewing(plan)
                case .failed(let failure):
                    self.state = .failed(UserFacingError(message: Self.message(for: failure)))
                }
            } catch is CancellationError {
                if gen == self.generation { self.state = .idle }
            } catch {
                if gen == self.generation {
                    self.state = .failed(UserFacingError(message: error.localizedDescription))
                }
            }
        }
    }

    func setSelection(_ id: CandidateID, isSelected: Bool, plan: CleanupPlan) {
        guard case .reviewing = state else { return }
        guard let candidate = plan.candidate(withID: id) else { return }

        if isSelected {
            // High-risk items require explicit approval before selection.
            guard candidate.risk != .high || explicitlyApprovedIDs.contains(id) else { return }
            selectedCandidateIDs.insert(id)
        } else {
            selectedCandidateIDs.remove(id)
        }
    }

    func approveHighRisk(_ id: CandidateID) {
        explicitlyApprovedIDs.insert(id)
    }

    func executeCleanup() {
        guard case .reviewing(let plan) = state else { return }
        guard let rootURL = analysisRootURL else { return }

        let byID = Dictionary(uniqueKeysWithValues: plan.allCandidates.map { ($0.id, $0) })
        let items = selectedCandidateIDs.compactMap { id -> ApprovedCleanupItem? in
            guard let candidate = byID[id] else { return nil }
            return ApprovedCleanupItem(
                candidate: candidate,
                explicitlyApproved: explicitlyApprovedIDs.contains(id)
            )
        }
        guard !items.isEmpty else { return }

        generation += 1
        let gen = generation
        state = .preflighting
        notice = nil
        lastPlan = plan
        lastExecutedBytes = items.reduce(0) { $0 + $1.candidate.allocatedSize }
        let executor = makeExecutor(rootURL)

        pipeline = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await executor.execute(items: items) { [weak self] progress in
                Task { @MainActor in
                    guard let self, gen == self.generation else { return }
                    self.state = .cleaning(progress)
                }
            }
            guard gen == self.generation else { return }
            self.state = .completed(result)
        }
    }

    func cancel() {
        pipeline?.cancel()
        pipeline = nil
        generation += 1
        state = .idle
    }

    /// Returns to the last reviewed plan with a cleared selection, so the
    /// user can re-check what remains after a partial cleanup.
    func returnToPlan() {
        guard let lastPlan else { return }
        selectedCandidateIDs = []
        state = .reviewing(lastPlan)
    }

    // MARK: Mapping

    private static func message(for failure: PlanningFailure) -> String {
        switch failure {
        case .localPlanningFailed:
            return "Recommendations could not be generated. Please try again."
        case .validationFailed:
            return "Recommendations could not be verified. Showing local results instead."
        }
    }
}

// MARK: - Plan lookups

extension CleanupPlan {
    var allCandidates: [CleanupCandidate] {
        groups.flatMap(\.candidates)
    }

    func candidate(withID id: CandidateID) -> CleanupCandidate? {
        allCandidates.first { $0.id == id }
    }
}
