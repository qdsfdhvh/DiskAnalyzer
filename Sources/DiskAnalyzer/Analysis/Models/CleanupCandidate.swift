import Foundation

// MARK: - Candidate identity

/// Opaque identifier for one cleanup candidate. Referenced by plan drafts and
/// remote planners; never carries path semantics by itself. Encodes as a bare
/// UUID string so remote JSON can reference candidates directly.
struct CandidateID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Enumerations

enum CleanupCategory: String, Codable, Sendable {
    case developerCache
    case applicationCache
    case oldInstaller
    case oldDownload
    case simulatorData
    case largeFile
}

/// Risk of cleaning an item, ordered low < medium < high.
enum RiskLevel: Int, Codable, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// All cleanup actions the app can execute. The executor accepts only these
/// registered actions; anything else is rejected at validation.
enum CleanupAction: String, Codable, Sendable {
    case moveToTrash
}

/// Kinds of evidence a candidate can cite. Kept as an enum so the UI can
/// render each kind distinctly and tests can assert on semantics.
enum EvidenceKind: String, Codable, Sendable {
    case knownRebuildablePath
    case ageInDays
    case allocatedSize
    case fileExtension
    case userDataLocation
}

// MARK: - Evidence

/// One locally verified fact supporting a candidate.
struct CandidateEvidence: Codable, Hashable, Sendable {
    let kind: EvidenceKind
    let summary: String
}

// MARK: - Fingerprint

/// Stable identity plus a size/date snapshot used to verify the item is
/// unchanged immediately before any cleanup action.
struct FileFingerprint: Codable, Hashable, Sendable {
    let deviceID: UInt64
    let inode: UInt64
    let allocatedSize: Int64
    let modificationTime: Date?
}

// MARK: - Candidate

/// A fully enriched, immutable cleanup candidate. `url`, size, risk, action,
/// and evidence are established locally and must never be overridden by a
/// model or remote planner.
struct CleanupCandidate: Identifiable, Codable, Hashable, Sendable {
    let id: CandidateID
    let url: URL
    let displayPath: String
    let category: CleanupCategory
    let allocatedSize: Int64
    let risk: RiskLevel
    let defaultSelected: Bool
    let action: CleanupAction
    let fingerprint: FileFingerprint
    let evidence: [CandidateEvidence]
}
