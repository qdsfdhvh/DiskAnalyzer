import XCTest
@testable import DiskAnalyzer

// MARK: - Fake transport

private struct TestError: Error {}

private final class FakeTransport: AIHTTPTransport, @unchecked Sendable {
    var result: Result<Data, Error> = .failure(TestError())
    var capturedRequest: URLRequest?

    func postJSON(request: URLRequest) async throws -> Data {
        capturedRequest = request
        return try result.get()
    }
}

// MARK: - Tests

final class RemoteCleanupPlannerTests: XCTestCase {

    private let GB = Int64(1024 * 1024 * 1024)
    private let homePath = "/Users/alice"
    private let endpoint = URL(string: "https://api.example.test/v1/chat/completions")!
    private var transport: FakeTransport!

    override func setUp() {
        super.setUp()
        transport = FakeTransport()
    }

    private func makeClient(key: String = "sk-test") -> OpenAICompatibleClient {
        OpenAICompatibleClient(
            endpoint: endpoint,
            model: "gpt-test-mini",
            apiKey: key,
            transport: transport,
            timeout: 5
        )
    }

    private func makeCandidate(id: CandidateID) -> CleanupCandidate {
        CleanupCandidate(
            id: id,
            url: URL(fileURLWithPath: "\(homePath)/Downloads/big.dmg"),
            displayPath: "~/Downloads/big.dmg",
            category: .oldInstaller,
            allocatedSize: 2 * GB,
            risk: .low,
            defaultSelected: true,
            action: .moveToTrash,
            fingerprint: FileFingerprint(deviceID: 1, inode: 1, allocatedSize: 2 * GB, modificationTime: nil),
            evidence: [CandidateEvidence(kind: .fileExtension, summary: "Installer/archive can normally be downloaded again")]
        )
    }

