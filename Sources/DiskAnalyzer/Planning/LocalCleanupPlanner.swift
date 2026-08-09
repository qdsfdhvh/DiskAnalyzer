import Foundation

/// Deterministic offline planner. Groups by risk in fixed order, sorts by
/// size descending within a group, and computes the suggested default
/// selection: low-risk candidates in size order until the target is reached,
/// or the report's own `defaultSelected` flags when no target is given.
struct LocalCleanupPlanner: CleanupPlanning, Sendable {

    func makeDraft(request: PlanningRequest) async throws -> CleanupPlanDraft {
        let candidates = request.report.candidates
        let low = candidates.filter { $0.risk == .low }
            .sorted { $0.allocatedSize > $1.allocatedSize }
        let medium = candidates.filter { $0.risk == .medium }
            .sorted { $0.allocatedSize > $1.allocatedSize }
        let high = candidates.filter { $0.risk == .high }
            .sorted { $0.allocatedSize > $1.allocatedSize }

        var groups: [CleanupPlanGroupDraft] = []
        if !low.isEmpty {
            groups.append(CleanupPlanGroupDraft(
                title: "Safe to reclaim",
                candidateIDs: low.map(\.id),
                explanation: "Regenerable or re-downloadable; low risk of data loss."
            ))
        }
        if !medium.isEmpty {
            groups.append(CleanupPlanGroupDraft(
                title: "Review recommended",
                candidateIDs: medium.map(\.id),
                explanation: "May contain data you want; check before cleaning."
            ))
        }
        if !high.isEmpty {
            groups.append(CleanupPlanGroupDraft(
                title: "Large items — manual judgment",
                candidateIDs: high.map(\.id),
                explanation: "Large files with no evidence they are disposable."
            ))
        }

        return CleanupPlanDraft(
            groups: groups,
            defaultSelectedIDs: selection(
                candidates: candidates,
                lowRiskOrder: low,
                targetBytes: request.targetBytes
            )
        )
    }

    // MARK: Selection

    private func selection(
        candidates: [CleanupCandidate],
        lowRiskOrder: [CleanupCandidate],
        targetBytes: Int64?
    ) -> [CandidateID] {
        if let targetBytes, targetBytes > 0 {
            var selected: [CleanupCandidate] = []
            var cumulative: Int64 = 0
            for candidate in lowRiskOrder {
                guard cumulative < targetBytes else { break }
                selected.append(candidate)
                cumulative += candidate.allocatedSize
            }
            return selected.map(\.id)
        }
        return candidates.filter(\.defaultSelected).map(\.id)
    }
}
