import Foundation

// MARK: - Analysis preferences

/// User-supplied goals for one analysis run. Pure value; owned by the UI layer.
struct AnalysisPreferences: Sendable, Equatable {
    /// How much space the user wants to reclaim, if any.
    var targetBytes: Int64?
    /// Files modified within this many days are treated as "recent" and
    /// excluded from age-based low-risk categories.
    var preserveRecentDays: Int
}

// MARK: - Analysis warnings

/// Non-fatal issues raised during discovery or enrichment. Never fails an
/// analysis by itself.
enum AnalysisWarning: Sendable, Equatable {
    /// Candidate discovery hit its cap; `omittedCount` candidates were dropped.
    case candidateLimitReached(omittedCount: Int)
    /// Filesystem metadata for one candidate could not be obtained; the
    /// candidate was omitted from the report.
    case metadataUnavailable(displayPath: String)
}

// MARK: - Candidate seed

/// Compact discovery output. Produced during a single in-memory traversal of a
/// completed scan tree; deliberately carries no filesystem metadata.
struct CandidateSeed: Sendable, Equatable, Hashable {
    let url: URL
    let category: CleanupCategory
    /// Size reported by the scan tree, not a fresh stat.
    let treeSize: Int64
}

// MARK: - Analysis report

/// Immutable, self-contained output of one analysis run. Snapshot of the facts
/// the UI and any planner may use; never backed by the mutable `FileNode` tree.
struct AnalysisReport: Sendable, Equatable {
    let generatedAt: Date
    let rootURL: URL
    let candidates: [CleanupCandidate]
    let warnings: [AnalysisWarning]
}