    private func makeReport(id: CandidateID) -> AnalysisReport {
        AnalysisReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            rootURL: URL(fileURLWithPath: homePath),
            candidates: [makeCandidate(id: id)],
            warnings: []
        )
    }

    private func validResponse(draftJSON: String) -> Data {
        let payload = """
        {"choices":[{"message":{"content":\(JSONString(draftJSON))}}]}
        """
        return Data(payload.utf8)
    }

    private func JSONString(_ s: String) -> String {
        // Encode a Swift string as a JSON string literal (top-level strings
        // require .fragmentsAllowed).
        let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Request encoding

    func testEncodedRequestCarriesModelAndRedactedPayload() async throws {
        let id = CandidateID(rawValue: UUID())
        let report = makeReport(id: id)
        transport.result = .success(validResponse(draftJSON: #"{"groups":[]}"#))
        let planner = RemoteCleanupPlanner(
            redactor: PrivacyRedactor(homePath: homePath),
            client: makeClient()
        )

        _ = try await planner.makeDraft(request: PlanningRequest(report: report, targetBytes: 10_000_000_000))

        let request = try XCTUnwrap(transport.capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer sk-test"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "gpt-test-mini")
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let userContent = try XCTUnwrap(messages[1]["content"] as? String)

        // The payload is the redacted DTO. Parse it back and check the decoded
        // values (raw JSON string matching trips over Foundation's escaped
        // slashes).
        let dtoJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(userContent.utf8)) as? [String: Any])
        XCTAssertEqual(dtoJSON["targetBytes"] as? Int, 10_000_000_000)
        let candidates = try XCTUnwrap(dtoJSON["candidates"] as? [[String: Any]])
        let first = try XCTUnwrap(candidates.first)
        XCTAssertEqual(first["id"] as? String, id.rawValue.uuidString)
        let pathLabel = try XCTUnwrap(first["pathLabel"] as? String)
        XCTAssertEqual(pathLabel, "~/Downloads/<private-1>")
        XCTAssertFalse(pathLabel.contains("alice"))
        XCTAssertFalse(pathLabel.contains("big.dmg"))
        let evidence = try XCTUnwrap(first["evidence"] as? [String])
        XCTAssertTrue(evidence.contains("Installer/archive can normally be downloaded again"))
    }

    // MARK: Response parsing

    func testValidResponseParsesDraft() async throws {
        let id = CandidateID(rawValue: UUID())
        let report = makeReport(id: id)
        let draftJSON = """
        {"groups":[{"title":"AI Group","candidateIDs":["\(id.rawValue.uuidString)"],"explanation":"Large download you can re-fetch"}]}
        """
        transport.result = .success(validResponse(draftJSON: draftJSON))
        let planner = RemoteCleanupPlanner(
            redactor: PrivacyRedactor(homePath: homePath),
            client: makeClient()
        )

        let draft = try await planner.makeDraft(request: PlanningRequest(report: report, targetBytes: nil))

        XCTAssertEqual(draft.groups.count, 1)
        XCTAssertEqual(draft.groups[0].title, "AI Group")
        XCTAssertEqual(draft.groups[0].candidateIDs, [id])
        XCTAssertTrue(draft.defaultSelectedIDs.isEmpty)
    }

    func testValidDraftPassesValidatorAgainstReport() async throws {
        let id = CandidateID(rawValue: UUID())
        let report = makeReport(id: id)
        let draftJSON = """
        {"groups":[{"title":"AI Group","candidateIDs":["\(id.rawValue.uuidString)"],"explanation":"ok"}]}
        """
        transport.result = .success(validResponse(draftJSON: draftJSON))
        let planner = RemoteCleanupPlanner(
            redactor: PrivacyRedactor(homePath: homePath),
            client: makeClient()
        )

        let draft = try await planner.makeDraft(request: PlanningRequest(report: report, targetBytes: nil))
        let plan = try CleanupPlanValidator().validate(draft: draft, against: report)

        XCTAssertEqual(plan.groups[0].candidates.map(\.id), [id])
        XCTAssertEqual(plan.groups[0].candidates[0].allocatedSize, 2 * GB)
    }

    func testUnknownIDInResponseRejectedByValidator() async throws {
        let id = CandidateID(rawValue: UUID())
        let report = makeReport(id: id)
        let ghost = CandidateID(rawValue: UUID())
        let draftJSON = """
        {"groups":[{"title":"AI Group","candidateIDs":["\(ghost.rawValue.uuidString)"],"explanation":"ok"}]}
        """
        transport.result = .success(validResponse(draftJSON: draftJSON))
        let planner = RemoteCleanupPlanner(
            redactor: PrivacyRedactor(homePath: homePath),
            client: makeClient()
        )

        let draft = try await planner.makeDraft(request: PlanningRequest(report: report, targetBytes: nil))

        XCTAssertThrowsError(try CleanupPlanValidator().validate(draft: draft, against: report)) { error in
            XCTAssertEqual(error as? CleanupPlanValidationError, .unknownCandidateID(ghost))
        }
    }

    // MARK: Failure modes

    func testMalformedJSONThrows() async throws {
        let id = CandidateID(rawValue: UUID())
        let report = makeReport(id: id)
        transport.result = .success(validResponse(draftJSON: "not json at all"))
        let planner = RemoteCleanupPlanner(
            redactor: PrivacyRedactor(homePath: homePath),
            client: makeClient()
        )

        do {
            _ = try await planner.makeDraft(request: PlanningRequest(report: report, targetBytes: nil))
            XCTFail("expected malformedJSON")
        } catch let error as RemotePlanningError {
            XCTAssertEqual(error, .malformedJSON)
        }
    }

    func testEmptyResponseThrows() async throws {
        let id = CandidateID(rawValue: UUID())
        let report = makeReport(id: id)
        transport.result = .success(Data(#"{"choices":[{"message":{"content":null}}]}"#.utf8))
        let planner = RemoteCleanupPlanner(
            redactor: PrivacyRedactor(homePath: homePath),
            client: makeClient()
        )

        do {
            _ = try await planner.makeDraft(request: PlanningRequest(report: report, targetBytes: nil))
            XCTFail("expected emptyResponse")
        } catch let error as RemotePlanningError {
            XCTAssertEqual(error, .emptyResponse)
        }
    }

    func testHTTPErrorPropagates() async throws {
        let id = CandidateID(rawValue: UUID())
        let report = makeReport(id: id)
        transport.result = .failure(AITransportError.httpStatus(500))
        let planner = RemoteCleanupPlanner(
            redactor: PrivacyRedactor(homePath: homePath),
            client: makeClient()
        )

        do {
            _ = try await planner.makeDraft(request: PlanningRequest(report: report, targetBytes: nil))
            XCTFail("expected http error")
        } catch let error as AITransportError {
            XCTAssertEqual(error, .httpStatus(500))
        }
    }

    func testTimeoutPropagates() async throws {
        let id = CandidateID(rawValue: UUID())
        let report = makeReport(id: id)
        transport.result = .failure(URLError(.timedOut))
        let planner = RemoteCleanupPlanner(
            redactor: PrivacyRedactor(homePath: homePath),
            client: makeClient()
        )

        do {
            _ = try await planner.makeDraft(request: PlanningRequest(report: report, targetBytes: nil))
            XCTFail("expected timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    func testEmptyAPIKeyThrows() async throws {
        let id = CandidateID(rawValue: UUID())
        let report = makeReport(id: id)
        transport.result = .success(validResponse(draftJSON: #"{"groups":[]}"#))
        let planner = RemoteCleanupPlanner(
            redactor: PrivacyRedactor(homePath: homePath),
            client: makeClient(key: "")
        )

        do {
            _ = try await planner.makeDraft(request: PlanningRequest(report: report, targetBytes: nil))
            XCTFail("expected emptyAPIKey")
        } catch let error as RemotePlanningError {
            XCTAssertEqual(error, .emptyAPIKey)
        }
    }

    // MARK: Coordinator integration

    func testRemotePlannerWorksThroughCoordinator() async throws {
        let id = CandidateID(rawValue: UUID())
        let report = makeReport(id: id)
        let draftJSON = """
        {"groups":[{"title":"AI Group","candidateIDs":["\(id.rawValue.uuidString)"],"explanation":"ok"}]}
        """
        transport.result = .success(validResponse(draftJSON: draftJSON))
        let remote = RemoteCleanupPlanner(
            redactor: PrivacyRedactor(homePath: homePath),
            client: makeClient()
        )
        let coordinator = PlanningCoordinator(
            localPlanner: LocalCleanupPlanner(),
            remotePlanner: remote,
            validator: CleanupPlanValidator()
        )

        let outcome = await coordinator.makePlan(
            request: PlanningRequest(report: report, targetBytes: nil),
            preferRemote: true
        )

        guard case let .plan(plan, notice) = outcome else {
            return XCTFail("expected plan")
        }
        XCTAssertNil(notice)
        XCTAssertEqual(plan.groups.first?.title, "AI Group")
    }

    func testRemoteFailureFallsBackThroughCoordinator() async throws {
        let id = CandidateID(rawValue: UUID())
        let report = makeReport(id: id)
        transport.result = .failure(AITransportError.httpStatus(429))
        let remote = RemoteCleanupPlanner(
            redactor: PrivacyRedactor(homePath: homePath),
            client: makeClient()
        )
        let coordinator = PlanningCoordinator(
            localPlanner: LocalCleanupPlanner(),
            remotePlanner: remote,
            validator: CleanupPlanValidator()
        )

        let outcome = await coordinator.makePlan(
            request: PlanningRequest(report: report, targetBytes: nil),
            preferRemote: true
        )

        guard case let .plan(plan, notice) = outcome else {
            return XCTFail("expected local fallback plan")
        }
        XCTAssertEqual(plan.groups.first?.title, "Safe to reclaim")
        XCTAssertNotNil(notice)
    }
}
