import Foundation

// MARK: - Analysis seam

/// The single interface callers use to turn a completed scan tree into an
/// immutable analysis report. Callers never see discovery or enrichment
/// internals.
protocol Analyzing: Sendable {
    func analyze(
        root: FileNode,
        preferences: AnalysisPreferences
    ) async -> AnalysisReport
}

// MARK: - Engine

/// Composes discovery and enrichment into one report. Owns the candidate cap
/// and warning composition.
struct AnalysisEngine: Analyzing, Sendable {

    static let candidateLimit = 200

    let homeURL: URL
    let discovery: CandidateSeedDiscovery
    let enricher: CandidateEnricher
    let now: @Sendable () -> Date

    init(
        homeURL: URL,
        discovery: CandidateSeedDiscovery = CandidateSeedDiscovery(),
        enricher: CandidateEnricher = CandidateEnricher(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.homeURL = homeURL
        self.discovery = discovery
        self.enricher = enricher
        self.now = now
    }

    func analyze(root: FileNode, preferences: AnalysisPreferences) async -> AnalysisReport {
        let discovered = discovery.discover(
            root: root,
            homeURL: homeURL,
            limit: Self.candidateLimit
        )
        let enriched = enricher.enrich(
            seeds: discovered.seeds,
            preserveRecentDays: preferences.preserveRecentDays
        )

        var warnings = enriched.warnings
        if discovered.omittedCount > 0 {
            warnings.append(.candidateLimitReached(omittedCount: discovered.omittedCount))
        }

        return AnalysisReport(
            generatedAt: now(),
            rootURL: root.url,
            candidates: enriched.candidates,
            warnings: warnings
        )
    }
}
