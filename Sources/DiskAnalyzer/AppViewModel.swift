import SwiftUI

// MARK: - Manages multiple scan sessions

@MainActor
final class AppViewModel: ObservableObject {
    @Published var sessions: [ScanSessionController] = []
    @Published var selectedID: UUID?
    /// Optional space goal set on the start screen; shapes recommendations.
    @Published var targetBytes: Int64?

    var selectedSession: ScanSessionController? {
        sessions.first { $0.id == selectedID }
    }

    // MARK: Add

    func addSession(url: URL) {
        let session = ScanSessionController(url: url)
        sessions.append(session)
        selectedID = session.id
        session.startScan()
    }

    func pickAndAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder or volume to analyze"
        panel.prompt = "Analyze"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        if panel.runModal() == .OK, let url = panel.url {
            addSession(url: url)
        }
    }

    func addHome() {
        addSession(url: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: Remove

    func removeSession(_ session: ScanSessionController) {
        if selectedID == session.id {
            selectNeighbor(after: session)
        }
        session.cancel()
        sessions.removeAll { $0.id == session.id }
    }

    private func selectNeighbor(after session: ScanSessionController) {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else {
            selectedID = nil
            return
        }
        if idx > 0 {
            selectedID = sessions[idx - 1].id
        } else if sessions.count > 1 {
            selectedID = sessions[1].id
        } else {
            selectedID = nil
        }
    }

    // MARK: Re-scan

    func rescan(_ session: ScanSessionController) {
        session.startScan()
    }

    func cancelScan(_ session: ScanSessionController) {
        session.cancel()
    }

    // MARK: Trash (single items from the file browser)

    /// Moves one URL to the Trash. Views call this instead of touching
    /// `FileManager` directly; the executor seam owns all filesystem mutation.
    func moveToTrash(url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    // MARK: Quick chips (convenience)

    static let quickLocations: [(label: String, path: String)] = [
        ("DerivedData", "~/Library/Developer/Xcode/DerivedData"),
        ("Simulators",  "~/Library/Developer/CoreSimulator"),
        ("Caches",      "~/Library/Caches"),
        ("Containers",  "~/Library/Containers"),
        ("Downloads",   "~/Downloads"),
    ]
}
