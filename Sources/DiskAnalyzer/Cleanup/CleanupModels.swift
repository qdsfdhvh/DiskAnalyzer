import Foundation

// MARK: - Approved item

/// A candidate the user has explicitly approved for execution. Only these
/// values can cross into the executor seam. `explicitlyApproved` must be true
/// for high-risk candidates.
struct ApprovedCleanupItem: Sendable, Equatable {
    let candidate: CleanupCandidate
    let explicitlyApproved: Bool
}

// MARK: - Preflight rejection

/// Typed reasons an item fails preflight, suitable for direct UI display.
enum PreflightRejection: Error, Equatable, LocalizedError {
    case outsideRoot(displayPath: String)
    case symlink(displayPath: String)
    case missingFile(displayPath: String)
    case changed(displayPath: String)
    case unsupportedAction(CleanupAction)
    case highRiskRequiresApproval(displayPath: String)

    var errorDescription: String? {
        switch self {
        case .outsideRoot(let p):
            return "\(p) is outside the analyzed folder."
        case .symlink(let p):
            return "\(p) is a symbolic link and was skipped."
        case .missingFile(let p):
            return "\(p) no longer exists."
        case .changed(let p):
            return "\(p) changed since it was analyzed; please re-analyze."
        case .unsupportedAction(let a):
            return "Action \(a.rawValue) is not supported."
        case .highRiskRequiresApproval(let p):
            return "\(p) is high-risk and requires explicit approval."
        }
    }
}
