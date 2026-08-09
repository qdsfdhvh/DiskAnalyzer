import Foundation

// MARK: - Enrichment result

struct EnrichmentResult: Sendable, Equatable {
    let candidates: [CleanupCandidate]
    let warnings: [AnalysisWarning]
}

// MARK: - Enricher

/// Turns discovery seeds into fully enriched, immutable candidates.
///
/// This is the only stage allowed to touch the filesystem, and it does so
/// exactly once per seed. Age-based predicates and the risk/default/evidence
/// assignments from Architecture section 5 are applied here.
struct CandidateEnricher: Sendable {

    private static let installerMinAgeDays = 30
    private static let downloadMinAgeDays = 90

    let fingerprinter: FileFingerprinting
    let now: @Sendable () -> Date

    init(
        fingerprinter: FileFingerprinting = LstatFileFingerprinter(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fingerprinter = fingerprinter
        self.now = now
    }

    func enrich(seeds: [CandidateSeed], preserveRecentDays: Int) -> EnrichmentResult {
        var candidates: [CleanupCandidate] = []
        var warnings: [AnalysisWarning] = []
        let currentDate = now()

        for seed in seeds {
            let fingerprint: FileFingerprint
            do {
                fingerprint = try fingerprinter.fingerprint(url: seed.url)
            } catch FingerprintError.symlink {
                // Deliberate omission, matching the scanner's symlink policy.
                continue
            } catch {
                warnings.append(.metadataUnavailable(displayPath: seed.url.path))
                continue
            }

            let age = ageDays(fingerprint.modificationTime, now: currentDate)
            guard let category = resolveCategory(seed, ageDays: age, preserveRecentDays: preserveRecentDays) else {
                continue
            }

            let profile = Self.profile(for: category)
            candidates.append(CleanupCandidate(
                id: CandidateID(rawValue: UUID()),
                url: seed.url,
                displayPath: seed.url.path,
                category: category,
                allocatedSize: seed.treeSize,
                risk: profile.risk,
                defaultSelected: profile.defaultSelected,
                action: .moveToTrash,
                fingerprint: fingerprint,
                evidence: Self.evidence(for: category, ageDays: age)
            ))
        }

        return EnrichmentResult(candidates: candidates, warnings: warnings)
    }

    // MARK: Age predicates (Architecture section 5)

    private func resolveCategory(_ seed: CandidateSeed, ageDays: Int?, preserveRecentDays: Int) -> CleanupCategory? {
        switch seed.category {
        case .oldInstaller:
            guard let ageDays,
                  ageDays >= Self.installerMinAgeDays,
                  ageDays > preserveRecentDays else {
                return fallback(seed)
            }
            return .oldInstaller
        case .oldDownload:
            guard let ageDays,
                  ageDays >= Self.downloadMinAgeDays,
                  ageDays > preserveRecentDays else {
                return fallback(seed)
            }
            return .oldDownload
        default:
            return seed.category
        }
    }

    /// A seed whose age predicate failed still qualifies as a large file when
    /// it is >= 1 GB ("not matched above" falls through to `largeFile`);
    /// otherwise it is dropped entirely.
    private func fallback(_ seed: CandidateSeed) -> CleanupCategory? {
        seed.treeSize >= CandidateSeedDiscovery.largeFileMinBytes ? .largeFile : nil
    }

    // MARK: Risk / default selection (Architecture section 5)

    private static func profile(for category: CleanupCategory) -> (risk: RiskLevel, defaultSelected: Bool) {
        switch category {
        case .developerCache:    return (.low, true)
        case .oldInstaller:      return (.low, true)
        case .applicationCache:  return (.medium, false)
        case .oldDownload:       return (.medium, false)
        case .simulatorData:     return (.medium, false)
        case .largeFile:         return (.high, false)
        }
    }

    // MARK: Evidence

    private static func evidence(for category: CleanupCategory, ageDays: Int?) -> [CandidateEvidence] {
        switch category {
        case .developerCache:
            return [.init(kind: .knownRebuildablePath, summary: "Xcode rebuilds generated artifacts")]
        case .applicationCache:
            return [.init(kind: .knownRebuildablePath, summary: "Cache is usually rebuildable but may contain offline state")]
        case .oldInstaller:
            var e = [CandidateEvidence(kind: .fileExtension, summary: "Installer/archive can normally be downloaded again")]
            if let ageDays { e.append(.init(kind: .ageInDays, summary: "\(ageDays) days old")) }
            return e
        case .oldDownload:
            var e = [CandidateEvidence(kind: .userDataLocation, summary: "Direct child of Downloads")]
            if let ageDays { e.append(.init(kind: .ageInDays, summary: "\(ageDays) days old")) }
            return e
        case .simulatorData:
            return [.init(kind: .userDataLocation, summary: "Simulator device data under CoreSimulator/Devices")]
        case .largeFile:
            return [.init(kind: .allocatedSize, summary: "Large regular file")]
        }
    }

    private func ageDays(_ modificationTime: Date?, now: Date) -> Int? {
        guard let modificationTime else { return nil }
        return max(0, Int(now.timeIntervalSince(modificationTime) / 86_400))
    }
}
