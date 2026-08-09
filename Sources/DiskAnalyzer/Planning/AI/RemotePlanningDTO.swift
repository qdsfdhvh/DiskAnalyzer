import Foundation

/// The only payload ever sent to a remote planner. Deliberately contains no
/// URLs, fingerprints, exact timestamps, file contents, usernames, or volume
/// names — just compact, redacted candidate summaries.
struct RemotePlanningDTO: Codable, Sendable, Equatable {
    let targetBytes: Int64?
    let candidates: [RemoteCandidateDTO]
}

struct RemoteCandidateDTO: Codable, Sendable, Equatable {
    let id: String
    let pathLabel: String
    let category: CleanupCategory
    let sizeBytes: Int64
    let risk: RiskLevel
    let defaultSelected: Bool
    let evidence: [String]
}
