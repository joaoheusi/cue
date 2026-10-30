import Foundation

public enum DotEnv {
    public static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let split = line.firstIndex(of: "=") else { continue }
            let key = line[..<split].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { values[key] = value }
        }
        return values
    }
}

public enum Assistant {
    public static let fileName = ".env"
    public static let keyName = "ANTHROPIC_API_KEY"
    public static let modelName = "ANTHROPIC_MODEL"
    public static let defaultModel = "claude-opus-5-5"
    public static let template = "\(keyName)=\n"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    public struct Credentials: Equatable, Sendable {
        public let key: String
        public let model: String
    }

    public static func credentials(in directory: URL) throws(CueError) -> Credentials {
        let url = directory.appendingPathComponent(fileName)
        let values = ((try? BoundedFile.read(url, maxBytes: 64 * 1024)).map { DotEnv.parse(String(decoding: $0, as: UTF8.self)) }) ?? [:]
        guard let key = values[keyName], !key.isEmpty else {
            throw CueError("AI_KEY_MISSING", "Add \(keyName) to the .env file. Open it from Settings → Commands.")
        }
        let model = values[modelName].flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        return Credentials(key: key, model: model)
    }

    public static func request(_ prompt: String, credentials: Credentials) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": credentials.model,
            "max_tokens": 16000,
            "fallbacks": "default",
            "output_config": ["effort": "low"],
            "messages": [["role": "user", "content": prompt]],
        ] as [String: Any])
        return request
    }

    public static func complete(_ prompt: String, credentials: Credentials) async throws(CueError) -> String {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: try request(prompt, credentials: credentials))
        } catch {
            throw failure(error)
        }
        return try parse(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func failure(_ error: Error) -> CueError {
        if (error as? URLError)?.code == .timedOut {
            return CueError("AI_TIMEOUT", "Claude took too long to respond. Try again.")
        }
        return CueError("AI_UNREACHABLE", "Could not reach Claude. Check your connection and try again.")
    }

    private struct Reply: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        struct Failure: Decodable { let message: String }
        let content: [Block]?
        let stop_reason: String?
        let error: Failure?
    }

    public static func parse(_ data: Data, status: Int) throws(CueError) -> String {
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard (200..<300).contains(status), let reply else {
            switch status {
            case 401, 403: throw CueError("AI_KEY_REJECTED", "Claude rejected the API key in .env.")
            case 429: throw CueError("AI_RATE_LIMITED", "Claude is rate limited. Try again in a moment.")
            default: throw CueError("AI_FAILED", reply?.error?.message ?? "Claude returned an error (\(status)). Try again.")
            }
        }
        switch reply.stop_reason {
        case "refusal": throw CueError("AI_REFUSED", "Claude declined this text.")
        case "max_tokens": throw CueError("AI_TRUNCATED", "The result was too long, so Cue discarded it.")
        default: break
        }
        let text = (reply.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CueError("AI_EMPTY", "Claude returned no text.")
        }
        return text
    }
}
