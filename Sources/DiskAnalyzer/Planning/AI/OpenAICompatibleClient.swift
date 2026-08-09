import Foundation

// MARK: - Transport seam

/// Sends an HTTP POST and returns the response body. Injected so tests never
/// hit the network.
protocol AIHTTPTransport: Sendable {
    func postJSON(request: URLRequest) async throws -> Data
}

enum AITransportError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
}

struct URLSessionAITransport: AIHTTPTransport, Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func postJSON(request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AITransportError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AITransportError.httpStatus(http.statusCode)
        }
        return data
    }
}

// MARK: - Errors

enum RemotePlanningError: Error, Equatable, LocalizedError {
    case emptyAPIKey
    case emptyResponse
    case malformedJSON

    var errorDescription: String? {
        switch self {
        case .emptyAPIKey:
            return "No API key is configured."
        case .emptyResponse:
            return "The AI service returned an empty response."
        case .malformedJSON:
            return "The AI response could not be understood."
        }
    }
}

// MARK: - Client

/// Minimal OpenAI-compatible chat-completions client. Sends the redacted DTO
/// as the user message and requires a JSON object response. Never logs the
/// request body, the response body, or the API key.
struct OpenAICompatibleClient: Sendable {

    static let systemPrompt = """
    You are a planning engine for a macOS disk-cleanup app. You receive a JSON \
    list of candidate items. Produce a JSON plan with groups. Each group has a \
    "title", a list of "candidateIDs" chosen ONLY from the IDs you were given, \
    and an "explanation" under 300 characters. Never invent candidates, paths, \
    or actions. Respond with a single JSON object and nothing else.
    """

    let endpoint: URL
    let model: String
    let apiKey: String
    let transport: any AIHTTPTransport
    let timeout: TimeInterval

    init(
        endpoint: URL,
        model: String,
        apiKey: String,
        transport: any AIHTTPTransport = URLSessionAITransport(),
        timeout: TimeInterval = 30
    ) {
        self.endpoint = endpoint
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
        self.timeout = timeout
    }

    func draft(for dto: RemotePlanningDTO) async throws -> CleanupPlanDraft {
        guard !apiKey.isEmpty else {
            throw RemotePlanningError.emptyAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.requestBody(dto: dto, model: model)

        let data = try await transport.postJSON(request: request)
        let content = try Self.extractContent(from: data)
        return try Self.parseDraft(from: content)
    }

    // MARK: Encoding

    private static func requestBody(dto: RemotePlanningDTO, model: String) throws -> Data {
        let dtoData = try JSONEncoder().encode(dto)
        let dtoJSON = String(decoding: dtoData, as: UTF8.self)
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": dtoJSON]
            ],
            "response_format": ["type": "json_object"]
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: Decoding

    private static func extractContent(from data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RemotePlanningError.malformedJSON
        }
        guard let content = response.choices.first?.message.content,
              !content.isEmpty else {
            throw RemotePlanningError.emptyResponse
        }
        return content
    }

    private static func parseDraft(from content: String) throws -> CleanupPlanDraft {
        struct GroupsOnly: Decodable {
            let groups: [CleanupPlanGroupDraft]
        }

        guard let data = content.data(using: .utf8) else {
            throw RemotePlanningError.malformedJSON
        }
        do {
            let decoded = try JSONDecoder().decode(GroupsOnly.self, from: data)
            // The remote model never supplies selection; the validator's
            // local fallback computes it deterministically.
            return CleanupPlanDraft(groups: decoded.groups, defaultSelectedIDs: [])
        } catch {
            throw RemotePlanningError.malformedJSON
        }
    }
}
