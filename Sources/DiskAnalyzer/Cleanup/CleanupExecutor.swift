import Foundation

// MARK: - Progress

struct CleanupProgress: Sendable, Equatable {
    var completedItems: Int = 0
    var totalItems: Int = 0
    var currentDisplayPath: String = ""
}

// MARK: - Outcomes

enum CleanupSkipReason: Sendable, Equatable {
    case rejected(PreflightRejection)
    case cancelled
}

enum CleanupItemOutcome: Sendable, Equatable {
    case movedToTrash(originalURL: URL, trashURL: URL?)
    case skipped(displayPath: String, reason: CleanupSkipReason)
    case failed(displayPath: String, message: String)
}

// MARK: - Result

struct CleanupResult: Sendable, Equatable {
    /// One outcome per normalized input item, in input order.
    let outcomes: [CleanupItemOutcome]

    var movedCount: Int {
        outcomes.filter { if case .movedToTrash = $0 { return true }; return false }.count
    }

    var skippedCount: Int {
        outcomes.filter { if case .skipped = $0 { return true }; return false }.count
    }

    var failedCount: Int {
        outcomes.filter { if case .failed = $0 { return true }; return false }.count
    }
}

// MARK: - Execution seam

/// Executes approved cleanup items. Preflight runs immediately before each
/// item; partial failures and cancellation are reported, never swallowed.
protocol CleanupExecuting: Sendable {
    func execute(
        items: [ApprovedCleanupItem],
        progress: @escaping @Sendable (CleanupProgress) -> Void
    ) async -> CleanupResult
}
