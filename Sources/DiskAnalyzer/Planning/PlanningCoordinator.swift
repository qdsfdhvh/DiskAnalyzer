import Foundation

// MARK: - Outcomes

enum PlanningFailure: Sendable, Equatable {
    case localPlanningFailed
    case validationFailed(CleanupPlanValidationError)
}

enum PlanningOutcome: Sendable, Equatable {
    case plan(CleanupPlan, notice: String?)
    case failed(PlanningFailure)
}

// MARK: - Coordinator

/// Chooses between local and remote planning while guaranteeing a validated
/// local plan whenever the local input is valid. Remote failures (unavailable,
/// throw, timeout, invalid output) always fall back to the local planner with
/// a user-facing notice.
struct PlanningCoordinator: Sendable {

    let localPlanner: any CleanupPlanning
    let remotePlanner: (any CleanupPlanning)?
    let validator: CleanupPlanValidator

    init(
        localPlanner: any CleanupPlanning = LocalCleanupPlanner(),
        remotePlanner: (any CleanupPlanning)? = nil,
        validator: CleanupPlanValidator = CleanupPlanValidator()
    ) {
        self.localPlanner = localPlanner
        self.remotePlanner = remotePlanner
        self.validator = validator
    }

    func makePlan(request: PlanningRequest, preferRemote: Bool) async -> PlanningOutcome {
        if preferRemote, let remotePlanner {
            do {
                let draft = try await remotePlanner.makeDraft(request: request)
                let plan = try validator.validate(draft: draft, against: request.report)
                return .plan(plan, notice: nil)
            } catch {
                return await makeLocalPlan(
                    request,
                    notice: "AI planning is unavailable — showing local recommendations."
                )
            }
        }
        return await makeLocalPlan(request, notice: nil)
    }

    // MARK: Local path

    private func makeLocalPlan(_ request: PlanningRequest, notice: String?) async -> PlanningOutcome {
        do {
            let draft = try await localPlanner.makeDraft(request: request)
            let plan = try validator.validate(draft: draft, against: request.report)
            return .plan(plan, notice: notice)
        } catch let error as CleanupPlanValidationError {
            return .failed(.validationFailed(error))
        } catch {
            return .failed(.localPlanningFailed)
        }
    }
}
