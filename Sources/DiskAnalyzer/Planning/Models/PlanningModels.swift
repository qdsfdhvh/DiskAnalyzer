import Foundation

// MARK: - Planning request

struct PlanningRequest: Sendable, Equatable {
    let report: AnalysisReport
    let targetBytes: Int64?
}

// MARK: - Draft

/// Output of a planner (local or remote). References candidates by ID only;
/// all facts are copied from the local report during validation.
struct CleanupPlanDraft: Codable, Sendable, Equatable {
    let groups: [CleanupPlanGroupDraft]
    /// Candidate IDs the planner suggests pre-checking for execution.
    /// The validator enforces that these are known and never high-risk.
    let defaultSelectedIDs: [CandidateID]
}

struct CleanupPlanGroupDraft: Codable, Sendable, Equatable {
    let title: String
    let candidateIDs: [CandidateID]
    let explanation: String
}

// MARK: - Final plan

/// A validated plan. All candidate facts are copied from the local report;
/// only ordering, grouping, and explanation come from the draft.
struct CleanupPlan: Identifiable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let reportGeneratedAt: Date
    let groups: [CleanupPlanGroup]
    /// IDs the UI should pre-check, after validation.
    let defaultSelectedIDs: Set<CandidateID>
}

struct CleanupPlanGroup: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let explanation: String
    let candidates: [CleanupCandidate]
}
