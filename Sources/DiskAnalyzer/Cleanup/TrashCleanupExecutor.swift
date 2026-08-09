import Foundation

// MARK: - Trash seam

/// Moves an item to the Trash. Injected so unit tests never touch the real
/// Trash.
protocol TrashMoving: Sendable {
    func moveToTrash(url: URL) throws -> URL?
}

struct FileManagerTrashMover: TrashMoving, Sendable {
    func moveToTrash(url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

// MARK: - Executor

/// Executes approved moves to the Trash with preflight verification before
/// every item, partial-result reporting, and cancellation between items.
struct TrashCleanupExecutor: CleanupExecuting, Sendable {

    let validator: PreflightValidator
    let trashMover: TrashMoving

    init(
        rootURL: URL,
        trashMover: TrashMoving = FileManagerTrashMover(),
        fingerprinter: FileFingerprinting = LstatFileFingerprinter()
    ) {
        self.validator = PreflightValidator(rootURL: rootURL, fingerprinter: fingerprinter)
        self.trashMover = trashMover
    }

    func execute(
        items: [ApprovedCleanupItem],
        progress: @escaping @Sendable (CleanupProgress) -> Void
    ) async -> CleanupResult {
        // Parent selection subsumes children before any execution begins.
        let normalized = validator.normalize(items)
        let total = normalized.count
        var outcomes: [CleanupItemOutcome] = []
        var completed = 0

        func emitProgress() {
            progress(CleanupProgress(
                completedItems: completed,
                totalItems: total,
                currentDisplayPath: ""
            ))
        }

        for item in normalized {
            if Task.isCancelled {
                // Stop starting new items; completed outcomes are preserved.
                outcomes.append(.skipped(
                    displayPath: item.candidate.displayPath,
                    reason: .cancelled
                ))
                completed += 1
                emitProgress()
                continue
            }

            do {
                try validator.validate(item)
                let trashURL = try trashMover.moveToTrash(url: item.candidate.url)
                outcomes.append(.movedToTrash(
                    originalURL: item.candidate.url,
                    trashURL: trashURL
                ))
            } catch let rejection as PreflightRejection {
                outcomes.append(.skipped(
                    displayPath: item.candidate.displayPath,
                    reason: .rejected(rejection)
                ))
            } catch {
                outcomes.append(.failed(
                    displayPath: item.candidate.displayPath,
                    message: error.localizedDescription
                ))
            }

            completed += 1
            emitProgress()
        }

        return CleanupResult(outcomes: outcomes)
    }
}
