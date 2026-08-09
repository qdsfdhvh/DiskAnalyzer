import Foundation

// MARK: - Planning seam

/// Turns an analysis report into a plan draft. There are two adapters:
/// `LocalCleanupPlanner` (deterministic, always available) and a remote AI
/// planner. Drafts reference candidate IDs only.
protocol CleanupPlanning: Sendable {
    func makeDraft(request: PlanningRequest) async throws -> CleanupPlanDraft
}
