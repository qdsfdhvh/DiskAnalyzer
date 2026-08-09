import XCTest
@testable import DiskAnalyzer

final class AnalysisModelsTests: XCTestCase {

    // MARK: RiskLevel

    func testRiskLevelOrdering() {
        XCTAssertLessThan(RiskLevel.low, RiskLevel.medium)
        XCTAssertLessThan(RiskLevel.medium, RiskLevel.high)
        XCTAssertLessThan(RiskLevel.low, RiskLevel.high)

        let sorted = [RiskLevel.high, RiskLevel.low, RiskLevel.medium].sorted()
        XCTAssertEqual(sorted, [.low, .medium, .high])
    }

    // MARK: Codable round trips

    func testCandidateIDCodableRoundTrip() throws {
        let id = CandidateID(rawValue: UUID())
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(CandidateID.self, from: data)
        XCTAssertEqual(decoded, id)
    }

    func testCleanupCandidateCodableRoundTrip() throws {
        let candidate = makeCandidate()
        let data = try JSONEncoder().encode(candidate)
        let decoded = try JSONDecoder().decode(CleanupCandidate.self, from: data)
        XCTAssertEqual(decoded, candidate)
    }

    func testAnalysisReportEquality() {
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let rootURL = URL(fileURLWithPath: "/tmp/Home")
        let a = AnalysisReport(
            generatedAt: generatedAt,
            rootURL: rootURL,
            candidates: [],
            warnings: []
        )
        let b = AnalysisReport(
            generatedAt: generatedAt,
            rootURL: rootURL,
            candidates: [],
            warnings: [.metadataUnavailable(displayPath: "x")]
        )
        XCTAssertEqual(a, a)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b.warnings, a.warnings)
    }

    // MARK: Helpers

    private func makeCandidate() -> CleanupCandidate {
        CleanupCandidate(
            id: CandidateID(rawValue: UUID()),
            url: URL(fileURLWithPath: "/tmp/Home/Library/Developer/Xcode/DerivedData/Output"),
            displayPath: "~/Library/Developer/Xcode/DerivedData/Output",
            category: .developerCache,
            allocatedSize: 8_400_000_000,
            risk: .low,
            defaultSelected: true,
            action: .moveToTrash,
            fingerprint: FileFingerprint(
                deviceID: 1,
                inode: 42,
                allocatedSize: 8_400_000_000,
                modificationTime: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            evidence: [
                CandidateEvidence(
                    kind: .knownRebuildablePath,
                    summary: "Xcode rebuilds generated artifacts"
                )
            ]
        )
    }
}
