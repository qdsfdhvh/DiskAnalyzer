import Foundation

/// Transforms local candidates into a bounded, redacted remote payload.
///
/// Rules (Architecture section 8):
/// - the home prefix becomes `~`;
/// - known system segments needed for classification are retained;
/// - unknown user-created components become deterministic `<private-N>` labels
///   that are stable within one request and distinct across different values;
/// - extensions are NOT preserved: they can carry identifying text
///   (e.g. `report.alice`), and the category field already conveys the type;
/// - candidates are capped at 100.
struct PrivacyRedactor: Sendable {

    /// Known system-structure segments retained verbatim.
    private static let knownSegments: Set<String> = [
        "Library", "Developer", "Xcode", "DerivedData", "Caches",
        "CoreSimulator", "Devices", "Downloads", "Containers",
        "Movies", "Documents", "Desktop", "Music", "Pictures", "Applications"
    ]

    /// Volume/root-level segments that are safe to keep as the label's anchor.
    private static let systemRoots: Set<String> = [
        "Volumes", "tmp", "private", "usr", "opt", "bin", "etc",
        "System", "Users", "Network"
    ]

    let homePath: String

    init(homePath: String = NSHomeDirectory()) {
        self.homePath = homePath
    }

    func redact(report: AnalysisReport, targetBytes: Int64?, limit: Int = 100) -> RemotePlanningDTO {
        var labels: [String: String] = [:]
        let candidates = report.candidates.prefix(limit).map {
            redact(candidate: $0, labels: &labels)
        }
        return RemotePlanningDTO(targetBytes: targetBytes, candidates: Array(candidates))
    }

    // MARK: Candidate

    private func redact(candidate: CleanupCandidate, labels: inout [String: String]) -> RemoteCandidateDTO {
        RemoteCandidateDTO(
            id: candidate.id.rawValue.uuidString,
            pathLabel: redactPath(candidate.url.path, labels: &labels),
            category: candidate.category,
            sizeBytes: candidate.allocatedSize,
            risk: candidate.risk,
            defaultSelected: candidate.defaultSelected,
            evidence: candidate.evidence.map(\.summary)
        )
    }

    // MARK: Path redaction

    func redactPath(_ path: String, labels: inout [String: String]) -> String {
        let standardized = (path as NSString).standardizingPath
        let home = (homePath as NSString).standardizingPath

        if standardized == home { return "~" }
        if standardized.hasPrefix(home + "/") {
            let rest = String(standardized.dropFirst(home.count + 1))
            return "~/" + redactComponents(rest, labels: &labels)
        }

        // Outside home: keep only the volume/root anchor, redact everything
        // else (including the volume name, which is user data).
        let parts = standardized.split(separator: "/").map(String.init)
        var out: [String] = []
        for (index, part) in parts.enumerated() {
            if index == 0 && Self.systemRoots.contains(part) {
                out.append(part)
            } else {
                out.append(label(for: part, labels: &labels))
            }
        }
        return out.joined(separator: "/")
    }

    private func redactComponents(_ rest: String, labels: inout [String: String]) -> String {
        rest.split(separator: "/")
            .map(String.init)
            .map { part in
                if Self.knownSegments.contains(part) { return part }
                return label(for: part, labels: &labels)
            }
            .joined(separator: "/")
    }

    /// Deterministic per-request label for one private path component.
    private func label(for component: String, labels: inout [String: String]) -> String {
        if let existing = labels[component] { return existing }
        let base = "<private-\(labels.count + 1)>"
        labels[component] = base
        return base
    }
}
