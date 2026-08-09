import Foundation

// MARK: - Validation errors

enum CleanupPlanValidationError: Error, Equatable, LocalizedError {
    case unknownCandidateID(CandidateID)
    case duplicateCandidateID(CandidateID)
    case highRiskDefaultSelection(CandidateID)
    case outsideRoot(CandidateID)
    case emptyGroupTitle

    var errorDescription: String? {
        switch self {
        case .unknownCandidateID:
            return "The plan references a candidate that does not exist in this analysis."
        case .duplicateCandidateID:
            return "The plan references the same candidate more than once."
        case .highRiskDefaultSelection:
            return "The plan would default-select a high-risk item."
        case .outsideRoot:
            return "The plan references a candidate outside the analyzed folder."
        case .emptyGroupTitle:
            return "The plan contains a group without a title."
        }
    }
}

// MARK: - Validator

/// The single module allowed to turn a plan draft into an executable plan.
///
/// All candidate facts (path, size, risk, action, evidence, fingerprint) are
/// copied by ID from the local report; a draft can only supply ordering,
/// grouping, and bounded explanation text. There is no code path by which
/// draft-provided text can construct or override a candidate.
struct CleanupPlanValidator: Sendable {

    static let maxExplanationLength = 300

    let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    func validate(draft: CleanupPlanDraft, against report: AnalysisReport) throws -> CleanupPlan {
        let byID = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.id, $0) })
        var seen: Set<CandidateID> = []
        var groups: [CleanupPlanGroup] = []

        for groupDraft in draft.groups {
            let title = groupDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw CleanupPlanValidationError.emptyGroupTitle
            }

            var candidates: [CleanupCandidate] = []
            for id in groupDraft.candidateIDs {
                guard let candidate = byID[id] else {
                    throw CleanupPlanValidationError.unknownCandidateID(id)
                }
                guard seen.insert(id).inserted else {
                    throw CleanupPlanValidationError.duplicateCandidateID(id)
                }
                // Structural containment: candidates must live under the
                // analyzed root. (Runtime containment — including symlink
                // resolution — is re-checked by preflight at execution time.)
                let root = Self.std(report.rootURL.path)
                let path = Self.std(candidate.url.path)
                guard path.hasPrefix(root + "/") else {
                    throw CleanupPlanValidationError.outsideRoot(id)
                }
                // Copy the immutable report value; nothing from the draft is
                // ever merged into the candidate.
                candidates.append(candidate)
            }

            groups.append(CleanupPlanGroup(
                id: UUID(),
                title: title,
                explanation: Self.capped(groupDraft.explanation),
                candidates: candidates
            ))
        }

        var selection: Set<CandidateID> = []
        for id in draft.defaultSelectedIDs {
            guard let candidate = byID[id] else {
                throw CleanupPlanValidationError.unknownCandidateID(id)
            }
            guard candidate.risk != .high else {
                throw CleanupPlanValidationError.highRiskDefaultSelection(id)
            }
            selection.insert(id)
        }

        return CleanupPlan(
            id: UUID(),
            createdAt: now(),
            reportGeneratedAt: report.generatedAt,
            groups: groups,
            defaultSelectedIDs: selection
        )
    }

    /// Explanation text is display-only, so oversize input is truncated
    /// deterministically rather than failing the whole plan.
    private static func capped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxExplanationLength else { return trimmed }
        return String(trimmed.prefix(maxExplanationLength))
    }

    private static func std(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
