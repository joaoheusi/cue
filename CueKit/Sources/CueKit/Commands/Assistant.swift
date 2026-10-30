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

    public static func setting(_ key: String, to value: String?, in text: String) -> String {
        var found = false
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init).compactMap { line -> String? in
            let body = line.trimmingCharacters(in: .whitespaces)
            let plain = body.hasPrefix("export ") ? String(body.dropFirst(7)) : body
            guard !plain.hasPrefix("#"), let split = plain.firstIndex(of: "="),
                  plain[..<split].trimmingCharacters(in: .whitespaces) == key else { return line }
            guard let value, !found else { return nil }
            found = true
            return "\(key)=\(value)"
        }
        if let value, !found {
            if lines.last == "" { lines.removeLast() }
            lines += ["\(key)=\(value)", ""]
        }
        return lines.joined(separator: "\n")
    }
}

public enum Assistant {
    public static let fileName = ".env"
    public static let keyName = "ANTHROPIC_API_KEY"
    public static let modelName = "ANTHROPIC_MODEL"
    public static let defaultModel = "claude-opus-5-5"
    public static let template = "\(keyName)=\n"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let models = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
    static let version = "2026-10-21"

    public struct Credentials: Equatable, Sendable {
        public let key: String
        public let model: String
    }

    public static func credentials(in directory: URL, storedKey: String? = nil) throws(CueError) -> Credentials {
        let url = directory.appendingPathComponent(fileName)
        let values = ((try? BoundedFile.read(url, maxBytes: 64 * 1024)).map { DotEnv.parse(String(decoding: $0, as: UTF8.self)) }) ?? [:]
        guard let key = storedKey ?? values[keyName], !key.isEmpty else {
            throw CueError("AI_KEY_MISSING", "Add your Anthropic API key in Settings → Actions.")
        }
        let model = values[modelName].flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        return Credentials(key: key, model: model)
    }

    public static func request(_ prompt: String, credentials: Credentials, stream: Bool = false) throws -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.key, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        var body: [String: Any] = [
            "model": credentials.model,
            "max_tokens": stream ? 64000 : 16000,
            "fallbacks": "default",
            "output_config": ["effort": "low"],
            "messages": [["role": "user", "content": prompt]],
        ]
        if stream { body["stream"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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

    public static func stream(_ prompt: String, credentials: Credentials) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: try request(prompt, credentials: credentials, stream: true))
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var data = Data()
                        for try await byte in bytes.prefix(64 * 1024) { data.append(byte) }
                        _ = try parse(data, status: status)
                        throw CueError("AI_FAILED", "Claude returned an error (\(status)). Try again.")
                    }
                    var decoder = StreamDecoder()
                    for try await line in bytes.lines {
                        if let text = try decoder.feed(line) { continuation.yield(text) }
                    }
                    try decoder.finish()
                    continuation.finish()
                } catch let error as CueError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : failure(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public struct StreamDecoder {
        private var stopReason: String?
        private var wroteText = false

        public init() {}

        private struct Event: Decodable {
            struct Delta: Decodable {
                let type: String?
                let text: String?
                let stop_reason: String?
            }
            let type: String
            let delta: Delta?
            let error: Reply.Failure?
        }

        public mutating func feed(_ line: String) throws(CueError) -> String? {
            guard line.hasPrefix("data:") else { return nil }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = try? JSONDecoder().decode(Event.self, from: Data(payload.utf8)) else { return nil }
            switch event.type {
            case "content_block_delta" where event.delta?.type == "text_delta":
                guard let text = event.delta?.text, !text.isEmpty else { return nil }
                wroteText = true
                return text
            case "message_delta":
                stopReason = event.delta?.stop_reason ?? stopReason
                return nil
            case "error":
                throw CueError("AI_FAILED", event.error?.message ?? "Claude stopped with an error. Try again.")
            default:
                return nil
            }
        }

        public func finish() throws(CueError) {
            switch stopReason {
            case "refusal": throw CueError("AI_REFUSED", "Claude declined this text.")
            case "max_tokens": throw CueError("AI_TRUNCATED", "The result was too long, so Cue stopped it here.")
            case nil: throw CueError("AI_UNREACHABLE", "The connection to Claude ended early. Try again.")
            default: break
            }
            if !wroteText { throw CueError("AI_EMPTY", "Claude returned no text.") }
        }
    }

    public static func verify(_ credentials: Credentials) async throws(CueError) {
        var request = URLRequest(url: models, timeoutInterval: 20)
        request.setValue(credentials.key, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        let status: Int
        do {
            status = (try await URLSession.shared.data(for: request).1 as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw failure(error)
        }
        switch status {
        case 200..<300: return
        case 401, 403: throw CueError("AI_KEY_REJECTED", "Claude rejected this API key.")
        case 429: throw CueError("AI_RATE_LIMITED", "Claude is rate limited. Try again in a moment.")
        default: throw CueError("AI_FAILED", "Claude returned an error (\(status)). Try again.")
        }
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
            case 401, 403: throw CueError("AI_KEY_REJECTED", "Claude rejected your API key. Replace it in Settings → Actions.")
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
