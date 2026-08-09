import Foundation

/// AI planner adapter: redacts the report into a bounded DTO and asks the
/// OpenAI-compatible client for a plan draft. All safety checks happen in
/// `CleanupPlanValidator`; the coordinator handles fallback to the local
/// planner on any failure.
struct RemoteCleanupPlanner: CleanupPlanning, Sendable {

    let redactor: PrivacyRedactor
    let client: OpenAICompatibleClient
    let limit: Int

    init(
        redactor: PrivacyRedactor = PrivacyRedactor(),
        client: OpenAICompatibleClient,
        limit: Int = 100
    ) {
        self.redactor = redactor
        self.client = client
        self.limit = limit
    }

    func makeDraft(request: PlanningRequest) async throws -> CleanupPlanDraft {
        let dto = redactor.redact(report: request.report, targetBytes: request.targetBytes, limit: limit)
        return try await client.draft(for: dto)
    }
}
